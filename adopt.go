package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// adopt makes a task the running session's own (will 11.2): the task of an agent seen to have ended, in its own worktree; or work
// declared abandoned, or a branch left without a worktree, in a new worktree. The adoption is recorded, and nothing is discarded. An
// owner that is live, or whose state is unknown, keeps its task.
func adopt(m Machine, args []string) int {
	name, err := oneTask(args, "carson adopt")
	if err == nil {
		err = newTaskName(name)
	}
	var said []string
	if err == nil {
		said, err = m.adoptTask(name)
	}
	for _, line := range said {
		fmt.Fprintln(m.Out, line)
	}
	if err != nil {
		fmt.Fprintln(m.Out, "Not adopted: "+err.Error())
		return codeOf(err)
	}
	return done
}

func (m Machine) adoptTask(name string) ([]string, error) {
	repo, err := m.repository()
	if err != nil {
		return nil, err
	}
	if t, on, found := repo.task(name); found {
		return m.takeOver(repo, t, on)
	}
	return m.takeUp(repo, name)
}

// takeOver makes an ended agent's task the running session's own, in the task's worktree as it is: the previous owner is kept in the
// new record, and no file of the task is touched.
func (m Machine) takeOver(repo *repository, t task, on string) ([]string, error) {
	name := t.branch
	if t.admin == "" {
		return nil, refuse(failed, "the owner record of %s cannot be found: git keeps no administrative folder that points back to its worktree. Run git worktree repair in the main working tree, then carson adopt %s again.", name, name)
	}
	record, found, err := readOwner(t.admin)
	switch {
	case err != nil:
		return nil, refuse(failed, "the owner record of %s cannot be read (%v); "+settled+".", name, err)
	case !found:
		return nil, refuse(refused, "%s was made outside carson, so whose it is cannot be told; "+settled+".", name)
	}
	me, unobserved := m.ownerRecord(name)
	if sameOwner(record, me) {
		return nil, repo.yours(name, t.path, record)
	}
	switch state, why := m.livenessOf(record); state {
	case live:
		return nil, refuse(refused, "%s belongs to %s, which is live; only an ended agent's task is adopted. Leave it to that session.", name, ownerName(record))
	case unknown:
		return nil, refuse(refused, "%s belongs to %s, whose state is unknown (%s); only an agent seen to have ended gives up its task. Leave it to that session; if it is gone, a person must settle it.", name, ownerName(record), why)
	}
	previous := record
	previous.Previous = nil
	me.Previous = append(record.Previous, previous)
	me.Landed = record.Landed
	err = replaceOwner(t.admin, record, me)
	if errors.Is(err, errOwned) {
		return nil, refuse(refused, "%s was adopted meanwhile by another session; carson status shows whose it is now.", name)
	}
	if err != nil {
		return nil, refuse(failed, "the owner record of %s could not be replaced (%v); it is left as it was. Run carson adopt %s again once that is cleared.", name, err, name)
	}
	if _, err := os.Stat(t.path); errors.Is(err, fs.ErrNotExist) {
		return repo.adoptedWithoutFolder(t, record), nil
	}
	said := []string{fmt.Sprintf("Adopted %s from %s, which has ended: its worktree at %s is yours now, as it was left.", name, ownerName(record), t.path)}
	if on != "" {
		said = append(said, fmt.Sprintf("It is on %s, not its branch; switch it back there with git switch %s.", on, name))
	}
	if unobserved != "" {
		said = append(said, unobserved)
	}
	return said, nil
}

