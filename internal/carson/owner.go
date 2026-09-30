package carson

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
// lives in git's administrative folder for the worktree, so it goes when the worktree goes and never shows in anyone's files.
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
	Merged    string    `json:"merged,omitempty"`
}

const ownerFile = "carson-owner.json"

// readOwner reads the owner record in a worktree's administrative folder. found is false when the worktree has none: it was made
// outside carson.
func readOwner(admin string) (record Record, found bool, err error) {
	data, err := os.ReadFile(filepath.Join(admin, ownerFile))
	if errors.Is(err, fs.ErrNotExist) {
		return Record{}, false, nil
	}
	if err != nil {
		return Record{}, false, err
	}
	if err := json.Unmarshal(data, &record); err != nil {
		return Record{}, false, fmt.Errorf("the owner record in %s cannot be read: %w", admin, err)
	}
	return record, true, nil
}

// errOwned is a worktree that already has an owner record: another session recorded it first.
var errOwned = errors.New("the worktree already has an owner record")

// createOwner writes a new owner record where there is none, linking it into place in one step that cannot overwrite: of two sessions
// recording the same worktree, exactly one succeeds, and the other gets errOwned.
func createOwner(admin string, record Record) error {
	data, err := json.MarshalIndent(record, "", "\t")
	if err != nil {
		return err
	}
	aside := filepath.Join(admin, ownerFile+"."+strconv.Itoa(os.Getpid())+".new")
	if err := os.WriteFile(aside, append(data, '\n'), 0o644); err != nil {
		return err
	}
	defer os.Remove(aside)
	if err := os.Link(aside, filepath.Join(admin, ownerFile)); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return errOwned
		}
		return err
	}
	return nil
}

// writeOwner writes the record in one step — written aside, then renamed into place — so a crash never leaves half a record.
func writeOwner(admin string, record Record) error {
	data, err := json.MarshalIndent(record, "", "\t")
	if err != nil {
		return err
	}
	aside := filepath.Join(admin, ownerFile+".new")
	if err := os.WriteFile(aside, append(data, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(aside, filepath.Join(admin, ownerFile))
}
