// Package daemon is the live probe: it records events, re-runs the probes
// they make relevant, and publishes scrubbed evidence sets the web app
// reads. Everything it runs is a fixed, read-only inventory command; callers
// can only ask for a full run.
//
// Layout under Config.StateDir:
//
//	raw/<stamp>/          unscrubbed runs (inventory.WriteFixtures), private
//	raw/last-full         name of the newest full run
//	public/live-<stamp>/  scrubbed sets (the web app's fixtures root)
//	events/               the scrubbed event timeline (package store)
//
// A stamp is the run's UTC time as 20060102T150405.000Z.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"lightpath/probe/correlate"
	"lightpath/probe/events"
	"lightpath/probe/inventory"
	"lightpath/probe/scrub"
	"lightpath/probe/store"
)

const stampLayout = "20060102T150405.000Z"

// Config wires the daemon to its environment.
type Config struct {
	StateDir string
	Scrubber *scrub.Scrubber
	Commands []inventory.Command
	Rules    []correlate.Rule
	Runner   inventory.Runner
	// Timeout per command.
	Timeout time.Duration
	// Target is recorded in each set's manifest (and scrubbed).
	Target string
	// Keep is how long raw runs, public sets and events are kept.
	Keep time.Duration
	// Quiet and MaxWait configure the event debouncer (see correlate).
	Quiet, MaxWait time.Duration
	Now            func() time.Time
}

// ErrBusy is returned when a probe run is already in progress.
var ErrBusy = errors.New("a probe run is already in progress")

// Daemon is safe for concurrent use.
type Daemon struct {
	cfg Config

	running sync.Mutex // held for the whole of a probe run

	mu        sync.Mutex // guards the fields below
	debounce  correlate.Debouncer
	lastSet   string
	prunedDay string
}

// New checks cfg (StateDir, Scrubber, Runner and Now set; Commands valid
// per inventory.Validate; Timeout and Keep positive) and creates the state
// directories (0750).
func New(cfg Config) (*Daemon, error) {
	switch {
	case cfg.StateDir == "":
		return nil, errors.New("daemon: StateDir is required")
	case cfg.Scrubber == nil:
		return nil, errors.New("daemon: Scrubber is required")
	case cfg.Runner == nil:
		return nil, errors.New("daemon: Runner is required")
	case cfg.Now == nil:
		return nil, errors.New("daemon: Now is required")
	case cfg.Timeout <= 0 || cfg.Keep <= 0:
		return nil, errors.New("daemon: Timeout and Keep must be positive")
	}
	if err := inventory.Validate(cfg.Commands); err != nil {
		return nil, fmt.Errorf("daemon: %w", err)
	}
	for _, sub := range []string{"raw", "public", "events"} {
		dir := filepath.Join(cfg.StateDir, sub)
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return nil, err
		}
		if err := os.Chmod(dir, 0o750); err != nil {
			return nil, err
		}
	}
	d := &Daemon{cfg: cfg, debounce: correlate.Debouncer{Quiet: cfg.Quiet, MaxWait: cfg.MaxWait}}
	if sets, _ := filepath.Glob(filepath.Join(cfg.StateDir, "public", "live-*")); len(sets) > 0 {
		slices.Sort(sets)
		d.lastSet = filepath.Base(sets[len(sets)-1])
	}
	return d, nil
}

// Probe runs the commands with the given ids, or all of them when ids is
// empty or no full run exists yet (unknown ids are an error). It writes the
// raw run, then publishes public/live-<stamp>: the last full run and every
// later run merged, later results winning, through the Scrubber. It returns
// the set's name. Only one run happens at a time: a concurrent call returns
// ErrBusy without running anything.
func (d *Daemon) Probe(ctx context.Context, ids []string) (string, error) {
	if !d.running.TryLock() {
		return "", ErrBusy
	}
	defer d.running.Unlock()

	rawDir := filepath.Join(d.cfg.StateDir, "raw")
	lastFull, _ := os.ReadFile(filepath.Join(rawDir, "last-full"))
	full := len(ids) == 0 || len(lastFull) == 0
	cmds := d.cfg.Commands
	if !full {
		var err error
		if cmds, err = inventory.Select(d.cfg.Commands, ids); err != nil {
			return "", err
		}
	}

	now := d.cfg.Now().UTC()
	stamp := now.Format(stampLayout)
	results := inventory.RunAll(ctx, d.cfg.Runner, cmds, d.cfg.Timeout)
	if err := inventory.WriteFixtures(filepath.Join(rawDir, stamp), d.cfg.Target, now, results); err != nil {
		return "", err
	}
	if full {
		if err := os.WriteFile(filepath.Join(rawDir, "last-full"), []byte(stamp), 0o600); err != nil {
			return "", err
		}
		lastFull = []byte(stamp)
	}

	// The last full run and everything after it, oldest first.
	runs, err := filepath.Glob(filepath.Join(rawDir, "2*"))
	if err != nil {
		return "", err
	}
	slices.Sort(runs)
	var ins []string
	for _, r := range runs {
		if filepath.Base(r) >= string(lastFull) {
			ins = append(ins, r)
		}
	}

	name := "live-" + stamp
	if err := d.cfg.Scrubber.Fixtures(ins, filepath.Join(d.cfg.StateDir, "public", name)); err != nil {
		return "", err
	}
	d.mu.Lock()
	d.lastSet = name
	d.mu.Unlock()
	return name, nil
}