// takeUp makes work declared abandoned, or a branch left without a worktree, the running session's task, in a new worktree beside the
// repository. Abandoned work's branch takes the task's name again. Every check comes before any change.
func (m Machine) takeUp(repo *repository, name string) ([]string, error) {
	hasBranch, hasAbandoned := repo.hasBranch(name), repo.hasBranch("abandoned/"+name)
	if !hasBranch && !hasAbandoned {
		return nil, refuse(refused, "no task or branch is named %s, and no abandoned work either. Start it with: carson start %s", name, name)
	}
	from := name
	if !hasBranch {
		from = "abandoned/" + name
	}
	ahead, err := repo.notOnMain(from)
	if err != nil {
		return nil, refuse(failed, "what branch %s holds against main cannot be read (%s). Nothing was changed; run carson adopt %s again once that is cleared.", from, reason(err), name)
	}
	if ahead == 0 && from == name {
		if hasAbandoned {
			return nil, refuse(refused, "branch %s holds nothing main lacks, and its name stands in the way of the abandoned work on abandoned/%s. Remove it with carson remove %s, then adopt again to take up that work.", name, name, name)
		}
		return nil, refuse(refused, "branch %s holds nothing main lacks, so there is nothing to adopt. Remove it with: carson remove %s", name, name)
	}
	home := m.Env("HOME")
	if !filepath.IsAbs(home) {
		return nil, refuse(failed, "HOME does not name a folder, so there is no ~/.worktrees to adopt the task in. Nothing was changed; set HOME to your home folder, then run carson adopt %s again.", name)
	}
	folder := repo.taskFolder(filepath.Clean(home), name)
	if _, err := os.Stat(folder); err == nil {
		return nil, refuse(refused, "%s already exists, and is not a worktree of this task. Nothing was changed; move that folder out of the way, then run carson adopt %s again.", folder, name)
	}
	if from != name {
		if _, err := git(repo.top, "branch", "-m", from, name); err != nil {
			return nil, refuse(failed, "branch %s could not be renamed %s (%s). Nothing was changed; run carson adopt %s again once that is cleared.", from, name, reason(err), name)
		}
	}
	if _, err := git(repo.top, "worktree", "add", "-q", folder, name); err != nil {
		renamed := ""
		if from != name {
			renamed = fmt.Sprintf("Branch %s is now named %s. ", from, name)
		}
		return nil, refuse(failed, "its worktree could not be made (%s). %sRun carson adopt %s again once that is cleared.", reason(err), renamed, name)
	}
	record, unobserved := m.ownerRecord(name)
	admin, err := git(folder, "rev-parse", "--absolute-git-dir")
	if err == nil {
		err = createOwner(admin, record)
	}
	if err != nil {
		return nil, refuse(failed, "its worktree is made at %s, but its owner record could not be written (%s), so it shows as made outside carson; "+settled+".", folder, reason(err))
	}
	what := fmt.Sprintf("branch %s, left without a worktree with %s not on main,", name, plural(ahead, "commit"))
	if from != name {
		what = fmt.Sprintf("its abandoned work, %s not on main, now back on branch %s,", plural(ahead, "commit"), name)
	}
	said := []string{fmt.Sprintf("Adopted %s: %s is in %s, owned by %s.", name, what, folder, ownerName(record))}
	if from == name && hasAbandoned {
		said = append(said, fmt.Sprintf("Earlier work on %s, declared abandoned, is still kept as branch abandoned/%s.", name, name))
	}
	if unobserved != "" {
		said = append(said, unobserved)
	}
	return said, nil
}

// adoptedWithoutFolder says what an adopted task whose worktree folder is gone holds, and the one way on: to keep its commits as
// abandoned work, or, when main holds them all, to remove it.
func (r *repository) adoptedWithoutFolder(t task, previous Record) []string {
	said := fmt.Sprintf("Adopted %s from %s, which has ended. Its worktree folder, %s, is gone", t.branch, ownerName(previous), t.path)
	ahead, err := r.notOnMain(t.branch)
	switch {
	case err != nil:
		return []string{fmt.Sprintf("%s, and what its branch holds against main cannot be read (%s). Once that is cleared, keep its work with carson abandon %s, or, if main holds it all, remove it with carson remove %s.", said, reason(err), t.branch, t.branch)}
	case ahead > 0:
		return []string{fmt.Sprintf("%s: keep its %s with: carson abandon %s", said, plural(ahead, "commit"), t.branch)}
	}
	return []string{fmt.Sprintf("%s, and main holds all its work: remove it with: carson remove %s", said, t.branch)}
}
