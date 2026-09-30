package carson

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// remove removes a landed task's worktree and branch, by its owner, from outside the worktree. Every check comes before any change:
// it refuses while the task holds uncommitted files or commits main lacks, a git operation in it has stopped part way, it holds a git
// repository of its own, or a process of the user running carson works inside it. Ignored files are kept, never deleted, and the
// branch goes by git's safe delete.
func remove(m Machine, args []string) int {
	return m.removeOrAbandon(args, false)
}

// abandon keeps an unfinished task's work on a branch abandoned/<task>, what was uncommitted committed, and removes its worktree, by
// its owner, from outside the worktree, with the same checks as remove.
func abandon(m Machine, args []string) int {
	return m.removeOrAbandon(args, true)
}

func (m Machine) removeOrAbandon(args []string, abandoned bool) int {
	command, not := "carson remove", "Not removed: "
	if abandoned {
		command, not = "carson abandon", "Not abandoned: "
	}
	name, err := oneTask(args, command)
	if err != nil {
		fmt.Fprintln(m.Out, not+err.Error())
		return codeOf(err)
	}
	said, err := m.removeTask(name, abandoned)
	for _, line := range said {
		fmt.Fprintln(m.Out, line)
	}
	if err != nil {
		fmt.Fprintln(m.Out, not+err.Error())
		return codeOf(err)
	}
	return done
}

func (m Machine) removeTask(name string, abandoned bool) ([]string, error) {
	repo, err := m.repository()
	if err != nil {
		return nil, err
	}
	if name == "main" || name == "master" {
		return nil, refuse(refused, "%s is a trunk's name, not a task's.", name)
	}
	t, on, found := repo.task(name)
	if !found {
		return repo.removeLeftoverBranch(name, abandoned)
	}
	r, err := m.checkRemoval(repo, t, on, abandoned)
	if err != nil {
		return nil, err
	}
	if abandoned {
		return r.abandon(m)
	}
	return r.remove(m)
}

// task is the task whose branch is name, including one whose branch a stopped rebase is rewriting; or else the worktree carson started
// for the task name, which has since left its branch for what on says.
func (r *repository) task(name string) (t task, on string, found bool) {
	tasks := r.tasks()
	for _, t := range tasks {
		if t.branch == name || t.branch == "" && branchUnderRebase(t.path) == name {
			t.branch = name
			return t, "", true
		}
	}
	for _, t := range tasks {
		if record, found, err := readOwner(t.admin); t.admin != "" && err == nil && found && record.Task == name {
			on = "a detached HEAD"
			if t.branch != "" {
				on = "branch " + t.branch
			}
			t.branch = name
			return t, on, true
		}
	}
	return task{}, "", false
}

// removal is a task that has passed every check for carson remove or carson abandon, and what the checks found in it.
type removal struct {
	repo        *repository
	task        task
	record      Record
	gone        bool     // the worktree's folder is gone
	ahead       int      // commits the branch holds that main lacks
	uncommitted []string // what the worktree holds that its commit does not, ignored files apart
}

