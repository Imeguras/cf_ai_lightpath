package inventory_test

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"lightpath/probe/inventory"
)

// fakeRunner returns canned outcomes keyed by argv[0] and records calls.
type fakeRunner struct {
	mu       sync.Mutex
	calls    []string
	outcomes map[string]outcome
}

type outcome struct {
	stdout, stderr []byte
	exit           int
	err            error
	block          bool // wait until ctx is done, then return ctx.Err()
}

func (f *fakeRunner) Run(ctx context.Context, argv []string) ([]byte, []byte, int, error) {
	f.mu.Lock()
	f.calls = append(f.calls, argv[0])
	o := f.outcomes[argv[0]]
	f.mu.Unlock()
	if o.block {
		<-ctx.Done()
		return nil, nil, -1, ctx.Err()
	}
	return o.stdout, o.stderr, o.exit, o.err
}

func TestRunAllRecordsEveryCommandInOrder(t *testing.T) {
	f := &fakeRunner{outcomes: map[string]outcome{
		"ok":      {stdout: []byte("out"), stderr: []byte("warn"), exit: 0},
		"nonzero": {stdout: []byte("partial"), exit: 3},
		"broken":  {err: errors.New("exec: not found")},
	}}
	cmds := []inventory.Command{cmd("c1", "ok", "-a"), cmd("c2", "broken"), cmd("c3", "nonzero", "x")}
	res := inventory.RunAll(context.Background(), f, cmds, time.Second)

	if len(res) != 3 {
		t.Fatalf("got %d results, want 3", len(res))
	}
	for i, c := range cmds {
		if res[i].ID != c.ID || len(res[i].Argv) != len(c.Argv) || res[i].Argv[0] != c.Argv[0] {
			t.Errorf("result %d = %s %v, want %s %v", i, res[i].ID, res[i].Argv, c.ID, c.Argv)
		}
		if res[i].StartedAt.IsZero() {
			t.Errorf("result %d has zero StartedAt", i)
		}
		if res[i].DurationMS < 0 {
			t.Errorf("result %d has negative DurationMS", i)
		}
	}
	if r := res[0]; r.ExitCode != 0 || r.Stdout != "out" || r.Stderr != "warn" || r.Error != "" || r.TimedOut || r.Truncated {
		t.Errorf("ok result = %+v", r)
	}
	if r := res[1]; r.ExitCode != -1 || r.Error == "" {
		t.Errorf("runner error result = %+v, want ExitCode -1 and Error set", r)
	}
	if r := res[2]; r.ExitCode != 3 || r.Error != "" || r.Stdout != "partial" {
		t.Errorf("non-zero exit result = %+v, want ExitCode 3, no Error", r)
	}
	if len(f.calls) != 3 {
		t.Errorf("runner called %d times, want 3 (RunAll must not stop early)", len(f.calls))
	}
}

func TestRunAllTimeoutIsPerCommand(t *testing.T) {
	f := &fakeRunner{outcomes: map[string]outcome{
		"slow": {block: true},
		"fast": {stdout: []byte("done")},
	}}
	cmds := []inventory.Command{cmd("slow", "slow"), cmd("fast", "fast")}
	start := time.Now()
	res := inventory.RunAll(context.Background(), f, cmds, 50*time.Millisecond)
	if time.Since(start) > 2*time.Second {
		t.Fatal("RunAll did not enforce the timeout")
	}
	if r := res[0]; !r.TimedOut || r.ExitCode != -1 || r.Error == "" {
		t.Errorf("slow result = %+v, want TimedOut, ExitCode -1, Error set", r)
	}
	if r := res[1]; r.TimedOut || r.ExitCode != 0 || r.Stdout != "done" {
		t.Errorf("fast result after a timeout = %+v, want it to run normally", r)
	}
}

