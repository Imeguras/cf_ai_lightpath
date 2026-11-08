// Package store keeps the event timeline as JSON lines, one file per UTC
// day (events-YYYY-MM-DD.jsonl), and removes old data by the date in its
// name.
package store

import (
	"bufio"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"time"

	"lightpath/probe/events"
)

// Append adds e as one JSON line to dir/events-<UTC day of e.Time>.jsonl,
// creating dir (0750) and the file (0640) when missing.
func Append(dir string, e events.Event) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o750); err != nil {
		return err
	}
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	name := filepath.Join(dir, "events-"+e.Time.UTC().Format("2006-01-02")+".jsonl")
	f, err := os.OpenFile(name, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o640)
	if err != nil {
		return err
	}
	_, werr := f.Write(append(line, '\n'))
	return errors.Join(werr, f.Close())
}

// Read returns every event in dir's day files whose Time is at or after
// since, oldest first (file order, then line order). Lines that are not
// valid events are skipped. A missing dir reads as no events.
func Read(dir string, since time.Time) ([]events.Event, error) {
	files, err := filepath.Glob(filepath.Join(dir, "events-*.jsonl"))
	if err != nil {
		return nil, err
	}
	slices.Sort(files)
	var out []events.Event
	for _, name := range files {
		f, err := os.Open(name)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, err
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64*1024), 1024*1024)
		for sc.Scan() {
			var e events.Event
			if json.Unmarshal(sc.Bytes(), &e) == nil && e.Kind != "" && !e.Time.Before(since) {
				out = append(out, e)
			}
		}
		err = errors.Join(sc.Err(), f.Close())
		if err != nil {
			return nil, err
		}
	}
	return out, nil
}

// Prune removes every entry directly under dir (file or directory) whose
// name contains a date, as YYYY-MM-DD or YYYYMMDD, older than keep before
// now (by UTC day). Entries without a date are left alone. It returns the
// removed names, sorted.
func Prune(dir string, now time.Time, keep time.Duration) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	cutoff := now.UTC().Add(-keep).Truncate(24 * time.Hour)
	var removed []string
	for _, e := range entries {
		m := dateRE.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		day, err := time.Parse("2006-01-02", m[1]+"-"+m[2]+"-"+m[3])
		if err != nil || !day.Before(cutoff) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			return removed, err
		}
		removed = append(removed, e.Name())
	}
	slices.Sort(removed)
	return removed, nil
}

var dateRE = regexp.MustCompile(`(20\d\d)-?(\d\d)-?(\d\d)`)