// checkRemoval checks, before anything is changed, that the task may be removed, or with abandoned, kept on a branch and its worktree
// removed. on is what the worktree has checked out when it is not the task's branch.
func (m Machine) checkRemoval(repo *repository, t task, on string, abandoned bool) (removal, error) {
	name := t.branch
	command, verb := "carson remove", "removes it"
	if abandoned {
		command, verb = "carson abandon", "abandons it"
	}
	again := command + " " + name + " again"
	if here, err := filepath.EvalSymlinks(m.Dir); err == nil && (here == t.path || strings.HasPrefix(here, t.path+"/")) {
		return removal{}, refuse(refused, "%s runs from outside the worktree it removes; run it from %s.", command, repo.top)
	}
	record, err := m.ownRecord(t, verb)
	if err != nil {
		return removal{}, err
	}
	if on != "" {
		return removal{}, offBranch(t, on, command+" "+name)
	}
	if t.locked != "" {
		return removal{}, refuse(refused, "%s's worktree is locked (%s). If the lock is no longer wanted: git worktree unlock %s, then run %s.", name, t.locked, t.path, again)
	}
	if branch := repo.mainTreeBranch(); !abandoned && branch != "main" {
		return removal{}, refuse(refused, "the main working tree is on %s, not main, so git cannot safely delete branch %s. Switch it back to main, then run %s.", branch, name, again)
	}
	r := removal{repo: repo, task: t, record: record}
	if r.ahead, err = repo.count("main.." + name); err != nil {
		return removal{}, refuse(failed, "what %s holds against main cannot be read (%s). Nothing was changed.", name, reason(err))
	}
	if _, err := os.Stat(t.path); errors.Is(err, fs.ErrNotExist) {
		r.gone = true
		switch {
		case abandoned && r.ahead == 0:
			return removal{}, refuse(refused, "%s's folder is gone, and its branch holds nothing main lacks, so there is nothing to keep; remove it with: carson remove %s", name, name)
		case !abandoned && r.ahead > 0:
			return removal{}, refuse(refused, "%s's folder is gone, and its branch holds %s not on main. Keep its work on a branch by abandoning the task: carson abandon %s", name, plural(r.ahead, "commit"), name)
		}
		return r, nil
	}
	if home := m.Env("HOME"); !filepath.IsAbs(home) {
		return removal{}, refuse(failed, "HOME does not name a folder, so the worktree's ignored files would have nowhere to be kept. Nothing was changed.")
	}
	if err := operationInProgress(t.admin, name+"'s worktree", again); err != nil {
		return removal{}, err
	}
	inside, err := m.Processes.Inside(t.path)
	if err != nil {
		return removal{}, refuse(failed, "whether any process works inside it cannot be checked (%s). Nothing was changed.", reason(err))
	}
	if len(inside) > 0 {
		return removal{}, refuse(refused, "processes are working inside it — %s. Stop them, then run %s.", strings.Join(inside, ", "), again)
	}
	nested, err := ownRepositories(t.path)
	if err != nil {
		return removal{}, refuse(failed, "what the worktree holds cannot be read (%s). Nothing was changed.", reason(err))
	}
	if len(nested) > 0 {
		what, them := "a git repository", "it"
		if len(nested) > 1 {
			what, them = "git repositories", "them"
		}
		return removal{}, refuse(refused, "%s holds %s of its own at %s, which git cannot remove with the worktree. Move %s out, then run %s. Nothing was changed.", name, what, strings.Join(nested, ", "), them, again)
	}
	if r.uncommitted, err = untrackedAndChanged(t.path); err != nil {
		return removal{}, refuse(failed, "what the worktree holds cannot be read (%s). Nothing was changed.", reason(err))
	}
	switch {
	case abandoned && r.ahead == 0 && len(r.uncommitted) == 0:
		return removal{}, refuse(refused, "%s holds nothing main lacks and nothing uncommitted, so there is nothing to keep; remove it with: carson remove %s", name, name)
	case abandoned:
	case len(r.uncommitted) > 0:
		return removal{}, refuse(refused, "%s holds %s — %s. Commit it and land it, or abandon the task: carson abandon %s", name, plural(len(r.uncommitted), "uncommitted file"), strings.Join(r.uncommitted, ", "), name)
	case r.ahead > 0:
		return removal{}, refuse(refused, "%s holds %s not on main. Land it with carson land %s, or abandon the task: carson abandon %s", name, plural(r.ahead, "commit"), name, name)
	}
	return r, nil
}

// ownRecord is the task's owner record, when the session running carson owns it; otherwise it says whose the task is, and whether
// that owner is live. verb is what only the owner does: "lands it", "removes it".
func (m Machine) ownRecord(t task, verb string) (Record, error) {
	if t.admin == "" {
		return Record{}, refuse(failed, "the owner record of %s cannot be found: git keeps no administrative folder that points back to its worktree.", t.branch)
	}
	record, found, err := readOwner(t.admin)
	if err != nil {
		return Record{}, refuse(failed, "the owner record of %s cannot be read (%v).", t.branch, err)
	}
	if !found {
		return Record{}, refuse(refused, "%s was made outside carson, so whose it is cannot be told; that is the master's to settle.", t.branch)
	}
	if me, _ := m.ownerRecord(t.branch); sameOwner(record, me) {
		return record, nil
	}
	state, why := m.livenessOf(record)
	switch state {
	case live:
		return Record{}, refuse(refused, "%s belongs to %s, which is live. Only its owner %s.", t.branch, ownerName(record), verb)
	case ended:
		return Record{}, refuse(refused, "%s belongs to %s, which has ended. Adopt it first: carson adopt %s", t.branch, ownerName(record), t.branch)
	default:
		return Record{}, refuse(refused, "%s belongs to %s, whose state is unknown (%s). Only its owner %s.", t.branch, ownerName(record), why, verb)
	}
}

