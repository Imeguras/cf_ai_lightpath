package inventory_test

import (
	"context"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"testing"

	"lightpath/probe/inventory"
)

var awkwardStrings = []string{
	"", "simple", "with space", "it's", "a'b'c", "''", "$HOME", "${HOME}", "`id`", "$(id)",
	"a;b|c&d", "*", "?", "[ab]", "~", "~root", "\\", "\\'", "\"double\"", "tab\there",
	"new\nline", "trailing\n", "-n", "--", "ünïcödé", "!event", "#comment", "{a,b}", "a=b",
}

// sh runs a command line in a real POSIX shell and returns its stdout.
func sh(t *testing.T, line string) string {
	t.Helper()
	out, err := exec.Command("/bin/sh", "-c", line).Output()
	if err != nil {
		t.Fatalf("sh -c %q: %v", line, err)
	}
	return string(out)
}

func TestShellQuoteIsOneWordEqualToInput(t *testing.T) {
	for _, s := range awkwardStrings {
		// printf '<%s>' with exactly one argument prints it once, wrapped.
		got := sh(t, `printf '<%s>' `+inventory.ShellQuote(s))
		if got != "<"+s+">" {
			t.Errorf("ShellQuote(%q): shell saw %q, want %q", s, got, "<"+s+">")
		}
	}
}

func TestShellQuoteEmptyString(t *testing.T) {
	if got := inventory.ShellQuote(""); got != "''" {
		t.Errorf("ShellQuote(\"\") = %q, want ''", got)
	}
}

func TestRemoteCommandLineRunsExactArgv(t *testing.T) {
	args := append([]string{}, awkwardStrings...)
	argv := append([]string{"printf", "<%s>"}, args...)
	got := sh(t, inventory.RemoteCommandLine(argv))
	var want strings.Builder
	for _, a := range args {
		want.WriteString("<" + a + ">")
	}
	if got != want.String() {
		t.Errorf("shell output = %q, want %q", got, want.String())
	}
}

func TestRemoteCommandLineDoesNotRunInjectedCommands(t *testing.T) {
	marker := t.TempDir() + "/pwned"
	argv := []string{"printf", "%s", "; touch " + marker, "$(touch " + marker + ")", "`touch " + marker + "`"}
	sh(t, inventory.RemoteCommandLine(argv))
	if exec.Command("test", "-e", marker).Run() == nil {
		t.Fatal("an argument was executed by the shell")
	}
}

func TestSSHRunnerArgs(t *testing.T) {
	r := inventory.SSHRunner{Target: "user@host", Options: []string{"-p", "2222"}}
	argv := []string{"zpool", "status", "it's"}
	got := r.Args(argv)

	if len(got) == 0 || got[0] != "ssh" {
		t.Fatalf("Args()[0] = %v, want ssh", got)
	}
	if !slices.Equal(got[1:3], []string{"-o", "BatchMode=yes"}) {
		t.Errorf("Args()[1:3] = %q, want [-o BatchMode=yes]", got[1:3])
	}
	ti := slices.Index(got, "user@host")
	if ti < 0 {
		t.Fatalf("Args() = %q has no target", got)
	}
	if oi := slices.Index(got, "2222"); oi < 0 || oi > ti {
		t.Errorf("Options not placed before target: %q", got)
	}
	if got[ti-1] != "--" {
		t.Errorf("element before target = %q, want --", got[ti-1])
	}
	if ti != len(got)-2 {
		t.Fatalf("Args() should end with target then command line: %q", got)
	}
	wantLine := "LC_ALL=C " + inventory.RemoteCommandLine(argv)
	if got[len(got)-1] != wantLine {
		t.Errorf("command line = %q, want %q", got[len(got)-1], wantLine)
	}
}

func TestSSHRunnerArgsWithoutOptions(t *testing.T) {
	got := inventory.SSHRunner{Target: "h"}.Args([]string{"uname"})
	want := []string{"ssh", "-o", "BatchMode=yes", "--", "h", "LC_ALL=C " + inventory.RemoteCommandLine([]string{"uname"})}
	if !slices.Equal(got, want) {
		t.Errorf("Args() = %q, want %q", got, want)
	}
}

// fakeSSH puts an executable named ssh first on PATH. It records its
// arguments, prints to stdout and stderr, and exits with code.
func fakeSSH(t *testing.T, code int) (argsFile string) {
	t.Helper()
	dir := t.TempDir()
	argsFile = dir + "/args"
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + inventory.ShellQuote(argsFile) +
		"\nprintf remote-out\nprintf remote-err >&2\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(dir+"/ssh", []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return argsFile
}

func TestSSHRunnerRunPassesRemoteExitCode(t *testing.T) {
	argsFile := fakeSSH(t, 3)
	r := inventory.SSHRunner{Target: "user@host"}
	out, errOut, code, err := r.Run(context.Background(), []string{"zpool", "status"})
	if err != nil || code != 3 || string(out) != "remote-out" || string(errOut) != "remote-err" {
		t.Errorf("Run = %q %q %d %v, want remote-out remote-err 3 nil", out, errOut, code, err)
	}
	data, _ := os.ReadFile(argsFile)
	got := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if want := r.Args([]string{"zpool", "status"})[1:]; !slices.Equal(got, want) {
		t.Errorf("ssh received %q, want %q", got, want)
	}
}

func TestSSHRunnerRunTreats255AsError(t *testing.T) {
	fakeSSH(t, 255)
	_, _, _, err := inventory.SSHRunner{Target: "user@host"}.Run(context.Background(), []string{"uname"})
	if err == nil {
		t.Error("Run with ssh exit 255 err = nil, want error")
	}
}
