package inventory_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"lightpath/probe/inventory"
)

func sampleResults() []inventory.Result {
	t0 := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	return []inventory.Result{
		{ID: "uname", Argv: []string{"uname", "-r"}, StartedAt: t0, DurationMS: 4, ExitCode: 0, Stdout: "7.0.3-arch1-1\n"},
		{ID: "zpool-status", Argv: []string{"zpool", "status"}, StartedAt: t0, DurationMS: 9, ExitCode: 1, Stderr: "The ZFS modules are not loaded.\n"},
		{ID: "slow", Argv: []string{"sleep", "9"}, StartedAt: t0, ExitCode: -1, TimedOut: true, Error: "timed out"},
	}
}

func TestWriteFixturesWritesOneFilePerResultAndIndex(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "run1")
	created := time.Date(2026, 11, 3, 12, 30, 0, 0, time.UTC)
	results := sampleResults()

	if err := inventory.WriteFixtures(dir, "micron@server", created, results); err != nil {
		t.Fatalf("WriteFixtures: %v", err)
	}

	for _, want := range results {
		data, err := os.ReadFile(filepath.Join(dir, want.ID+".json"))
		if err != nil {
			t.Fatalf("missing fixture for %s: %v", want.ID, err)
		}
		var got inventory.Result
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatalf("%s.json is not a Result: %v", want.ID, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s.json = %+v, want %+v", want.ID, got, want)
		}
	}

	data, err := os.ReadFile(filepath.Join(dir, "index.json"))
	if err != nil {
		t.Fatalf("missing index.json: %v", err)
	}
	var m inventory.Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("index.json is not a Manifest: %v", err)
	}
	if m.Target != "micron@server" || !m.CreatedAt.Equal(created) {
		t.Errorf("manifest header = %q %v", m.Target, m.CreatedAt)
	}
	if len(m.Entries) != len(results) {
		t.Fatalf("manifest has %d entries, want %d", len(m.Entries), len(results))
	}
	for i, r := range results {
		e := m.Entries[i]
		if e.ID != r.ID || e.ExitCode != r.ExitCode || e.TimedOut != r.TimedOut || e.Truncated != r.Truncated || e.Error != r.Error {
			t.Errorf("entry %d = %+v, does not summarise %+v", i, e, r)
		}
		if _, err := os.Stat(filepath.Join(dir, e.File)); err != nil {
			t.Errorf("entry %d names file %q that does not exist", i, e.File)
		}
	}
}

func TestWriteFixturesPermissions(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "run")
	if err := inventory.WriteFixtures(dir, "h", time.Now(), sampleResults()); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o700 {
		t.Errorf("dir mode = %o, want 700", st.Mode().Perm())
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) == 0 {
		t.Fatal("no files written")
	}
	for _, e := range entries {
		info, _ := e.Info()
		if info.Mode().Perm() != 0o600 {
			t.Errorf("%s mode = %o, want 600", e.Name(), info.Mode().Perm())
		}
	}
}

func TestWriteFixturesCreatesMissingParentsPrivately(t *testing.T) {
	base := t.TempDir()
	dir := filepath.Join(base, "a", "b", "run")
	if err := inventory.WriteFixtures(dir, "h", time.Now(), sampleResults()); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{filepath.Join(base, "a"), filepath.Join(base, "a", "b")} {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.Mode().Perm() != 0o700 {
			t.Errorf("%s mode = %o, want 700", p, st.Mode().Perm())
		}
	}
}

func TestWriteFixturesRefusesExistingDir(t *testing.T) {
	dir := t.TempDir()
	keep := filepath.Join(dir, "keep.txt")
	os.WriteFile(keep, []byte("old"), 0o600)
	if err := inventory.WriteFixtures(dir, "h", time.Now(), sampleResults()); err == nil {
		t.Fatal("WriteFixtures(existing dir) = nil, want error")
	}
	if data, _ := os.ReadFile(keep); string(data) != "old" {
		t.Error("existing file was modified")
	}
	if _, err := os.Stat(filepath.Join(dir, "index.json")); err == nil {
		t.Error("index.json written into an existing dir")
	}
}

func TestWriteFixturesRejectsBadIDsBeforeWriting(t *testing.T) {
	for name, results := range map[string][]inventory.Result{
		"traversal": {{ID: "ok"}, {ID: "../evil"}},
		"invalid":   {{ID: "Bad ID"}},
		"empty":     {{ID: "ok"}, {ID: ""}},
		"reserved":  {{ID: "index"}},
		"duplicate": {{ID: "dup"}, {ID: "dup"}},
	} {
		dir := filepath.Join(t.TempDir(), "run")
		if err := inventory.WriteFixtures(dir, "h", time.Now(), results); err == nil {
			t.Errorf("%s: WriteFixtures = nil, want error", name)
		}
		if _, err := os.Stat(dir); !os.IsNotExist(err) {
			t.Errorf("%s: dir was created despite invalid IDs", name)
		}
	}
}
