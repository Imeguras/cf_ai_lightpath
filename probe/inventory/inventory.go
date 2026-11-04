// Package inventory runs a fixed list of read-only commands against the
// homelab and saves their raw output as fixtures (phase 1 of the plan).
//
// It never escalates privileges. Commands that need root are allowed to fail;
// the failure itself (exit code, stderr) is recorded as evidence.
package inventory

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
)

// MaxOutputBytes is the most stdout or stderr kept per command. Anything
// beyond it is cut and the Result is marked Truncated.
const MaxOutputBytes = 1 << 20

// Command is one whitelisted, read-only command.
type Command struct {
	// ID is unique within a list, matches ^[a-z0-9][a-z0-9_-]*$ and is used
	// as the fixture file name.
	ID string
	// Argv is the exact argument vector. Argv[0] is a bare program name,
	// resolved through PATH.
	Argv []string
	// Why says what the output is evidence for.
	Why string
}

// Result is what happened when one Command ran.
type Result struct {
	ID         string    `json:"id"`
	Argv       []string  `json:"argv"`
	StartedAt  time.Time `json:"started_at"`
	DurationMS int64     `json:"duration_ms"`
	// ExitCode is the command's exit status, or -1 when it could not be
	// run or timed out.
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	// Truncated is true when stdout or stderr was cut at MaxOutputBytes.
	Truncated bool `json:"truncated"`
	TimedOut  bool `json:"timed_out"`
	// Error describes a failure to run the command at all (not found,
	// transport failure, timeout, cancellation). It is empty when the
	// command ran, whatever its exit code.
	Error string `json:"error,omitempty"`
}

// Validate checks a command list before anything runs. It returns an error
// when:
//   - the list is empty;
//   - an ID is empty, does not match ^[a-z0-9][a-z0-9_-]*$, or is duplicated;
//   - an Argv is empty;
//   - Argv[0] contains a '/', whitespace or any of the shell metacharacters
//     ; | & $ ` < > ( ) * ? [ ] { } ' " \ ~ !
//   - Argv[0] is a privilege-escalation program (doas, sudo, fudo, su,
//     pkexec, run0) or a shell (sh, bash, zsh, dash, fish);
//   - any element of Argv contains a NUL byte or a newline.
//
// Arguments after Argv[0] may contain spaces and shell metacharacters; they
// are passed as single words, never interpreted.
func Validate(cmds []Command) error {
	if len(cmds) == 0 {
		return errors.New("command list is empty")
	}
	seen := make(map[string]bool, len(cmds))
	for i, c := range cmds {
		if !validID(c.ID) {
			return fmt.Errorf("command %d: invalid ID %q", i, c.ID)
		}
		if seen[c.ID] {
			return fmt.Errorf("command %q: duplicate ID", c.ID)
		}
		seen[c.ID] = true
		if len(c.Argv) == 0 {
			return fmt.Errorf("command %q: empty argv", c.ID)
		}
		prog := c.Argv[0]
		if prog == "" || strings.ContainsAny(prog, programForbiddenChars) || strings.ContainsFunc(prog, unicode.IsSpace) {
			return fmt.Errorf("command %q: program %q must be a bare name", c.ID, prog)
		}
		if forbiddenPrograms[prog] {
			return fmt.Errorf("command %q: program %q is not allowed (privilege escalation or shell)", c.ID, prog)
		}
		for _, a := range c.Argv {
			if strings.ContainsAny(a, "\x00\n") {
				return fmt.Errorf("command %q: argument %q contains NUL or newline", c.ID, a)
			}
		}
	}
	return nil
}

var idRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

func validID(id string) bool { return idRE.MatchString(id) }

const programForbiddenChars = "/;|&$`<>()*?[]{}'\"\\~!"

var forbiddenPrograms = map[string]bool{
	"doas": true, "sudo": true, "fudo": true, "su": true, "pkexec": true, "run0": true,
	"sh": true, "bash": true, "zsh": true, "dash": true, "fish": true,
}

