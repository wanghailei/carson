package main

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unicode"
)

const noOwnerHeading = "No owner record (made outside carson, so whose they are cannot be told; a person must settle them):"

// status shows main against GitHub, the main working tree, every task grouped by the session that owns it, the tasks carson does not
// own last, and the branches of tasks declared abandoned. It changes nothing.
func status(m Machine, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(m.Out, "carson status takes no arguments; it shows every task.")
		return refused
	}
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		fmt.Fprintf(m.Out, notARepository+"\n", m.Dir)
		return failed
	}
	if err != nil {
		fmt.Fprintf(m.Out, unreadableRepository+"\n", reason(err))
		return failed
	}
	fmt.Fprintln(m.Out, repo.mainAgainstGitHub())
	fmt.Fprintln(m.Out, repo.mainTree())
	m.showTasks(repo)
	repo.showAbandoned(m)
	return done
}

func (m Machine) showTasks(repo *repository) {
	tasks := repo.tasks()
	if len(tasks) == 0 {
		fmt.Fprintln(m.Out, "No tasks under way.")
		return
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
}

// showAbandoned lists the branches of tasks declared abandoned, and how to take one up again.
func (r *repository) showAbandoned(m Machine) {
	out, err := git(r.top, "for-each-ref", "--format=%(refname:short)", "refs/heads/abandoned/")
	if err != nil {
		fmt.Fprintf(m.Out, "Abandoned tasks: cannot be listed (%s).\n", reason(err))
		return
	}
	branches := lines(out)
	if len(branches) == 0 {
		return
	}
	checkedOut := map[string]bool{}
	for _, w := range r.worktrees {
		checkedOut[w.branch] = true
	}
	shown := false
	for _, branch := range branches {
		if checkedOut[branch] {
			continue // it is listed with the tasks
		}
		if !shown {
			fmt.Fprintln(m.Out, "Abandoned tasks (take one up again with: carson adopt <task>):")
			shown = true
		}
		held := "what it holds against main is unknown"
		if ahead, err := r.count("main.." + branch); err == nil {
			held = plural(ahead, "commit") + " not on main"
		}
		fmt.Fprintf(m.Out, "  %s: branch %s at %s, %s.\n", strings.TrimPrefix(branch, "abandoned/"), branch, r.short(branch), held)
	}
}

// ownerHeading names a session and whether it is live: "Claude session 4e7a91d2 on this-mac, live:".
func (m Machine) ownerHeading(record Record) string {
	state, why := m.livenessOf(record)
	said := state.String()
	if state == unknown {
		said += " (" + why + ")"
	}
	return capitalised(ownerName(record)) + ", " + said + ":"
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
