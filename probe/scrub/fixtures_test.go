package scrub_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"lightpath/probe/inventory"
	"lightpath/probe/scrub"
)

var secrets = []string{"box-alpha", "alice", "tank_main", "192.168.1.153", "3c:4a:92:f0:11:2b", "0xec0d9a0300b0a7f1", "alice.surname@gmail.com"}

func writeRun(t *testing.T, dir, target string, results []inventory.Result) {
	t.Helper()
	if err := inventory.WriteFixtures(dir, target, time.Date(2026, 11, 4, 17, 32, 40, 0, time.UTC), results); err != nil {
		t.Fatal(err)
	}
}

func runA() []inventory.Result {
	return []inventory.Result{
		{ID: "uname", Argv: []string{"uname", "-a"}, Stdout: "Linux box-alpha 7.2.14-arch1-1\n"},
		{ID: "ip-addr", Argv: []string{"ip", "-j", "addr"}, Stdout: `[{"address":"3c:4a:92:f0:11:2b","local":"192.168.1.153"}]`},
		{ID: "ibstat", Argv: []string{"ibstat"}, Stdout: "Port GUID: 0xec0d9a0300b0a7f1\n"},
		{ID: "journal-warnings", Argv: []string{"journalctl"}, Stdout: "alice.surname@gmail.com logged in from 192.168.1.153\n"},
		{ID: "docker-ps", Argv: []string{"docker", "ps", "--filter", "volume=/tank_main"}, Stdout: "/home/alice/compose on /tank_main\n",
			Stderr: "warning from box-alpha", ExitCode: 1, Error: "ssh to alice@192.168.1.153 failed"},
	}
}

func readResult(t *testing.T, path string) inventory.Result {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var r inventory.Result
	if err := json.Unmarshal(data, &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func readManifest(t *testing.T, dir string) inventory.Manifest {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m inventory.Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestFixturesRemovesEverySecretFromEveryFile(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "alice@192.168.1.153", runA())
	out := filepath.Join(base, "public", "zfs-down")

	if err := newScrubber(t).Fixtures([]string{in}, out); err != nil {
		t.Fatalf("Fixtures: %v", err)
	}
	entries, err := os.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(runA())+1 {
		t.Errorf("out has %d files, want %d fixtures + index.json", len(entries), len(runA()))
	}
	for _, e := range entries {
		data, _ := os.ReadFile(filepath.Join(out, e.Name()))
		for _, sec := range secrets {
			if strings.Contains(string(data), sec) {
				t.Errorf("%s still contains %q", e.Name(), sec)
			}
		}
	}
}

func TestFixturesKeepsStructureAndUnsensitiveData(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "alice@192.168.1.153", runA())
	out := filepath.Join(base, "out")
	if err := newScrubber(t).Fixtures([]string{in}, out); err != nil {
		t.Fatal(err)
	}
	r := readResult(t, filepath.Join(out, "uname.json"))
	if r.ID != "uname" || r.Stdout != "Linux labhost 7.2.14-arch1-1\n" || len(r.Argv) != 2 {
		t.Errorf("uname fixture = %+v", r)
	}
	d := readResult(t, filepath.Join(out, "docker-ps.json"))
	if d.ExitCode != 1 || d.Stderr != "warning from labhost" || d.Error == "" || strings.Contains(d.Error, "alice") {
		t.Errorf("docker-ps fixture = %+v", d)
	}
	m := readManifest(t, out)
	if strings.Contains(m.Target, "alice") || strings.Contains(m.Target, "192.168") {
		t.Errorf("manifest target not scrubbed: %q", m.Target)
	}
	if len(m.Entries) != len(runA()) || m.Entries[0].ID != "uname" {
		t.Errorf("manifest entries = %+v", m.Entries)
	}
	for _, e := range m.Entries {
		if strings.Contains(e.Error, "alice") {
			t.Errorf("manifest entry error not scrubbed: %q", e.Error)
		}
	}
}

func TestFixturesConsistentAcrossFiles(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "h", runA())
	out := filepath.Join(base, "out")
	if err := newScrubber(t).Fixtures([]string{in}, out); err != nil {
		t.Fatal(err)
	}
	ip := readResult(t, filepath.Join(out, "ip-addr.json")).Stdout
	journal := readResult(t, filepath.Join(out, "journal-warnings.json")).Stdout
	q := dottedQuad.FindString(ip)
	if q == "" || !strings.Contains(journal, q) {
		t.Errorf("the same address got different placeholders: ip-addr %q, journal %q", ip, journal)
	}
}

