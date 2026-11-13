package scrub

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"

	"lightpath/probe/inventory"
)

var fixtureID = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

// Fixtures scrubs one or more inventory fixture directories (as written by
// inventory.WriteFixtures) into a new public directory out.
//
// Directories are read in order; a fixture in a later directory replaces one
// with the same ID from an earlier directory, keeping the position where the
// ID first appeared. IDs in the Config's Drop list are left out entirely,
// both as files and from the manifest. The manifest's target and creation
// time come from the last directory: the set shows the state as of the
// latest run.
//
// Every string in each Result (Argv, Stdout, Stderr, Error) and the
// manifest's Target and entry Errors pass through Text. Stdout then passes
// through Versions. The output is meant
// to be published, so directories are created with mode 0755 and files with
// mode 0644; missing parents are created.
//
// It fails if out already exists. After writing, it re-reads every output
// file and checks it with Leaks; if anything leaked, it removes out and
// returns an error naming the file.
func (s *Scrubber) Fixtures(ins []string, out string) error {
	if _, err := os.Lstat(out); err == nil {
		return fmt.Errorf("output directory %s already exists", out)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	// Read everything before creating out, so a bad input leaves nothing behind.
	var latest inventory.Manifest
	var order []string
	results := map[string]inventory.Result{}
	for _, in := range ins {
		m, err := readJSON[inventory.Manifest](filepath.Join(in, "index.json"))
		if err != nil {
			return err
		}
		latest = m
		for _, e := range m.Entries {
			if !fixtureID.MatchString(e.ID) || e.ID == "index" {
				return fmt.Errorf("%s: invalid fixture ID %q", in, e.ID)
			}
			r, err := readJSON[inventory.Result](filepath.Join(in, e.ID+".json"))
			if err != nil {
				return err
			}
			if _, ok := results[e.ID]; !ok {
				order = append(order, e.ID)
			}
			results[e.ID] = r
		}
	}

	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	if err := os.Mkdir(out, 0o755); err != nil {
		return err
	}
	if err := s.writeFixtures(out, latest, order, results); err != nil {
		os.RemoveAll(out)
		return err
	}
	if err := s.checkFixtures(out); err != nil {
		os.RemoveAll(out)
		return err
	}
	return nil
}

func (s *Scrubber) writeFixtures(out string, latest inventory.Manifest, order []string, results map[string]inventory.Result) error {
	if err := os.Chmod(out, 0o755); err != nil {
		return err
	}
	// The manifest takes the latest run's target (scrubbed) and creation time.
	m := inventory.Manifest{Target: s.Text(latest.Target), CreatedAt: latest.CreatedAt}
	for _, id := range order {
		if s.drop[id] {
			continue
		}
		r := results[id]
		for i, a := range r.Argv {
			r.Argv[i] = s.Text(a)
		}
		r.Stdout, r.Stderr, r.Error = s.Versions(id, s.Text(r.Stdout)), s.Text(r.Stderr), s.Text(r.Error)
		file := id + ".json"
		if err := writePublicJSON(filepath.Join(out, file), r); err != nil {
			return err
		}
		m.Entries = append(m.Entries, inventory.ManifestEntry{
			ID: id, File: file, ExitCode: r.ExitCode, TimedOut: r.TimedOut, Truncated: r.Truncated, Error: r.Error,
		})
	}
	return writePublicJSON(filepath.Join(out, "index.json"), m)
}

// checkFixtures re-reads what was written and runs Leaks on every string.
func (s *Scrubber) checkFixtures(out string) error {
	m, err := readJSON[inventory.Manifest](filepath.Join(out, "index.json"))
	if err != nil {
		return err
	}
	strs := []string{m.Target}
	for _, e := range m.Entries {
		strs = append(strs, e.Error)
	}
	if leaks := s.leaksIn(strs); len(leaks) > 0 {
		return fmt.Errorf("index.json still contains %v", leaks)
	}
	for _, e := range m.Entries {
		r, err := readJSON[inventory.Result](filepath.Join(out, e.File))
		if err != nil {
			return err
		}
		if leaks := s.leaksIn(append(append([]string{}, r.Argv...), r.Stdout, r.Stderr, r.Error)); len(leaks) > 0 {
			return fmt.Errorf("%s still contains %v", e.File, leaks)
		}
	}
	return nil
}

func (s *Scrubber) leaksIn(strs []string) []string {
	var all []string
	for _, str := range strs {
		all = append(all, s.Leaks(str)...)
	}
	return all
}

func readJSON[T any](path string) (T, error) {
	var v T
	data, err := os.ReadFile(path)
	if err != nil {
		return v, err
	}
	if err := json.Unmarshal(data, &v); err != nil {
		return v, fmt.Errorf("%s: %w", path, err)
	}
	return v, nil
}

func writePublicJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o644); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