// removeLeftoverBranch removes a branch that has no worktree and whose work is all on main: nothing is lost but the name. With abandoned,
// a branch holding work main lacks is kept as abandoned/<name> instead.
func (r *repository) removeLeftoverBranch(name string, abandoned bool) ([]string, error) {
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err != nil {
		return nil, refuse(refused, "no task or branch is named %s.", name)
	}
	if r.worktrees[0].branch == name {
		return nil, refuse(refused, "branch %s is checked out in the main working tree, at %s. Switch it back to main, then run carson remove %s again.", name, r.top, name)
	}
	ahead, err := r.count("main.." + name)
	switch {
	case err != nil:
		return nil, refuse(failed, "what branch %s holds against main cannot be read (%s). Nothing was changed.", name, reason(err))
	case strings.HasPrefix(name, "abandoned/"):
		return nil, refuse(refused, "branch %s holds the work of a task declared abandoned, %s not on main, and carson keeps it. %s", name, plural(ahead, "commit"), takeUp(name))
	case abandoned && ahead > 0:
		kept := r.freeBranch("abandoned/" + name)
		if _, err := git(r.top, "branch", "-m", name, kept); err != nil {
			return nil, refuse(failed, "branch %s could not be renamed %s (%s). Nothing was changed.", name, kept, reason(err))
		}
		return []string{fmt.Sprintf("Kept the leftover branch %s, its task declared abandoned, as branch %s at %s (%s not on main). %s", name, kept, r.short(kept), plural(ahead, "commit"), takeUp(kept))}, nil
	case abandoned:
		return nil, refuse(refused, "branch %s holds nothing main lacks, so there is nothing to keep; remove it with: carson remove %s", name, name)
	case ahead > 0:
		return nil, refuse(refused, "branch %s has no worktree, and holds %s not on main; it is left as it is. Adopt it with carson adopt %s, or keep it as abandoned work with carson abandon %s", name, plural(ahead, "commit"), name, name)
	}
	if branch := r.mainTreeBranch(); branch != "main" {
		return nil, refuse(refused, "the main working tree is on %s, not main, so git cannot safely delete branch %s. Switch it back to main, then run carson remove %s again.", branch, name, name)
	}
	if _, err := git(r.top, "branch", "-d", name); err != nil {
		return nil, refuse(failed, "the leftover branch %s could not be deleted (%s).", name, reason(err))
	}
	return []string{fmt.Sprintf("Removed the leftover branch %s: it had no worktree, and its work is on main.", name)}, nil
}

// remove removes the worktree, keeping its ignored files, and deletes the branch by git's safe delete, which measures it against the
// main working tree's branch: main, as checkRemoval has seen.
func (r removal) remove(m Machine) ([]string, error) {
	name := r.task.branch
	said, err := r.clear(m, "Branch "+name+" is left as it is.")
	if err != nil {
		return said, err
	}
	if _, err := git(r.repo.top, "branch", "-d", name); err != nil {
		return said, refuse(failed, "its worktree at %s is removed, but branch %s could not be deleted (%s); it holds nothing main lacks.", r.task.path, name, reason(err))
	}
	worktree := "its worktree at " + r.task.path
	if r.gone {
		worktree += ", whose folder was already gone"
	}
	branch := "its branch, which held nothing main lacks"
	if r.record.Landed != "" {
		branch = "its branch, landed on main at " + r.repo.short(r.record.Landed)
	}
	result := fmt.Sprintf("Removed %s: %s, and %s. It was owned by %s.", name, worktree, branch, ownerName(r.record))
	return append([]string{result}, said...), nil
}

