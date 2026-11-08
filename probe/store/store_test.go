package store_test

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"lightpath/probe/events"
	"lightpath/probe/store"
)

func at(day, hour int) time.Time { return time.Date(2026, 11, day, hour, 0, 0, 0, time.UTC) }

func ev(t time.Time, subject string) events.Event {
	return events.Event{Time: t, Kind: events.Package, Subject: subject, Change: "upgraded", Message: subject}
}

func TestAppendAndRead(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "events")
	for _, e := range []events.Event{ev(at(7, 23), "a"), ev(at(8, 1), "b"), ev(at(8, 2), "c")} {
		if err := store.Append(dir, e); err != nil {
			t.Fatal(err)
		}
	}
	names, _ := filepath.Glob(filepath.Join(dir, "*"))
	for i := range names {
		names[i] = filepath.Base(names[i])
	}
	if !slices.Equal(names, []string{"events-2026-11-07.jsonl", "events-2026-11-08.jsonl"}) {
		t.Fatalf("files = %v", names)
	}
	if fi, _ := os.Stat(dir); fi.Mode().Perm() != 0o750 {
		t.Errorf("dir mode %v", fi.Mode().Perm())
	}
	if fi, _ := os.Stat(filepath.Join(dir, "events-2026-11-08.jsonl")); fi.Mode().Perm() != 0o640 {
		t.Errorf("file mode %v", fi.Mode().Perm())
	}

	all, err := store.Read(dir, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 || all[0].Subject != "a" || all[2].Subject != "c" || !all[1].Time.Equal(at(8, 1)) {
		t.Fatalf("read %+v", all)
	}
	recent, _ := store.Read(dir, at(8, 1))
	if len(recent) != 2 || recent[0].Subject != "b" {
		t.Fatalf("since: %+v", recent)
	}
}

func TestReadSkipsBadLinesAndMissingDir(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "events-2026-11-08.jsonl"), []byte("not json\n{\"kind\":\"package\",\"subject\":\"x\",\"time\":\"2026-11-08T00:00:00Z\"}\n"), 0o640)
	got, err := store.Read(dir, time.Time{})
	if err != nil || len(got) != 1 || got[0].Subject != "x" {
		t.Fatalf("got %+v, %v", got, err)
	}
	if got, err := store.Read(filepath.Join(dir, "missing"), time.Time{}); err != nil || len(got) != 0 {
		t.Fatalf("missing dir: %+v, %v", got, err)
	}
}

func TestPrune(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"events-2026-08-09.jsonl", "events-2026-08-10.jsonl", "events-2026-11-08.jsonl", "notes.txt"} {
		os.WriteFile(filepath.Join(dir, n), nil, 0o640)
	}
	for _, n := range []string{"live-20260809T120000Z", "live-20261108T120000Z", "20260801T000000Z", "zfs-down-2026-11-04"} {
		os.Mkdir(filepath.Join(dir, n), 0o750)
		os.WriteFile(filepath.Join(dir, n, "index.json"), nil, 0o640)
	}
	removed, err := store.Prune(dir, at(8, 12), 90*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	// 90 days before 2026-11-08 is 2026-08-10: that day is kept.
	want := []string{"20260801T000000Z", "events-2026-08-09.jsonl", "live-20260809T120000Z"}
	if !slices.Equal(removed, want) {
		t.Fatalf("removed %v, want %v", removed, want)
	}
	left, _ := os.ReadDir(dir)
	if len(left) != 5 {
		t.Fatalf("left %d entries", len(left))
	}
}
