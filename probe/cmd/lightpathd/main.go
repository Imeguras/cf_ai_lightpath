// Command lightpathd is the live probe daemon (phase 7). It follows the
// systemd journal, re-runs the read-only probes that events make relevant,
// publishes scrubbed evidence sets, and serves a small control API on a
// unix socket for the web app ("Re-probe now", status, the event timeline).
//
// It is meant to run as the unprivileged hlprobe user under systemd (see
// deploy/arch/lightpathd.service); it never escalates.
package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"lightpath/probe/correlate"
	"lightpath/probe/daemon"
	"lightpath/probe/inventory"
	"lightpath/probe/scrub"
)

func main() {
	state := flag.String("state", "/var/lib/lightpath", "state directory (raw runs, public sets, events)")
	scrubPath := flag.String("scrub", "/etc/lightpath/scrub.json", "private scrub config")
	socket := flag.String("socket", "/run/lightpath/probe.sock", "control API socket")
	keep := flag.Duration("keep", 90*24*time.Hour, "how long raw runs, public sets and events are kept")
	timeout := flag.Duration("timeout", 30*time.Second, "time limit per command")
	flag.Parse()
	log.SetFlags(0) // journald adds timestamps

	cfg, err := scrub.LoadConfig(*scrubPath)
	if err != nil {
		log.Fatalf("scrub config: %v", err)
	}
	s, err := scrub.New(cfg)
	if err != nil {
		log.Fatalf("scrub config: %v", err)
	}
	host, _ := os.Hostname()
	d, err := daemon.New(daemon.Config{
		StateDir: *state, Scrubber: s, Commands: inventory.DefaultCommands(), Rules: correlate.DefaultRules(),
		Runner: inventory.LocalRunner{}, Timeout: *timeout, Target: "hlprobe@" + host, Keep: *keep,
		Quiet: 30 * time.Second, MaxWait: 5 * time.Minute, Suppress: time.Hour, Now: time.Now,
	})
	if err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// The first start publishes one full set, so there is something to show.
	if sets, _ := filepath.Glob(filepath.Join(*state, "public", "live-*")); len(sets) == 0 {
		if name, err := d.Probe(ctx, nil); err != nil {
			log.Printf("first probe: %v", err)
		} else {
			log.Printf("published %s", name)
		}
	}

	srv := &http.Server{Handler: d.Handler(), ReadHeaderTimeout: 10 * time.Second, WriteTimeout: 10 * time.Minute}
	ln, err := listen(*socket)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("control API: %v", err)
			stop()
		}
	}()

	cursorFile := filepath.Join(*state, "journal.cursor")
	var cursor latest
	cursor.set(readCursor(cursorFile))
	go follow(ctx, d, &cursor)

	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			saveCursor(cursorFile, cursor.get())
			shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			srv.Shutdown(shutdown)
			cancel()
			return
		case <-tick.C:
			if name, err := d.Tick(ctx); err != nil {
				log.Printf("tick: %v", err)
			} else if name != "" {
				log.Printf("published %s", name)
			}
			saveCursor(cursorFile, cursor.get())
		}
	}
}

// listen opens the control socket, replacing a stale one, readable and
// writable by the owner and its group only (the web app joins the group).
func listen(path string) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o660); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// follow runs journalctl --follow and feeds it to the daemon, restarting it
// (after a pause) whenever it exits, resuming after the last cursor seen.
func follow(ctx context.Context, d *daemon.Daemon, cursor *latest) {
	for ctx.Err() == nil {
		args := []string{"--follow", "--output=json", "--no-pager"}
		if c := cursor.get(); c != "" {
			args = append(args, "--after-cursor="+c)
		} else {
			args = append(args, "--lines=0")
		}
		cmd := exec.CommandContext(ctx, "journalctl", args...)
		cmd.Env = []string{"LC_ALL=C"}
		out, err := cmd.StdoutPipe()
		if err == nil {
			err = cmd.Start()
		}
		if err == nil {
			err = d.Consume(out, cursor.set)
			cmd.Wait()
		}
		if ctx.Err() == nil {
			log.Printf("journal follower stopped (%v); restarting in 5s", err)
			select {
			case <-ctx.Done():
			case <-time.After(5 * time.Second):
			}
		}
	}
}

type latest struct {
	mu sync.Mutex
	v  string
}

func (l *latest) set(v string) { l.mu.Lock(); l.v = v; l.mu.Unlock() }
func (l *latest) get() string  { l.mu.Lock(); defer l.mu.Unlock(); return l.v }

func readCursor(path string) string {
	b, _ := os.ReadFile(path)
	return strings.TrimSpace(string(b))
}

func saveCursor(path, c string) {
	if c == "" {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(c+"\n"), 0o600); err == nil {
		os.Rename(tmp, path)
	}
}