// abandon keeps everything the task holds on a branch named abandoned/<task> — its commits, and what was uncommitted, committed — and
// removes its worktree, keeping its ignored files. The commit goes through the repository's own checks; when one refuses, what was
// staged for it is unstaged, so the worktree is as it was. The branch is renamed last: whatever fails before, the task is still under
// its own name, and carson abandon <task> takes it on from there. Nothing is destroyed.
func (r removal) abandon(m Machine) ([]string, error) {
	name := r.task.branch
	if len(r.uncommitted) > 0 {
		_, err := git(r.task.path, "add", "-A")
		if err == nil {
			_, err = git(r.task.path, "commit", "-q", "-m", "Keep what was uncommitted when "+name+" was declared abandoned")
		}
		if err != nil {
			if _, unstaged := git(r.task.path, "reset", "-q"); unstaged != nil {
				return nil, refuse(failed, "what was uncommitted could not be committed (%s), and what was staged for it could not be unstaged (%s). Its branch is still %s.", reason(err), reason(unstaged), name)
			}
			return nil, refuse(failed, "what was uncommitted could not be committed (%s). Its files are left as they are, none of them staged, on branch %s; run carson abandon %s again once that is cleared.", reason(err), name, name)
		}
	}
	again := "Its work is on branch " + name
	if len(r.uncommitted) > 0 {
		again += ", what was uncommitted now committed"
	}
	again += "; run carson abandon " + name + " again once that is cleared."
	said, err := r.clear(m, again)
	if err != nil {
		return said, err
	}
	kept := r.repo.freeBranch("abandoned/" + name)
	if _, err := git(r.repo.top, "branch", "-m", name, kept); err != nil {
		return said, refuse(failed, "its worktree is removed, but branch %s could not be renamed %s (%s). %s", name, kept, reason(err), again)
	}
	what := plural(r.ahead, "commit")
	switch {
	case len(r.uncommitted) > 0 && r.ahead == 0:
		what = "1 commit, holding what was uncommitted"
	case len(r.uncommitted) > 0:
		what = plural(r.ahead+1, "commit") + ", the last holding what was uncommitted"
	}
	worktree := "its worktree is removed"
	if r.gone {
		worktree = "git's record of its worktree, whose folder was already gone, is removed"
	}
	result := fmt.Sprintf("Abandoned %s: its work — %s — is kept as branch %s at %s, and %s. %s", name, what, kept, r.repo.short(kept), worktree, takeUp(kept))
	return append([]string{result}, said...), nil
}

// takeUp says how the task whose abandoned work is kept on branch kept is taken up again.
func takeUp(kept string) string {
	return "Take it up again with: carson adopt " + strings.TrimPrefix(kept, "abandoned/")
}

// offBranch refuses a task whose worktree has left its branch for what on says, with the way back; command is what to run after.
func offBranch(t task, on, command string) error {
	return refuse(refused, "%s's worktree at %s is on %s, not its branch. Switch it back there with git switch %s, then run %s again.", t.branch, t.path, on, t.branch, command)
}

// freeBranch is name, or when a branch already has that name, the first of name-2, name-3 … that none has.
func (r *repository) freeBranch(name string) string {
	free := name
	for n := 2; ; n++ {
		if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+free); err != nil {
			return free
		}
		free = name + "-" + strconv.Itoa(n)
	}
}

// clear keeps the worktree's ignored files and removes the worktree, or only git's record of it when its folder is already gone.
// branch says, on a failure, where the task's branch stands.
func (r removal) clear(m Machine, branch string) ([]string, error) {
	var said []string
	if !r.gone {
		note, err := r.repo.keepIgnored(m, r.task)
		if err != nil {
			return nil, refuse(failed, "%s %s", err, branch)
		}
		if note != "" {
			said = append(said, note)
		}
	}
	_, err := git(r.repo.top, "worktree", "remove", r.task.path)
	if err == nil {
		return said, nil
	}
	// git drops its record of a worktree even when it could delete only part of the folder.
	if _, recorded := os.Stat(r.task.admin); recorded == nil {
		but := ""
		if len(said) > 0 {
			but = ", but for its ignored files, kept as said above"
		}
		return said, refuse(failed, "its worktree could not be removed (%s); it is left as it is%s. %s", reason(err), but, branch)
	}
	return said, refuse(failed, "git could not delete all of its worktree's folder (%s), yet has dropped its record of the worktree. What is left of the folder, all of it committed, is at %s. %s", reason(err), r.task.path, branch)
}