func TestRunAllTruncatesLongOutput(t *testing.T) {
	big := bytes.Repeat([]byte("x"), inventory.MaxOutputBytes+10)
	f := &fakeRunner{outcomes: map[string]outcome{
		"bigout": {stdout: big},
		"bigerr": {stderr: big},
		"exact":  {stdout: big[:inventory.MaxOutputBytes]},
	}}
	res := inventory.RunAll(context.Background(), f,
		[]inventory.Command{cmd("o", "bigout"), cmd("e", "bigerr"), cmd("x", "exact")}, time.Second)
	if r := res[0]; len(r.Stdout) != inventory.MaxOutputBytes || !r.Truncated {
		t.Errorf("stdout len %d truncated %v, want %d true", len(r.Stdout), r.Truncated, inventory.MaxOutputBytes)
	}
	if r := res[1]; len(r.Stderr) != inventory.MaxOutputBytes || !r.Truncated {
		t.Errorf("stderr len %d truncated %v, want %d true", len(r.Stderr), r.Truncated, inventory.MaxOutputBytes)
	}
	if r := res[2]; len(r.Stdout) != inventory.MaxOutputBytes || r.Truncated {
		t.Errorf("output of exactly MaxOutputBytes: len %d truncated %v, want untouched", len(r.Stdout), r.Truncated)
	}
}

func TestRunAllCancelledContextSkipsRemaining(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	f := &fakeRunner{outcomes: map[string]outcome{}}
	cancel()
	cmds := []inventory.Command{cmd("a", "a"), cmd("b", "b")}
	res := inventory.RunAll(ctx, f, cmds, time.Second)
	if len(res) != 2 {
		t.Fatalf("got %d results, want 2", len(res))
	}
	for _, r := range res {
		if r.ExitCode != -1 || r.Error == "" {
			t.Errorf("result %s = %+v, want ExitCode -1 and Error set", r.ID, r)
		}
	}
	if len(f.calls) != 0 {
		t.Errorf("runner called %d times after cancel, want 0", len(f.calls))
	}
}

func TestRunAllEmptyList(t *testing.T) {
	if res := inventory.RunAll(context.Background(), &fakeRunner{}, nil, time.Second); len(res) != 0 {
		t.Errorf("RunAll(nil) = %v, want empty", res)
	}
}

func TestLocalRunnerCapturesOutputAndExit(t *testing.T) {
	out, errOut, code, err := (inventory.LocalRunner{}).Run(context.Background(),
		[]string{"sh", "-c", "printf out; printf err >&2; exit 3"})
	if err != nil {
		t.Fatalf("Run err = %v, want nil for a non-zero exit", err)
	}
	if string(out) != "out" || string(errOut) != "err" || code != 3 {
		t.Errorf("Run = %q %q %d, want out err 3", out, errOut, code)
	}
}

func TestLocalRunnerZeroExit(t *testing.T) {
	_, _, code, err := (inventory.LocalRunner{}).Run(context.Background(), []string{"true"})
	if err != nil || code != 0 {
		t.Errorf("Run(true) = %d, %v; want 0, nil", code, err)
	}
}

func TestLocalRunnerDoesNotUseAShell(t *testing.T) {
	out, _, _, err := (inventory.LocalRunner{}).Run(context.Background(), []string{"printf", "%s", "$HOME;`id`"})
	if err != nil || string(out) != "$HOME;`id`" {
		t.Errorf("Run = %q, %v; argument was interpreted", out, err)
	}
}

func TestLocalRunnerSetsCLocale(t *testing.T) {
	out, _, _, err := (inventory.LocalRunner{}).Run(context.Background(), []string{"sh", "-c", `printf %s "$LC_ALL"`})
	if err != nil || string(out) != "C" {
		t.Errorf("LC_ALL in child = %q, %v; want C", out, err)
	}
}

func TestLocalRunnerMissingProgramIsError(t *testing.T) {
	if _, _, _, err := (inventory.LocalRunner{}).Run(context.Background(), []string{"no-such-program-xyz"}); err == nil {
		t.Error("Run(missing program) err = nil, want error")
	}
}

func TestLocalRunnerHonoursContext(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, _, _, err := (inventory.LocalRunner{}).Run(ctx, []string{"sleep", "5"})
	if err == nil {
		t.Error("Run past deadline err = nil, want error")
	}
	if time.Since(start) > 2*time.Second {
		t.Error("Run did not stop at the deadline")
	}
}
