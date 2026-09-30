package carson

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
		return m.takeOver(t, on)
	}
	return m.takeUp(repo, name)
}

// takeOver makes an ended agent's task the running session's own, in the task's worktree as it is: the previous owner is kept in the
// new record, and no file of the task is touched.
func (m Machine) takeOver(t task, on string) ([]string, error) {
	name := t.branch
	if t.admin == "" {
		return nil, refuse(failed, "the owner record of %s cannot be found: git keeps no administrative folder that points back to its worktree.", name)
	}
	record, found, err := readOwner(t.admin)
	switch {
	case err != nil:
		return nil, refuse(failed, "the owner record of %s cannot be read (%v).", name, err)
	case !found:
		return nil, refuse(refused, "%s was made outside carson, so whose it is cannot be told; that is the master's to settle.", name)
	}
	me, unobserved := m.ownerRecord(name)
	if sameOwner(record, me) {
		return nil, refuse(refused, "%s is already yours, at %s; work there.", name, t.path)
	}
	switch state, why := m.livenessOf(record); state {
	case live:
		return nil, refuse(refused, "%s belongs to %s, which is live; only an ended agent's task is adopted.", name, ownerName(record))
	case unknown:
		return nil, refuse(refused, "%s belongs to %s, whose state is unknown (%s); only an agent seen to have ended gives up its task.", name, ownerName(record), why)
	}
	if _, err := os.Stat(t.path); errors.Is(err, fs.ErrNotExist) {
		return nil, refuse(refused, "%s's worktree folder, %s, is gone, so the task cannot be adopted where it is; that is the master's to settle.", name, t.path)
	}
	previous := record
	previous.Previous = nil
	me.Previous = append(record.Previous, previous)
	err = replaceOwner(t.admin, me)
	if errors.Is(err, errOwned) {
		return nil, refuse(refused, "%s was adopted meanwhile by another session.", name)
	}
	if err != nil {
		return nil, refuse(failed, "the owner record of %s could not be replaced (%v); it is left as it was.", name, err)
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
	_, noBranch := git(repo.top, "rev-parse", "--verify", "-q", "refs/heads/"+name)
	_, noAbandoned := git(repo.top, "rev-parse", "--verify", "-q", "refs/heads/abandoned/"+name)
	if noBranch != nil && noAbandoned != nil {
		return nil, refuse(refused, "no task or branch is named %s, and no abandoned work either. Start it with: carson start %s", name, name)
	}
	from := name
	if noBranch != nil {
		from = "abandoned/" + name
	}
	ahead, err := repo.count("main.." + from)
	if err != nil {
		return nil, refuse(failed, "what branch %s holds against main cannot be read (%s). Nothing was changed.", from, reason(err))
	}
	if ahead == 0 && from == name {
		blocks := ""
		if noAbandoned == nil {
			blocks = fmt.Sprintf(", and its name stands in the way of the abandoned work on abandoned/%s", name)
		}
		return nil, refuse(refused, "branch %s holds nothing main lacks%s. Remove it with carson remove %s, then adopt again.", name, blocks, name)
	}
	home := m.Env("HOME")
	if !filepath.IsAbs(home) {
		return nil, refuse(failed, "HOME does not name a folder, so there is no ~/.worktrees to adopt the task in. Nothing was changed.")
	}
	folder := repo.taskFolder(filepath.Clean(home), name)
	if _, err := os.Stat(folder); err == nil {
		return nil, refuse(refused, "%s already exists, and is not a worktree of this task. Nothing was changed.", folder)
	}
	if from != name {
		if _, err := git(repo.top, "branch", "-m", from, name); err != nil {
			return nil, refuse(failed, "branch %s could not be renamed %s (%s). Nothing was changed.", from, name, reason(err))
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
		return nil, refuse(failed, "its worktree is made at %s, but its owner record could not be written (%s): it shows as made outside carson until that is put right.", folder, reason(err))
	}
	what := fmt.Sprintf("branch %s, left without a worktree with %s not on main,", name, plural(ahead, "commit"))
	if from != name {
		what = fmt.Sprintf("its abandoned work, %s not on main, now back on branch %s,", plural(ahead, "commit"), name)
	}
	said := []string{fmt.Sprintf("Adopted %s: %s is in %s, owned by %s.", name, what, folder, ownerName(record))}
	if from == name && noAbandoned == nil {
		said = append(said, fmt.Sprintf("Earlier work on %s, declared abandoned, is still kept as branch abandoned/%s.", name, name))
	}
	if unobserved != "" {
		said = append(said, unobserved)
	}
	return said, nil
}