// freeFolder makes the folder named, or when one is there already, the first of name-2, name-3 … that is not, and returns it: a
// folder made for one removal is never shared with another.
func freeFolder(name string) (string, error) {
	if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
		return "", err
	}
	free := name
	for n := 2; ; n++ {
		err := os.Mkdir(free, 0o755)
		if err == nil {
			return free, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return "", err
		}
		free = name + "-" + strconv.Itoa(n)
	}
}

// ownRepositories names the git repositories inside the worktree — one cloned or made there, or a submodule checked out — which git
// will not remove with the worktree.
func ownRepositories(dir string) ([]string, error) {
	// Listing every untracked file, git stops only at a repository of its own, which it names as a folder.
	held, err := git(dir, "--no-optional-locks", "status", "--porcelain", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	var found []string
	for _, entry := range strings.Split(held, "\x00") {
		if strings.HasPrefix(entry, "?? ") && strings.HasSuffix(entry, "/") {
			found = append(found, strings.TrimSuffix(entry[3:], "/"))
		}
	}
	staged, err := git(dir, "ls-files", "--stage", "-z")
	if err != nil {
		return nil, err
	}
	for _, entry := range strings.Split(staged, "\x00") {
		if _, path, isLink := strings.Cut(entry, "\t"); isLink && strings.HasPrefix(entry, "160000 ") {
			if _, err := os.Stat(filepath.Join(dir, path, ".git")); err == nil {
				found = append(found, path)
			}
		}
	}
	return found, nil
}

// untrackedAndChanged names what the worktree holds that its commit does not, ignored files apart.
func untrackedAndChanged(dir string) ([]string, error) {
	found, err := changes(dir)
	if err != nil {
		return nil, err
	}
	names := make([]string, len(found))
	for i, line := range found {
		names[i] = strings.TrimSpace(line[2:])
	}
	return names, nil
}

// keepIgnored moves the worktree's ignored files — a local .env, build output — to ~/.cache/deleted before the worktree goes, since
// git removes them without a word. It says where they are, or refuses, touching nothing more, if they cannot be kept.
func (r *repository) keepIgnored(m Machine, t task) (string, error) {
	held, err := git(t.path, "--no-optional-locks", "status", "--porcelain", "-z", "--ignored=matching", "--untracked-files=all")
	if err != nil {
		return "", refuse(failed, "the worktree's ignored files cannot be listed (%s). Nothing was changed.", reason(err))
	}
	var ignored []string
	for _, entry := range strings.Split(held, "\x00") {
		if strings.HasPrefix(entry, "!! ") {
			ignored = append(ignored, strings.TrimSuffix(entry[3:], "/"))
		}
	}
	if len(ignored) == 0 {
		return "", nil
	}
	home := filepath.Clean(m.Env("HOME"))
	place := strings.TrimPrefix(r.top, "/")
	if strings.HasPrefix(r.top, home+"/") {
		place = strings.TrimPrefix(r.top, home+"/")
	}
	kept, err := freeFolder(filepath.Join(home, ".cache", "deleted", place, t.branch+"-"+time.Now().Format("20060102-150405")))
	if err != nil {
		return "", refuse(failed, "no folder could be made to keep the worktree's ignored files in (%v). Nothing was changed.", err)
	}
	for i, path := range ignored {
		target := filepath.Join(kept, path)
		err := os.MkdirAll(filepath.Dir(target), 0o755)
		if err == nil {
			err = os.Rename(filepath.Join(t.path, path), target)
		}
		if err != nil {
			return "", refuse(failed, "ignored file %s could not be kept (%v); %d of %d %s in %s, and the worktree is left as it is.", path, err, i, len(ignored), isOrAre(i), kept)
		}
	}
	return fmt.Sprintf("Its %s (%s) %s kept in %s.", plural(len(ignored), "ignored file"), strings.Join(ignored, ", "), isOrAre(len(ignored)), kept), nil
}