func TestFixturesLaterDirReplacesSameID(t *testing.T) {
	base := t.TempDir()
	a, b := filepath.Join(base, "a"), filepath.Join(base, "b")
	writeRun(t, a, "h", runA())
	writeRun(t, b, "h", []inventory.Result{
		{ID: "ibstat", Argv: []string{"ibstat"}, Stdout: "fixed run\n"},
		{ID: "docker-security", Argv: []string{"docker", "info"}, Stdout: `["name=seccomp"]`},
	})
	out := filepath.Join(base, "out")
	if err := newScrubber(t).Fixtures([]string{a, b}, out); err != nil {
		t.Fatal(err)
	}
	if got := readResult(t, filepath.Join(out, "ibstat.json")).Stdout; got != "fixed run\n" {
		t.Errorf("ibstat = %q, want the later run", got)
	}
	m := readManifest(t, out)
	var ids []string
	for _, e := range m.Entries {
		ids = append(ids, e.ID)
	}
	want := []string{"uname", "ip-addr", "ibstat", "journal-warnings", "docker-ps", "docker-security"}
	if strings.Join(ids, ",") != strings.Join(want, ",") {
		t.Errorf("manifest order = %v, want %v", ids, want)
	}
}

func TestFixturesDrop(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "h", runA())
	cfg := testCfg
	cfg.Drop = []string{"journal-warnings"}
	s, err := scrub.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(base, "out")
	if err := s.Fixtures([]string{in}, out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(out, "journal-warnings.json")); !os.IsNotExist(err) {
		t.Error("dropped fixture was written")
	}
	for _, e := range readManifest(t, out).Entries {
		if e.ID == "journal-warnings" {
			t.Error("dropped fixture is still in the manifest")
		}
	}
}

func TestFixturesRefusesExistingOut(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "h", runA())
	out := filepath.Join(base, "out")
	os.Mkdir(out, 0o755)
	os.WriteFile(filepath.Join(out, "keep"), []byte("old"), 0o644)
	if err := newScrubber(t).Fixtures([]string{in}, out); err == nil {
		t.Fatal("Fixtures(existing out) = nil error, want error")
	}
	if data, _ := os.ReadFile(filepath.Join(out, "keep")); string(data) != "old" {
		t.Error("existing out was modified")
	}
}

func TestFixturesPublicPermissions(t *testing.T) {
	base := t.TempDir()
	in := filepath.Join(base, "raw")
	writeRun(t, in, "h", runA())
	out := filepath.Join(base, "pub", "set")
	if err := newScrubber(t).Fixtures([]string{in}, out); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{filepath.Join(base, "pub"), out} {
		st, _ := os.Stat(d)
		if st.Mode().Perm() != 0o755 {
			t.Errorf("%s mode = %o, want 755", d, st.Mode().Perm())
		}
	}
	entries, _ := os.ReadDir(out)
	for _, e := range entries {
		info, _ := e.Info()
		if info.Mode().Perm() != 0o644 {
			t.Errorf("%s mode = %o, want 644", e.Name(), info.Mode().Perm())
		}
	}
}

func TestFixturesMissingInputIsError(t *testing.T) {
	base := t.TempDir()
	out := filepath.Join(base, "out")
	if err := newScrubber(t).Fixtures([]string{filepath.Join(base, "nope")}, out); err == nil {
		t.Error("Fixtures(missing input) = nil error, want error")
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Error("out was created despite the error")
	}
}
