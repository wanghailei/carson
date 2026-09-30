package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// Record is who owns a task's worktree: a harness session, known by its process and that process's start time, on one machine. It
// lives in git's administrative folder for the worktree, so it goes when the worktree goes and never shows in anyone's files. The landing
// lock is a record too, naming the carson that holds it.
type Record struct {
	Task      string    `json:"task"`
	Harness   string    `json:"harness"`
	Session   string    `json:"session"`
	PID       int       `json:"pid"`
	Started   string    `json:"process_started"`
	Machine   string    `json:"machine"`
	MachineID string    `json:"machine_id,omitempty"`
	Created   time.Time `json:"created"`
	Previous  []Record  `json:"previous,omitempty"`
	Landed    string    `json:"landed,omitempty"`
}

const ownerFile = "carson-owner.json"

// errOwned is a record file that already exists: another session recorded it first.
var errOwned = errors.New("the record already exists")

// readOwner reads the owner record in a worktree's administrative folder. found is false when the worktree has none: it was made
// outside carson.
func readOwner(admin string) (Record, bool, error) {
	return readRecordFile(filepath.Join(admin, ownerFile))
}

// createOwner writes a new owner record where there is none; of two sessions recording the same worktree, exactly one succeeds.
func createOwner(admin string, record Record) error {
	return createRecordFile(filepath.Join(admin, ownerFile), record)
}

// replaceOwner replaces a worktree's owner record, judged ended, with record, for an adoption. The record there is moved aside in one
// step that only one session can make, and kept only if it is the one judged: of two sessions adopting the same task exactly one
// succeeds, and the other gets errOwned, whether it comes while the first is adopting or after. If the new record then cannot be
// written, the old one is put back.
func replaceOwner(admin string, judged, record Record) error {
	path := filepath.Join(admin, ownerFile)
	aside := path + "." + strconv.Itoa(os.Getpid()) + ".old"
	if err := os.Rename(path, aside); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return errOwned
		}
		return err
	}
	if moved, found, err := readRecordFile(aside); err != nil || !found || !sameRecord(moved, judged) {
		os.Rename(aside, path)
		return errOwned
	}
	if err := createRecordFile(path, record); err != nil {
		if os.Link(aside, path) == nil {
			os.Remove(aside)
		}
		return err
	}
	return os.Remove(aside)
}

// sameRecord is whether two records are one: the same session's process, recorded at the same moment.
func sameRecord(a, b Record) bool {
	return a.Session == b.Session && a.PID == b.PID && a.Started == b.Started && a.Created.Equal(b.Created)
}

// writeOwner replaces a worktree's owner record.
func writeOwner(admin string, record Record) error {
	return writeRecordFile(filepath.Join(admin, ownerFile), record)
}

func readRecordFile(path string) (Record, bool, error) {
	var record Record
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Record{}, false, nil
	}
	if err != nil {
		return Record{}, false, err
	}
	if err := json.Unmarshal(data, &record); err != nil {
		return Record{}, false, fmt.Errorf("%s cannot be read: %w", path, err)
	}
	return record, true, nil
}

// writeAside writes the record beside path, under a name of this process's own, for renaming or linking into place.
func writeAside(path string, record Record) (string, error) {
	data, err := json.MarshalIndent(record, "", "\t")
	if err != nil {
		return "", err
	}
	aside := path + "." + strconv.Itoa(os.Getpid()) + ".new"
	return aside, os.WriteFile(aside, append(data, '\n'), 0o644)
}

// writeRecordFile writes the record in one step — written aside, then renamed into place — so a crash never leaves half a record.
func writeRecordFile(path string, record Record) error {
	aside, err := writeAside(path, record)
	if err != nil {
		return err
	}
	return os.Rename(aside, path)
}

// createRecordFile writes the record only where none is, linking it into place in one step that cannot overwrite: of two writers,
// exactly one succeeds and the other gets errOwned.
func createRecordFile(path string, record Record) error {
	aside, err := writeAside(path, record)
	defer os.Remove(aside)
	if err != nil {
		return err
	}
	if err := os.Link(aside, path); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return errOwned
		}
		return err
	}
	return nil
}
