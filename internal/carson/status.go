package carson

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
)

const noOwnerHeading = "No owner record (made outside carson; whose it is is the master's to settle):"

// status shows main against GitHub, the main working tree, and every task grouped by the session that owns it. It changes nothing.
func status(m Machine) int {
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		fmt.Fprintf(m.Out, "carson: %s is not inside a git repository.\n", m.Dir)
		return refused
	}
	if err != nil {
		fmt.Fprintf(m.Out, "carson: the repository could not be read: %v\n", err)
		return failed
	}
	fmt.Fprintln(m.Out, repo.mainAgainstGitHub())
	fmt.Fprintln(m.Out, repo.mainTree())
	tasks, admins, err := repo.tasks()
	if err != nil {
		fmt.Fprintf(m.Out, "carson: the worktrees could not be listed: %v\n", err)
		return failed
	}
	if len(tasks) == 0 {
		fmt.Fprintln(m.Out, "No tasks.")
		return done
	}
	var headings []string
	groups := map[string][]string{}
	for _, task := range tasks {
		heading := noOwnerHeading
		if record, found, err := readOwner(admins[task.path]); err != nil {
			heading = "Owner record unreadable (" + err.Error() + "):"
		} else if found {
			heading = m.ownerHeading(record)
		}
		if _, seen := groups[heading]; !seen {
			headings = append(headings, heading)
		}
		groups[heading] = append(groups[heading], fmt.Sprintf("%s at %s: %s", taskName(task), task.path, repo.taskState(task)))
	}
	// Tasks with no owner record come last: nothing carson does touches them.
	for i, heading := range headings {
		if heading == noOwnerHeading {
			headings = append(append(headings[:i:i], headings[i+1:]...), heading)
			break
		}
	}
	fmt.Fprintln(m.Out, "Tasks:")
	for _, heading := range headings {
		fmt.Fprintln(m.Out, "  "+heading)
		for _, line := range groups[heading] {
			fmt.Fprintln(m.Out, "    "+line)
		}
	}
	return done
}

// ownerHeading names a session and whether it is live: "Claude session 4e7a91d2 on this-mac, live:".
func (m Machine) ownerHeading(record Record) string {
	state, reason := m.livenessOf(record)
	var said string
	switch state {
	case live:
		said = "live"
	case ended:
		said = "ended"
	default:
		said = "unknown (" + reason + ")"
	}
	if record.Harness == "terminal" {
		return fmt.Sprintf("A terminal, process %d, on %s, %s:", record.PID, record.Machine, said)
	}
	session, _, _ := strings.Cut(record.Session, "-")
	return fmt.Sprintf("%s session %s on %s, %s:", capitalised(record.Harness), session, record.Machine, said)
}

func taskName(w worktree) string {
	if w.branch != "" {
		return w.branch
	}
	return filepath.Base(w.path)
}

func capitalised(word string) string {
	if word == "" {
		return word
	}
	runes := []rune(word)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}
