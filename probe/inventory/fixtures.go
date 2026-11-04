package inventory

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Manifest is written as index.json next to the per-command fixture files.
type Manifest struct {
	Target    string          `json:"target"`
	CreatedAt time.Time       `json:"created_at"`
	Entries   []ManifestEntry `json:"entries"`
}

// ManifestEntry summarises one Result and names its fixture file.
type ManifestEntry struct {
	ID        string `json:"id"`
	File      string `json:"file"`
	ExitCode  int    `json:"exit_code"`
	TimedOut  bool   `json:"timed_out"`
	Truncated bool   `json:"truncated"`
	Error     string `json:"error,omitempty"`
}

const manifestName = "index"

// WriteFixtures saves results into a new directory dir: one "<ID>.json" per
// Result (the Result as JSON) and an "index.json" Manifest whose entries are
// in the same order as results.
//
// Fixtures are never overwritten: it fails if dir already exists. Missing
// parent directories are created. Raw output is private, so directories are
// created with mode 0700 and files with mode 0600.
//
// Before writing anything, it returns an error if any Result ID is not a
// valid command ID (see Validate), is duplicated, or is "index" (reserved
// for the manifest); in that case dir is not created.
func WriteFixtures(dir, target string, createdAt time.Time, results []Result) error {
	seen := make(map[string]bool, len(results))
	for _, r := range results {
		switch {
		case !validID(r.ID):
			return fmt.Errorf("invalid result ID %q", r.ID)
		case r.ID == manifestName:
			return fmt.Errorf("result ID %q is reserved", r.ID)
		case seen[r.ID]:
			return fmt.Errorf("duplicate result ID %q", r.ID)
		}
		seen[r.ID] = true
	}

	if err := os.MkdirAll(filepath.Dir(dir), 0o700); err != nil {
		return err
	}
	// Mkdir (not MkdirAll) fails if dir exists, which is what we want.
	if err := os.Mkdir(dir, 0o700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return fmt.Errorf("fixture directory %s already exists", dir)
		}
		return err
	}
	// The umask may have narrowed the mode further; set it exactly.
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}

	m := Manifest{Target: target, CreatedAt: createdAt, Entries: make([]ManifestEntry, 0, len(results))}
	for _, r := range results {
		file := r.ID + ".json"
		if err := writeJSON(filepath.Join(dir, file), r); err != nil {
			return err
		}
		m.Entries = append(m.Entries, ManifestEntry{
			ID: r.ID, File: file, ExitCode: r.ExitCode,
			TimedOut: r.TimedOut, Truncated: r.Truncated, Error: r.Error,
		})
	}
	return writeJSON(filepath.Join(dir, manifestName+".json"), m)
}

func writeJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
