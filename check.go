package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// The checks carson land runs in the task's worktree before main moves: first the land checks carson's own configuration lists for
// every repository on the machine, each given the range of the commits the landing brings to GitHub, then the repository's
// bin/check. Each must exit 0 and leave the task as it found it. A land check is how a rule that holds in every repository — one
// change to a commit, say — is checked once for all of them, rather than by a copy in each repository's bin/check that protects only
// that repository. carson knows nothing of what a check looks at.

// configurationFile is carson's configuration, by the name a person knows it. carson reads it on each landing and never writes it.
const configurationFile = "~/.carson/config.json"

// configuration is what carson's configuration says. Its one setting is the land checks, each a command given by its full path:
//
//	{"land": {"checks": ["~/bin/check-commits"]}}
//
// Settings carson does not know are left alone, so a file written for Carson 4 still reads, as one with no land checks.
type configuration struct {
	Land struct {
		Checks []string `json:"checks"`
	} `json:"land"`
}

// cannotCheck ends every refusal over the land checks' configuration. A check carson was told to run is never skipped, so a landing it
// cannot check is refused; and what the configuration says is a person's to settle, not an agent's to edit its way past.
const cannotCheck = ", and carson lands nothing it cannot check. Nothing was changed; " + settled + ", and run carson land %s again once it is settled."

// landCheck is one land check: as the configuration lists it, and the file carson runs for it.
type landCheck struct {
	listed string // "~/bin/check-commits"
	path   string // the same with ~ made the home folder
}

// landChecks are the land checks carson's configuration lists, each found as a file carson can run, or why carson cannot land task: a
// configuration it cannot read, or a check it could not run. No configuration is no land checks.
func (m Machine) landChecks(task string) ([]landCheck, error) {
	// A home that is not there would hold no configuration, and so no land checks: the landing would go unchecked, so it is refused.
	home := m.Env("HOME")
	if info, err := os.Stat(home); err != nil || !info.IsDir() || !filepath.IsAbs(home) {
		return nil, refuse(failed, "HOME does not name a folder, so carson's configuration, %s, cannot be read, and carson lands nothing it cannot check. Nothing was changed; set HOME to your home folder, then run carson land %s again.", configurationFile, task)
	}
	content, err := os.ReadFile(filepath.Join(home, ".carson", "config.json"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, refuse(refused, "%s cannot be read (%v), so which land checks apply cannot be told"+cannotCheck, configurationFile, err, task)
	}
	var said configuration
	if err := json.Unmarshal(content, &said); err != nil {
		return nil, refuse(refused, "%s is not JSON whose land.checks is a list of commands (%v), so which land checks apply cannot be told"+cannotCheck, configurationFile, err, task)
	}
	checks := make([]landCheck, len(said.Land.Checks))
	for i, listed := range said.Land.Checks {
		if checks[i], err = findLandCheck(home, listed, task); err != nil {
			return nil, err
		}
	}
	return checks, nil
}

// findLandCheck finds the file a land check, as listed, names, and refuses one carson could not run. A check is given by its full
// path, or by one starting ~/ in home: a bare name would be looked for in folders that differ from one shell to the next.
func findLandCheck(home, listed, task string) (landCheck, error) {
	path := listed
	if strings.HasPrefix(listed, "~/") {
		path = filepath.Join(home, listed[2:])
	}
	if !filepath.IsAbs(path) {
		return landCheck{}, refuse(refused, "the land check %q, listed in %s, is not a full path starting / or ~/"+cannotCheck, listed, configurationFile, task)
	}
	_, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return landCheck{}, refuse(refused, "the land check %s, listed in %s, does not exist"+cannotCheck, listed, configurationFile, task)
	case err != nil:
		return landCheck{}, refuse(refused, "the land check %s, listed in %s, cannot be looked at (%v)"+cannotCheck, listed, configurationFile, err, task)
	}
	// LookPath asks the system whether carson's own user may run the file, which its mode alone does not say: 0641 lets others run it,
	// not its owner. A folder is no executable file either.
	if _, err := exec.LookPath(path); err != nil {
		return landCheck{}, refuse(refused, "the land check %s, listed in %s, is not an executable file"+cannotCheck, listed, configurationFile, task)
	}
	return landCheck{listed: listed, path: path}, nil
}

// on is the land check as it runs on a task's commits, given as a range git reads, such as refs/remotes/github/main..refs/heads/fix-login.
func (c landCheck) on(commits, task string) check {
	return check{
		name:   c.listed,
		called: fmt.Sprintf("the land check %s %s, from %s,", c.listed, commits, configurationFile),
		fix:    fmt.Sprintf("Fix what %s reports in %s's commits", c.listed, task),
		path:   c.path,
		args:   []string{commits},
	}
}

// repositoryCheck is the repository's own bin/check in the task's worktree dir, and whether the repository declares one.
func repositoryCheck(dir string) (check, bool) {
	path := filepath.Join(dir, "bin", "check")
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return check{}, false
	}
	return check{name: "bin/check", called: "bin/check", fix: "Fix what bin/check reports, commit", path: path}, true
}

// check is one check as carson land runs it.
type check struct {
	name   string // as the landing names it once it has passed: "~/bin/check-commits", "bin/check"
	called string // as a refusal names it, with what it was given, so it can be run again by hand
	fix    string // what to do when it fails, before carson land is run again
	path   string
	args   []string
}

// run runs the check in the task's worktree dir, and says how it failed — with the end of what it printed — or nil when it passed. It
// stays in carson's process group, so Ctrl-C stops both.
func (c check) run(dir string) error {
	command := exec.Command(c.path, c.args...)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err == nil {
		return nil
	}
	exit := err.Error()
	var failure *exec.ExitError
	if errors.As(err, &failure) {
		exit = fmt.Sprintf("exit %d", failure.ExitCode())
	}
	tail := lines(strings.TrimRight(string(output), "\n"))
	if len(tail) == 0 {
		return refuse(refused, "%s failed (%s). It printed nothing.", c.called, exit)
	}
	if len(tail) > 20 {
		tail = tail[len(tail)-20:]
	}
	return refuse(refused, "%s failed (%s). Its output ends:\n%s", c.called, exit, strings.Join(tail, "\n"))
}

// checks are the checks one landing runs, in order: the land checks, then the repository's bin/check when it declares one.
type checks struct {
	each       []check
	repository bool // whether the repository declares a bin/check
}

// passed says, for the landing's report, which checks passed.
func (c checks) passed() string {
	names := make([]string, len(c.each))
	for i, each := range c.each {
		names[i] = each.name
	}
	switch {
	case len(names) == 0:
		return "No checks declared (no bin/check)."
	case !c.repository:
		return "Checks: " + inWords(names) + " passed; the repository declares none of its own (no bin/check)."
	}
	return "Checks: " + inWords(names) + " passed."
}

// inWords lists names as a sentence does: "a", "a and b", "a, b and c".
func inWords(names []string) string {
	if len(names) < 2 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}
