package inventory

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
)

// LocalRunner runs a command on this machine with os/exec, without a shell.
// The child gets this process's environment with LC_ALL=C added, so tool
// output is not localised.
type LocalRunner struct{}

// Run implements Runner.
func (LocalRunner) Run(ctx context.Context, argv []string) ([]byte, []byte, int, error) {
	return execute(ctx, argv)
}

// SSHRunner runs a command on a remote host through the ssh client, in batch
// mode, so it fails instead of asking for a password or passphrase.
type SSHRunner struct {
	// Target is the ssh destination, e.g. "user@host".
	Target string
	// Options are extra ssh client arguments, placed before Target.
	Options []string
}

// Args returns the full argument vector Run executes for argv:
//
//	ssh -o BatchMode=yes <Options...> -- <Target> "LC_ALL=C " + RemoteCommandLine(argv)
func (s SSHRunner) Args(argv []string) []string {
	args := []string{"ssh", "-o", "BatchMode=yes"}
	args = append(args, s.Options...)
	return append(args, "--", s.Target, "LC_ALL=C "+RemoteCommandLine(argv))
}

// Run implements Runner. ssh exits with 255 for its own failures (cannot
// connect, authentication refused), so exit status 255 is reported as an
// error rather than as the remote command's exit code.
func (s SSHRunner) Run(ctx context.Context, argv []string) ([]byte, []byte, int, error) {
	stdout, stderr, code, err := execute(ctx, s.Args(argv))
	if err == nil && code == 255 {
		err = fmt.Errorf("ssh failed (exit 255): %s", bytes.TrimSpace(stderr))
	}
	return stdout, stderr, code, err
}

// execute runs argv without a shell and separates "ran with some exit code"
// from "could not run".
func execute(ctx context.Context, argv []string) ([]byte, []byte, int, error) {
	if len(argv) == 0 {
		return nil, nil, -1, errors.New("empty argv")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr

	err := cmd.Run()
	if ctxErr := ctx.Err(); ctxErr != nil {
		return stdout.Bytes(), stderr.Bytes(), -1, ctxErr
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return stdout.Bytes(), stderr.Bytes(), exitErr.ExitCode(), nil
	}
	if err != nil {
		return stdout.Bytes(), stderr.Bytes(), -1, err
	}
	return stdout.Bytes(), stderr.Bytes(), 0, nil
}