// Observe records e: its Message passes through the Scrubber, it is
// appended to the timeline, and the probes the Rules name for it are queued.
func (d *Daemon) Observe(e events.Event) error {
	e.Message = d.cfg.Scrubber.Text(e.Message)
	e.Subject = d.cfg.Scrubber.Text(e.Subject)
	if err := store.Append(filepath.Join(d.cfg.StateDir, "events"), e); err != nil {
		return err
	}
	d.mu.Lock()
	d.debounce.Add(correlate.Probes(d.cfg.Rules, e), d.cfg.Now())
	d.mu.Unlock()
	return nil
}

// Tick runs the queued probes once the debouncer says they are due,
// returning the published set's name ("" when nothing ran), and once per
// UTC day removes raw runs, public sets and event files older than Keep.
func (d *Daemon) Tick(ctx context.Context) (string, error) {
	now := d.cfg.Now()
	var errs []error

	d.mu.Lock()
	day := now.UTC().Format("2006-01-02")
	prune := d.prunedDay != day
	d.prunedDay = day
	due := d.debounce.Due(now)
	d.mu.Unlock()

	if prune {
		for _, sub := range []string{"raw", "public", "events"} {
			if _, err := store.Prune(filepath.Join(d.cfg.StateDir, sub), now, d.cfg.Keep); err != nil {
				errs = append(errs, err)
			}
		}
	}
	if len(due) == 0 {
		return "", errors.Join(errs...)
	}
	name, err := d.Probe(ctx, due)
	if errors.Is(err, ErrBusy) {
		// A run is going on; try these again later.
		d.mu.Lock()
		d.debounce.Add(due, now)
		d.mu.Unlock()
		return "", errors.Join(errs...)
	}
	return name, errors.Join(append(errs, err)...)
}

// Handler serves the control API (over a unix socket in production). JSON
// in and out:
//
//	POST /probe   runs everything: 200 {"set"}; 409 {"error"} when busy;
//	              500 {"error"} on failure
//	GET  /status  200 {"running": bool, "last_set": string, "pending": [ids]}
//	GET  /events?since=<RFC 3339>
//	              200 {"events": [...]}: the timeline from since (default:
//	              the last 7 days), oldest first; 400 for a bad since
//	other methods on these paths: 405; other paths: 404
func (d *Daemon) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/probe", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			reply(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		name, err := d.Probe(r.Context(), nil)
		switch {
		case errors.Is(err, ErrBusy):
			reply(w, http.StatusConflict, map[string]string{"error": err.Error()})
		case err != nil:
			reply(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		default:
			reply(w, http.StatusOK, map[string]string{"set": name})
		}
	})
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			reply(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		running := !d.running.TryLock()
		if !running {
			d.running.Unlock()
		}
		d.mu.Lock()
		body := map[string]any{"running": running, "last_set": d.lastSet, "pending": orEmpty(d.debounce.Pending())}
		d.mu.Unlock()
		reply(w, http.StatusOK, body)
	})
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			reply(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
			return
		}
		since := d.cfg.Now().Add(-7 * 24 * time.Hour)
		if q := r.URL.Query().Get("since"); q != "" {
			t, err := time.Parse(time.RFC3339, q)
			if err != nil {
				reply(w, http.StatusBadRequest, map[string]string{"error": "since must be RFC 3339"})
				return
			}
			since = t
		}
		evs, err := store.Read(filepath.Join(d.cfg.StateDir, "events"), since)
		if err != nil {
			reply(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
			return
		}
		reply(w, http.StatusOK, map[string]any{"events": orEmpty(evs)})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		reply(w, http.StatusNotFound, map[string]string{"error": "not found: " + strings.TrimPrefix(r.URL.Path, "/")})
	})
	return mux
}

func orEmpty[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func reply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(body)
}
