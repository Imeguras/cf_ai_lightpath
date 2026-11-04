package scrub_test

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"lightpath/probe/inventory"
	"lightpath/probe/scrub"
)

func versionScrubber(t *testing.T) *scrub.Scrubber {
	t.Helper()
	cfg := testCfg
	cfg.FakeVersions = scrub.FakeVersions{
		IDs:    []string{"pacman-q", "paru-aur-upgrades"},
		Keep:   []string{"linux", "zfs-dkms"},
		Secret: "test-secret",
	}
	s, err := scrub.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// shape replaces every digit run by "#", so versions with the same shape compare equal.
var digitRun = regexp.MustCompile(`[0-9]+`)

func shape(v string) string {
	return digitRun.ReplaceAllStringFunc(v, func(d string) string { return strings.Repeat("#", len(d)) })
}

func parseLine(t *testing.T, line string) (name, version string) {
	t.Helper()
	f := strings.Fields(line)
	if len(f) != 2 {
		t.Fatalf("line %q is not 'name version'", line)
	}
	return f[0], f[1]
}

// manyPackages builds a pacman -Q listing of n packages.
func manyPackages(n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "pkg%03d %d.%d.%d-%d\n", i, i%7+1, i%13, i%31+10, i%3+1)
	}
	return b.String()
}

func TestVersionsFakesAboutTwoThirds(t *testing.T) {
	s := versionScrubber(t)
	in := manyPackages(300)
	out := s.Versions("pacman-q", in)
	inLines, outLines := strings.Split(strings.TrimSpace(in), "\n"), strings.Split(strings.TrimSpace(out), "\n")
	if len(inLines) != len(outLines) {
		t.Fatalf("line count changed: %d -> %d", len(inLines), len(outLines))
	}
	changed := 0
	for i := range inLines {
		n1, v1 := parseLine(t, inLines[i])
		n2, v2 := parseLine(t, outLines[i])
		if n1 != n2 {
			t.Errorf("package name changed: %q -> %q", n1, n2)
		}
		if v1 != v2 {
			changed++
			if shape(v1) != shape(v2) {
				t.Errorf("%s: fake version %q does not have the shape of %q", n1, v2, v1)
			}
		}
	}
	if frac := float64(changed) / float64(len(inLines)); frac < 0.55 || frac > 0.78 {
		t.Errorf("faked %d of %d versions (%.0f%%), want about two thirds", changed, len(inLines), frac*100)
	}
}

func TestVersionsKeepsEpochAndRelease(t *testing.T) {
	s := versionScrubber(t)
	// Find faked packages among many, then check epoch and release on each.
	var b strings.Builder
	for i := 0; i < 60; i++ {
		fmt.Fprintf(&b, "lib%02d 1:2.%d.%d-%d\n", i, i, i+3, i%4+1)
	}
	in := strings.Split(strings.TrimSpace(b.String()), "\n")
	out := strings.Split(strings.TrimSpace(s.Versions("pacman-q", b.String())), "\n")
	faked := 0
	for i := range in {
		_, v1 := parseLine(t, in[i])
		_, v2 := parseLine(t, out[i])
		if v1 == v2 {
			continue
		}
		faked++
		if !strings.HasPrefix(v2, "1:") {
			t.Errorf("epoch lost: %q -> %q", v1, v2)
		}
		if v1[strings.LastIndexByte(v1, '-'):] != v2[strings.LastIndexByte(v2, '-'):] {
			t.Errorf("release changed: %q -> %q", v1, v2)
		}
	}
	if faked == 0 {
		t.Fatal("nothing was faked")
	}
}

func TestVersionsKeepList(t *testing.T) {
	s := versionScrubber(t)
	in := "linux 7.2.14.arch1-1\nzfs-dkms 2.4.0-1\n"
	if got := s.Versions("pacman-q", in); got != in {
		t.Errorf("kept packages changed:\n%s", got)
	}
}

func TestVersionsOnlyListedIDs(t *testing.T) {
	s := versionScrubber(t)
	in := manyPackages(30)
	if got := s.Versions("uname", in); got != in {
		t.Error("a fixture not in FakeVersions.IDs was changed")
	}
	none, _ := scrub.New(testCfg)
	if got := none.Versions("pacman-q", in); got != in {
		t.Error("with no FakeVersions config, pacman-q was changed")
	}
}

