package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

// landingLockFile is the repository's landing lock, in git's common folder: held only while one carson lands a task, so two landings never move
// main at once.
const landingLockFile = "carson-land.lock"

// lockLanding takes the landing lock for task. A lock whose carson has ended is taken over, and said; a live one refuses the landing, to be
// run again when that one has finished. release gives the lock back, if it is still this carson's.
func (r *repository) lockLanding(m Machine, task string) (release func(), note string, err error) {
	path := filepath.Join(r.common, landingLockFile)
	holder, _ := m.ownerRecord(task)
	holder.PID, holder.Started, holder.Created = m.PID, "", time.Now().UTC()
	if started, err := m.Processes.Started(m.PID); err == nil {
		holder.Started = started
	}
	for attempt := 0; attempt < 4; attempt++ {
		err := createRecordFile(path, holder)
		if err == nil {
			return func() {
				if current, found, err := readRecordFile(path); err == nil && found && current.PID == holder.PID && current.Created.Equal(holder.Created) {
					os.Remove(path)
				}
			}, note, nil
		}
		if !errors.Is(err, errOwned) {
			return nil, "", refuse(failed, "the landing lock could not be taken (%v). Nothing was changed; run carson land %s again once that is cleared.", err, task)
		}
		held, found, err := readRecordFile(path)
		if err != nil {
			return nil, "", refuse(failed, "the landing lock is held, and cannot be read (%v). Nothing was changed; run carson land %s again once that is cleared.", err, task)
		}
		if !found {
			continue // given back between the two looks
		}
		state, why := m.livenessOf(held)
		switch state {
		case live:
			return nil, "", refuse(failed, "another landing is running in this repository — %s, by %s. Run carson land %s again when it has finished. Nothing was changed.", held.Task, ownerName(held), task)
		case unknown:
			return nil, "", refuse(failed, "the landing lock is held by %s's landing, by %s, whose state is unknown (%s). Nothing was changed; run carson land %s again when that landing has finished, and if its session is gone, a person must settle it.", held.Task, ownerName(held), why, task)
		}
		// The carson that held it has ended: its lock is only a leftover. It is moved aside rather than removed, and only when the file
		// moved is the one judged stale is it cleared — so two carsons clearing the same leftover never clear each other's new lock.
		aside := path + "." + strconv.Itoa(os.Getpid()) + ".stale"
		if err := os.Rename(path, aside); err != nil {
			continue // another carson moved it first; look again
		}
		moved, _, err := readRecordFile(aside)
		if err != nil || moved.PID != held.PID || !moved.Created.Equal(held.Created) {
			// A fresh lock was moved by mistake: put it back where it was, unless another has been taken meanwhile.
			os.Link(aside, path)
			os.Remove(aside)
			continue
		}
		os.Remove(aside)
		note = "The landing lock left by an ended carson (" + held.Task + ", by " + ownerName(held) + ") is taken over."
	}
	return nil, "", refuse(failed, "the landing lock could not be taken; another landing keeps taking it. Nothing was changed; run carson land %s again in a moment.", task)
}
