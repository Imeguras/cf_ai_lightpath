package daemon_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"lightpath/probe/correlate"
	"lightpath/probe/daemon"
	"lightpath/probe/events"
	"lightpath/probe/inventory"
	"lightpath/probe/scrub"
)

// A runner that answers "<argv0> run <n> on realhost" and counts calls.
type fakeRunner struct {
	mu    sync.Mutex
	calls map[string]int
	block chan struct{}
}

func (f *fakeRunner) Run(ctx context.Context, argv []string) ([]byte, []byte, int, error) {
	if f.block != nil {
		<-f.block
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls[argv[0]]++
	return []byte(argv[0] + " run " + string(rune('0'+f.calls[argv[0]])) + " on realhost\n"), nil, 0, nil
}

func (f *fakeRunner) count(name string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[name]
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

var cmds = []inventory.Command{
	{ID: "uname", Argv: []string{"uname", "-a"}, Why: "kernel"},
	{ID: "pacman-q", Argv: []string{"pacman", "-Q"}, Why: "packages"},
	{ID: "ip-link", Argv: []string{"ip", "link"}, Why: "links"},
}

var rules = []correlate.Rule{
	{Kind: events.Package, Subject: regexpMust(`linux`), Probes: []string{"uname", "pacman-q"}, Why: "kernel"},
}

func setup(t *testing.T) (*daemon.Daemon, *fakeRunner, *clock, string) {
	t.Helper()
	dir := t.TempDir()
	s, err := scrub.New(scrub.Config{Literals: []scrub.Literal{{Find: "realhost", Replace: "labhost"}}})
	if err != nil {
		t.Fatal(err)
	}
	r := &fakeRunner{calls: map[string]int{}}
	c := &clock{t: time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)}
	d, err := daemon.New(daemon.Config{
		StateDir: dir, Scrubber: s, Commands: cmds, Rules: rules, Runner: r,
		Timeout: time.Second, Target: "hlprobe@realhost", Keep: 90 * 24 * time.Hour,
		Quiet: 30 * time.Second, MaxWait: 5 * time.Minute, Suppress: time.Hour, Now: c.now,
	})
	if err != nil {
		t.Fatal(err)
	}
	return d, r, c, dir
}

func readSet(t *testing.T, dir, name string) (inventory.Manifest, map[string]inventory.Result) {
	t.Helper()
	var m inventory.Manifest
	b, err := os.ReadFile(filepath.Join(dir, "public", name, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	json.Unmarshal(b, &m)
	out := map[string]inventory.Result{}
	for _, e := range m.Entries {
		var r inventory.Result
		b, _ := os.ReadFile(filepath.Join(dir, "public", name, e.File))
		json.Unmarshal(b, &r)
		out[r.ID] = r
	}
	return m, out
}

func TestFirstProbeRunsEverythingAndPublishesAScrubbedSet(t *testing.T) {
	d, r, _, dir := setup(t)
	name, err := d.Probe(context.Background(), []string{"uname"})
	if err != nil {
		t.Fatal(err)
	}
	if name != "live-20261108T120000.000Z" {
		t.Fatalf("name %q", name)
	}
	if r.count("uname") != 1 || r.count("pacman") != 1 || r.count("ip") != 1 {
		t.Fatalf("first run must be full: %v", r.calls)
	}
	m, set := readSet(t, dir, name)
	if len(set) != 3 || strings.Contains(m.Target, "realhost") {
		t.Fatalf("manifest %+v", m)
	}
	if got := set["uname"].Stdout; got != "uname run 1 on labhost\n" {
		t.Fatalf("not scrubbed: %q", got)
	}
	if fi, err := os.Stat(filepath.Join(dir, "raw")); err != nil || fi.Mode().Perm() != 0o750 {
		t.Fatalf("raw dir: %v %v", fi, err)
	}
}

func TestPartialProbeMergesOverTheLastFullRun(t *testing.T) {
	d, r, c, dir := setup(t)
	d.Probe(context.Background(), nil)
	c.add(time.Minute)
	name, err := d.Probe(context.Background(), []string{"uname"})
	if err != nil {
		t.Fatal(err)
	}
	if r.count("uname") != 2 || r.count("pacman") != 1 {
		t.Fatalf("partial ran %v", r.calls)
	}
	_, set := readSet(t, dir, name)
	if len(set) != 3 || set["uname"].Stdout != "uname run 2 on labhost\n" || set["pacman-q"].Stdout != "pacman run 1 on labhost\n" {
		t.Fatalf("merge wrong: %+v", set)
	}
	if _, err := d.Probe(context.Background(), []string{"nope"}); err == nil {
		t.Fatal("unknown id accepted")
	}
}

func TestOneRunAtATime(t *testing.T) {
	d, r, _, _ := setup(t)
	r.block = make(chan struct{})
	done := make(chan error)
	go func() { _, err := d.Probe(context.Background(), nil); done <- err }()
	time.Sleep(50 * time.Millisecond)
	if _, err := d.Probe(context.Background(), nil); !errors.Is(err, daemon.ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy", err)
	}
	close(r.block)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestEventsQueueProbesAndAreRecordedScrubbed(t *testing.T) {
	d, r, c, dir := setup(t)
	d.Probe(context.Background(), nil)

	e := events.Event{Time: c.now(), Kind: events.Package, Subject: "linux", Change: "upgraded", Message: "linux on realhost"}
	if err := d.Observe(e); err != nil {
		t.Fatal(err)
	}
	if name, _ := d.Tick(context.Background()); name != "" {
		t.Fatalf("ran before quiet: %s", name)
	}
	c.add(31 * time.Second)
	name, err := d.Tick(context.Background())
	if err != nil || name == "" {
		t.Fatalf("tick: %q %v", name, err)
	}
	if r.count("uname") != 2 || r.count("pacman") != 2 || r.count("ip") != 1 {
		t.Fatalf("ran %v", r.calls)
	}

	b, _ := os.ReadFile(filepath.Join(dir, "events", "events-2026-11-08.jsonl"))
	if !strings.Contains(string(b), "linux on labhost") || strings.Contains(string(b), "realhost") {
		t.Fatalf("timeline: %s", b)
	}

	unrelated := events.Event{Time: c.now(), Kind: events.Unit, Subject: "x.service", Change: "started", Message: "m"}
	d.Observe(unrelated)
	c.add(time.Hour)
	if name, _ := d.Tick(context.Background()); name != "" {
		t.Fatalf("unrelated event ran probes: %s", name)
	}
}

func TestTickPrunesOldDataOncePerDay(t *testing.T) {
	d, _, c, dir := setup(t)
	old := filepath.Join(dir, "public", "live-20260801T000000.000Z")
	os.MkdirAll(old, 0o750)
	os.WriteFile(filepath.Join(dir, "events", "events-2026-08-01.jsonl"), nil, 0o640)
	os.MkdirAll(filepath.Join(dir, "raw", "20260801T000000.000Z"), 0o750)
	d.Tick(context.Background())
	for _, p := range []string{old, filepath.Join(dir, "events", "events-2026-08-01.jsonl"), filepath.Join(dir, "raw", "20260801T000000.000Z")} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s not pruned", p)
		}
	}
	c.add(time.Hour)
	os.MkdirAll(old, 0o750)
	d.Tick(context.Background())
	if _, err := os.Stat(old); err != nil {
		t.Errorf("pruned twice on the same day")
	}
}

func TestHandler(t *testing.T) {
	d, _, c, _ := setup(t)
	h := d.Handler()
	do := func(method, path string) (int, map[string]any) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		var body map[string]any
		json.Unmarshal(rec.Body.Bytes(), &body)
		if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Errorf("%s %s: content-type %q", method, path, ct)
		}
		return rec.Code, body
	}

	code, body := do("POST", "/probe")
	if code != 200 || body["set"] != "live-20261108T120000.000Z" {
		t.Fatalf("probe: %d %v", code, body)
	}
	code, body = do("GET", "/status")
	if code != 200 || body["running"] != false || body["last_set"] != "live-20261108T120000.000Z" {
		t.Fatalf("status: %d %v", code, body)
	}
	d.Observe(events.Event{Time: c.now(), Kind: events.Package, Subject: "linux", Change: "upgraded", Message: "linux"})
	code, body = do("GET", "/status")
	if p, _ := body["pending"].([]any); len(p) != 2 {
		t.Fatalf("pending: %v", body)
	}
	code, body = do("GET", "/events")
	if evs, _ := body["events"].([]any); code != 200 || len(evs) != 1 {
		t.Fatalf("events: %d %v", code, body)
	}
	code, body = do("GET", "/events?since=2026-11-09T00:00:00Z")
	if evs, _ := body["events"].([]any); code != 200 || len(evs) != 0 {
		t.Fatalf("events since: %d %v", code, body)
	}
	if code, _ = do("GET", "/events?since=yesterday"); code != 400 {
		t.Errorf("bad since: %d", code)
	}
	for _, c := range []struct {
		m, p string
		want int
	}{{"GET", "/probe", 405}, {"POST", "/status", 405}, {"GET", "/nope", 404}} {
		if code, _ := do(c.m, c.p); code != c.want {
			t.Errorf("%s %s = %d, want %d", c.m, c.p, code, c.want)
		}
	}
}