// Select returns the commands whose IDs are in ids, in the order they appear
// in cmds (not the order of ids). Repeated IDs in ids are ignored. An empty
// ids returns all of cmds. An ID that is not in cmds is an error.
func Select(cmds []Command, ids []string) ([]Command, error) {
	if len(ids) == 0 {
		return cmds, nil
	}
	want := make(map[string]bool, len(ids))
	for _, id := range ids {
		want[id] = true
	}
	var out []Command
	for _, c := range cmds {
		if want[c.ID] {
			out = append(out, c)
			delete(want, c.ID)
		}
	}
	for id := range want {
		return nil, fmt.Errorf("unknown command ID %q", id)
	}
	return out, nil
}

// ShellQuote quotes s for a POSIX shell so that the shell sees exactly one
// word equal to s, whatever s contains. The empty string becomes a pair of
// single quotes.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// RemoteCommandLine joins argv into a single command line for a POSIX
// shell, quoting every element with ShellQuote, so the shell runs exactly
// argv.
func RemoteCommandLine(argv []string) string {
	quoted := make([]string, len(argv))
	for i, a := range argv {
		quoted[i] = ShellQuote(a)
	}
	return strings.Join(quoted, " ")
}

// Runner executes one argument vector.
//
// Run returns the command's stdout, stderr and exit code. err is non-nil only
// when the command could not be run at all (program not found, transport
// failure, ctx cancelled or past its deadline); a non-zero exit is not an
// error.
type Runner interface {
	Run(ctx context.Context, argv []string) (stdout, stderr []byte, exitCode int, err error)
}

// RunAll runs each command in order with r, giving each one at most timeout.
// It never stops early: a command that fails, cannot start or times out is
// recorded in its Result and the next command runs.
//
// Each Result copies the command's ID and Argv. A command that exceeds
// timeout has TimedOut set, ExitCode -1 and a non-empty Error. When r
// returns an error, ExitCode is -1 and Error holds its message. Output
// longer than MaxOutputBytes is cut to MaxOutputBytes and Truncated is set.
//
// If ctx is cancelled, the commands not yet started are not run; their
// Results have ExitCode -1 and a non-empty Error. RunAll always returns one
// Result per command, in the same order as cmds.
func RunAll(ctx context.Context, r Runner, cmds []Command, timeout time.Duration) []Result {
	results := make([]Result, 0, len(cmds))
	for _, c := range cmds {
		res := Result{ID: c.ID, Argv: append([]string(nil), c.Argv...), StartedAt: time.Now()}
		if err := ctx.Err(); err != nil {
			res.ExitCode = -1
			res.Error = "not run: " + err.Error()
			results = append(results, res)
			continue
		}
		cctx, cancel := context.WithTimeout(ctx, timeout)
		stdout, stderr, code, err := r.Run(cctx, c.Argv)
		timedOut := errors.Is(cctx.Err(), context.DeadlineExceeded) && ctx.Err() == nil
		cancel()

		res.DurationMS = time.Since(res.StartedAt).Milliseconds()
		res.ExitCode = code
		res.Stdout, res.Truncated = clip(stdout, res.Truncated)
		res.Stderr, res.Truncated = clip(stderr, res.Truncated)
		switch {
		case timedOut:
			res.TimedOut = true
			res.ExitCode = -1
			res.Error = fmt.Sprintf("timed out after %s", timeout)
		case err != nil:
			res.ExitCode = -1
			res.Error = err.Error()
		}
		results = append(results, res)
	}
	return results
}

// clip cuts b to MaxOutputBytes, reporting whether it (or an earlier stream)
// was truncated.
func clip(b []byte, already bool) (string, bool) {
	if len(b) > MaxOutputBytes {
		return string(b[:MaxOutputBytes]), true
	}
	return string(b), already
}