func TestVersionsUpgradeLinesAndConsistency(t *testing.T) {
	s := versionScrubber(t)
	q := s.Versions("pacman-q", manyPackages(60))
	var up strings.Builder
	for _, line := range strings.Split(strings.TrimSpace(manyPackages(60)), "\n") {
		f := strings.Fields(line)
		fmt.Fprintf(&up, "%s %s -> 9.9.9-1\n", f[0], f[1])
	}
	u := s.Versions("paru-aur-upgrades", up.String())

	fakeOf := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(q), "\n") {
		f := strings.Fields(line)
		fakeOf[f[0]] = f[1]
	}
	upLine := regexp.MustCompile(`^(\S+) (\S+) -> (\S+)$`)
	for _, line := range strings.Split(strings.TrimSpace(u), "\n") {
		m := upLine.FindStringSubmatch(line)
		if m == nil {
			t.Fatalf("upgrade line lost its format: %q", line)
		}
		if m[2] != fakeOf[m[1]] {
			t.Errorf("%s: pacman-q shows %q, paru-aur-upgrades shows %q", m[1], fakeOf[m[1]], m[2])
		}
	}
}

func TestVersionsDeterministic(t *testing.T) {
	in := manyPackages(50)
	if versionScrubber(t).Versions("pacman-q", in) != versionScrubber(t).Versions("pacman-q", in) {
		t.Error("two Scrubbers faked versions differently")
	}
}

func TestVersionsLeavesOtherLinesAlone(t *testing.T) {
	s := versionScrubber(t)
	for _, line := range []string{"error: package 'linux-lts' was not found", "", "  indented 1.2.3-1", "three words here 1.0-1"} {
		if got := s.Versions("pacman-q", line); got != line {
			t.Errorf("Versions(%q) = %q, want unchanged", line, got)
		}
	}
}

func TestFixturesFakesVersionsInStdout(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "h", []inventory.Result{
		{ID: "pacman-q", Argv: []string{"pacman", "-Q"}, Stdout: manyPackages(60)},
		{ID: "uname", Argv: []string{"uname"}, Stdout: "Linux labhost 7.2.14-arch1-1\n"},
	})
	out := filepath.Join(base, "out")
	if err := versionScrubber(t).Fixtures([]string{in}, out); err != nil {
		t.Fatal(err)
	}
	if got := readResult(t, filepath.Join(out, "pacman-q.json")).Stdout; got == manyPackages(60) {
		t.Error("pacman-q versions were not faked")
	}
	if got := readResult(t, filepath.Join(out, "uname.json")).Stdout; got != "Linux labhost 7.2.14-arch1-1\n" {
		t.Errorf("uname changed: %q", got)
	}
}

func TestNewRequiresSecretWhenFakingVersions(t *testing.T) {
	cfg := testCfg
	cfg.FakeVersions = scrub.FakeVersions{IDs: []string{"pacman-q"}}
	if _, err := scrub.New(cfg); err == nil {
		t.Error("New(FakeVersions without Secret) = nil error, want error")
	}
}

func TestVersionsDependOnSecret(t *testing.T) {
	in := manyPackages(60)
	a := versionScrubber(t).Versions("pacman-q", in)
	cfg := testCfg
	cfg.FakeVersions = scrub.FakeVersions{IDs: []string{"pacman-q"}, Keep: []string{"linux", "zfs-dkms"}, Secret: "another-secret"}
	other, err := scrub.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	b := other.Versions("pacman-q", in)
	if a == b {
		t.Fatal("two different secrets produced identical fake versions")
	}
	// Both choice and values must depend on it: count lines that differ.
	diff := 0
	la, lb := strings.Split(a, "\n"), strings.Split(b, "\n")
	for i := range la {
		if la[i] != lb[i] {
			diff++
		}
	}
	if diff < len(la)/3 {
		t.Errorf("only %d of %d lines differ between secrets", diff, len(la))
	}
}

func TestVersionsUnrelatedAcrossPackages(t *testing.T) {
	s := versionScrubber(t)
	var b strings.Builder
	for i := 0; i < 90; i++ {
		fmt.Fprintf(&b, "same%02d 1.2.3-1\n", i)
	}
	fakes := map[string]int{}
	faked := 0
	for _, line := range strings.Split(strings.TrimSpace(s.Versions("pacman-q", b.String())), "\n") {
		_, v := parseLine(t, line)
		if v != "1.2.3-1" {
			faked++
			fakes[v]++
		}
	}
	if faked == 0 {
		t.Fatal("nothing faked")
	}
	if float64(len(fakes)) < 0.8*float64(faked) {
		t.Errorf("%d faked packages with the same real version share only %d distinct fakes", faked, len(fakes))
	}
}