func TestNewChecksConfig(t *testing.T) {
	s, _ := scrub.New(scrub.Config{})
	ok := daemon.Config{StateDir: t.TempDir(), Scrubber: s, Commands: cmds, Runner: &fakeRunner{}, Timeout: time.Second, Keep: time.Hour, Quiet: time.Second, MaxWait: time.Minute, Now: time.Now}
	if _, err := daemon.New(ok); err != nil {
		t.Fatalf("valid config: %v", err)
	}
	bad := []func(*daemon.Config){
		func(c *daemon.Config) { c.StateDir = "" },
		func(c *daemon.Config) { c.Scrubber = nil },
		func(c *daemon.Config) { c.Runner = nil },
		func(c *daemon.Config) { c.Now = nil },
		func(c *daemon.Config) { c.Timeout = 0 },
		func(c *daemon.Config) { c.Keep = 0 },
		func(c *daemon.Config) {
			c.Commands = []inventory.Command{{ID: "x", Argv: []string{"sudo", "ls"}, Why: "w"}}
		},
	}
	for i, mutate := range bad {
		c := ok
		mutate(&c)
		if _, err := daemon.New(c); err == nil {
			t.Errorf("bad config %d accepted", i)
		}
	}
	_ = slices.Contains[[]string]
}

func regexpMust(p string) *regexp.Regexp { return regexp.MustCompile(p) }

