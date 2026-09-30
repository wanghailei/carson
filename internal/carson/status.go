package carson

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
)

const noOwnerHeading = "No owner record (made outside carson; whose it is is the master's to settle):"

// status shows main against GitHub, the main working tree, and every task grouped by the session that owns it, the tasks carson does
// not own last. It changes nothing.
func status(m Machine) int {
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		fmt.Fprintf(m.Out, "carson: %s is not inside a git repository.\n", m.Dir)
		return failed
	}
	if err != nil {
		fmt.Fprintf(m.Out, "carson: the repository could not be read (%s).\n", reason(err))
		return failed
	}
	fmt.Fprintln(m.Out, repo.mainAgainstGitHub())
	fmt.Fprintln(m.Out, repo.mainTree())
	tasks := repo.tasks()
	if len(tasks) == 0 {
		fmt.Fprintln(m.Out, "No tasks.")
		return done
	}
	var headings, unowned []string
	groups := map[string][]string{}
	for _, t := range tasks {
		line := fmt.Sprintf("%s at %s: %s", t.name(), t.path, repo.state(t))
		heading := ""
		if t.admin == "" {
			heading = "Owner unknown (git keeps no administrative folder that points to it):"
		} else if record, found, err := readOwner(t.admin); err != nil {
			heading = "Owner record unreadable (" + err.Error() + "):"
		} else if !found {
			unowned = append(unowned, line)
			continue
		} else {
			heading = m.ownerHeading(record)
		}
		if _, seen := groups[heading]; !seen {
			headings = append(headings, heading)
		}
		groups[heading] = append(groups[heading], line)
	}
	if len(unowned) > 0 {
		headings = append(headings, noOwnerHeading)
		groups[noOwnerHeading] = unowned
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
	state, why := m.livenessOf(record)
	said := map[liveness]string{live: "live", ended: "ended", unknown: "unknown (" + why + ")"}[state]
	if record.Harness == "terminal" {
		return fmt.Sprintf("A terminal, process %d, on %s, %s:", record.PID, record.Machine, said)
	}
	session, _, _ := strings.Cut(record.Session, "-")
	return fmt.Sprintf("%s session %s on %s, %s:", capitalised(record.Harness), session, record.Machine, said)
}

func (t task) name() string {
	if t.branch != "" {
		return t.branch
	}
	return filepath.Base(t.path)
}

func capitalised(word string) string {
	if word == "" {
		return word
	}
	runes := []rune(word)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}