func TestFlappingIsSuppressedAndCounted(t *testing.T) {
	d, r, c, dir := setup(t)
	d.Probe(context.Background(), nil)
	fail := func() events.Event {
		return events.Event{Time: c.now(), Kind: events.Package, Subject: "linux", Change: "upgraded", Message: "linux"}
	}
	d.Observe(fail())
	c.add(time.Minute)
	d.Tick(context.Background()) // runs the first batch
	ran := r.count("uname")

	for i := 0; i < 50; i++ { // a restart loop: identical events every 10 s
		c.add(10 * time.Second)
		d.Observe(fail())
	}
	c.add(time.Minute)
	if name, _ := d.Tick(context.Background()); name != "" || r.count("uname") != ran {
		t.Fatalf("suppressed events re-probed: %q", name)
	}
	other := events.Event{Time: c.now(), Kind: events.Package, Subject: "linux", Change: "removed", Message: "linux"}
	d.Observe(other) // a different change is not suppressed

	c.add(time.Hour)
	d.Observe(fail()) // the window has passed: recorded again, with the count

	evs, _ := os.ReadFile(filepath.Join(dir, "events", "events-2026-11-08.jsonl"))
	lines := strings.Split(strings.TrimSpace(string(evs)), "\n")
	if len(lines) != 3 {
		t.Fatalf("recorded %d events, want 3:\n%s", len(lines), evs)
	}
	if !strings.Contains(lines[2], `"repeats":50`) || strings.Contains(lines[0], "repeats") {
		t.Fatalf("repeat count wrong:\n%s", evs)
	}
}
