package carson

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// remove removes a finished task's worktree and branch, by its owner, from outside the worktree. It refuses while the task holds
// uncommitted files or commits main lacks, or while any process works inside it. Ignored files are kept, never deleted; the branch
// goes by git's safe delete. With --abandoned, what the task holds is committed and kept on a branch named abandoned/<task>.
func remove(m Machine, args []string) int {
	say := func(text string) { fmt.Fprintln(m.Out, text) }
	name, abandoned, err := removeArguments(args)
	if err != nil {
		say("Not removed: " + err.Error())
		return codeOf(err)
	}
	said, err := m.removeTask(name, abandoned)
	for _, line := range said {
		say(line)
	}
	if err != nil {
		say("Not removed: " + err.Error())
		return codeOf(err)
	}
	return done
}

func removeArguments(args []string) (name string, abandoned bool, err error) {
	for _, arg := range args {
		switch {
		case arg == "--abandoned":
			abandoned = true
		case strings.HasPrefix(arg, "-"):
			return "", false, refuse(refused, "carson remove has no option %q.", arg)
		case name != "":
			return "", false, refuse(refused, "one task at a time; %q and %q were given.", name, arg)
		default:
			name = arg
		}
	}
	if name == "" {
		return "", false, refuse(refused, "name the task, as in carson remove fix-login.")
	}
	return name, abandoned, nil
}

func (m Machine) removeTask(name string, abandoned bool) ([]string, error) {
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		return nil, refuse(failed, "%s is not inside a git repository.", m.Dir)
	}
	if err != nil {
		return nil, refuse(failed, "the repository could not be read (%s).", reason(err))
	}
	var t task
	for _, candidate := range repo.tasks() {
		if candidate.branch == name || candidate.branch == "" && branchUnderRebase(candidate.path) == name {
			t = candidate
			t.branch = name
		}
	}
	if t.path == "" {
		return repo.removeLeftoverBranch(name)
	}
	if here, err := filepath.EvalSymlinks(m.Dir); err == nil && (here == t.path || strings.HasPrefix(here, t.path+"/")) {
		return nil, refuse(refused, "carson remove runs from outside the worktree it removes; run it from %s.", repo.top)
	}
	record, err := m.ownRecord(t, "removes it")
	if err != nil {
		return nil, err
	}
	inside, err := m.Processes.Inside(t.path)
	if err != nil {
		return nil, refuse(failed, "whether any process works inside it cannot be checked (%s). Nothing was changed.", reason(err))
	}
	if len(inside) > 0 {
		return nil, refuse(refused, "processes are working inside it — %s. Stop them, then run carson remove again.", strings.Join(inside, ", "))
	}
	if abandoned {
		return repo.abandon(m, t)
	}
	if uncommitted, err := untrackedAndChanged(t.path); err != nil {
		return nil, refuse(failed, "what the worktree holds cannot be read (%s). Nothing was changed.", reason(err))
	} else if len(uncommitted) > 0 {
		return nil, refuse(refused, "%s holds %s — %s. Commit and merge it, or declare the task abandoned: carson remove %s --abandoned", name, uncommittedFiles(len(uncommitted)), strings.Join(uncommitted, ", "), name)
	}
	ahead, err := repo.count("main.." + name)
	if err != nil {
		return nil, refuse(failed, "what %s holds against main cannot be read (%s). Nothing was changed.", name, reason(err))
	}
	if ahead > 0 {
		return nil, refuse(refused, "%s holds %s not on main. Merge it with carson merge, or declare the task abandoned: carson remove %s --abandoned", name, plural(ahead, "commit"), name)
	}
	var said []string
	if note, err := repo.keepIgnored(m, t); err != nil {
		return nil, err
	} else if note != "" {
		said = append(said, note)
	}
	if _, err := git(repo.top, "worktree", "remove", t.path); err != nil {
		return said, refuse(failed, "its worktree could not be removed (%s). Its branch is left as it is.", reason(err))
	}
	if _, err := git(repo.top, "branch", "-d", name); err != nil {
		return said, refuse(failed, "its worktree at %s is removed, but branch %s could not be deleted (%s); it holds nothing main lacks.", t.path, name, reason(err))
	}
	result := fmt.Sprintf("Removed %s: its worktree at %s, and its branch, whose work is on main at %s. It was owned by %s.", name, t.path, repo.short("main"), ownerName(record))
	return append([]string{result}, said...), nil
}

// ownRecord is the task's owner record, when the session running carson owns it; otherwise it says whose the task is, and whether
// that owner is live. verb is what only the owner does: "merges it", "removes it".
func (m Machine) ownRecord(t task, verb string) (Record, error) {
	record, found, err := readOwner(t.admin)
	switch {
	case t.admin == "" || err != nil:
		return Record{}, refuse(failed, "the owner record of %s cannot be read (%v).", t.branch, err)
	case !found:
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
		return Record{}, refuse(refused, "%s belongs to %s, which has ended. Taking it over (carson start %s --existing) is not built yet.", t.branch, ownerName(record), t.branch)
	default:
		return Record{}, refuse(refused, "%s belongs to %s, whose state is unknown (%s). Only its owner %s.", t.branch, ownerName(record), why, verb)
	}
}

// removeLeftoverBranch removes a branch that has no worktree and whose work is all on main: nothing is lost but the name.
func (r *repository) removeLeftoverBranch(name string) ([]string, error) {
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err != nil {
		return nil, refuse(refused, "no task or branch is named %s.", name)
	}
	ahead, err := r.count("main.." + name)
	switch {
	case err != nil:
		return nil, refuse(failed, "what branch %s holds against main cannot be read (%s). Nothing was changed.", name, reason(err))
	case ahead > 0:
		return nil, refuse(refused, "branch %s has no worktree, and holds %s not on main; it is left as it is. Taking it up again (carson start %s --existing) is not built yet.", name, plural(ahead, "commit"), name)
	}
	if _, err := git(r.top, "branch", "-d", name); err != nil {
		return nil, refuse(failed, "the leftover branch %s could not be deleted (%s).", name, reason(err))
	}
	return []string{fmt.Sprintf("Removed the leftover branch %s: it had no worktree, and its work is on main.", name)}, nil
}

// abandon keeps everything the task holds on a branch named abandoned/<task> — its commits, and what was uncommitted, committed —
// keeps its ignored files, and removes its worktree. Nothing is destroyed.
func (r *repository) abandon(m Machine, t task) ([]string, error) {
	kept := "abandoned/" + t.branch
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+kept); err == nil {
		return nil, refuse(refused, "branch %s already exists; the task cannot be kept under that name. Nothing was changed.", kept)
	}
	uncommitted, err := untrackedAndChanged(t.path)
	if err != nil {
		return nil, refuse(failed, "what the worktree holds cannot be read (%s). Nothing was changed.", reason(err))
	}
	if len(uncommitted) > 0 {
		if _, err := git(t.path, "add", "-A"); err == nil {
			_, err = git(t.path, "commit", "-q", "-m", "Keep what was uncommitted when "+t.branch+" was declared abandoned")
		}
		if err != nil {
			return nil, refuse(failed, "what was uncommitted could not be committed (%s). The worktree is left as it is.", reason(err))
		}
	}
	var said []string
	if note, err := r.keepIgnored(m, t); err != nil {
		return nil, err
	} else if note != "" {
		said = append(said, note)
	}
	if _, err := git(r.top, "branch", "-m", t.branch, kept); err != nil {
		return said, refuse(failed, "branch %s could not be renamed %s (%s). The worktree is left as it is.", t.branch, kept, reason(err))
	}
	if _, err := git(r.top, "worktree", "remove", t.path); err != nil {
		return said, refuse(failed, "the task is kept as branch %s, but its worktree could not be removed (%s).", kept, reason(err))
	}
	commits, _ := r.count("main.." + kept)
	what := plural(commits, "commit")
	if len(uncommitted) > 0 {
		what += ", the last holding what was uncommitted"
	}
	result := fmt.Sprintf("Removed %s's worktree, its task declared abandoned. Its work — %s — is kept as branch %s at %s. To take it up again: git worktree add <folder> %s", t.branch, what, kept, r.short(kept), kept)
	return append([]string{result}, said...), nil
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

func uncommittedFiles(n int) string {
	return plural(n, "uncommitted file")
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
	kept := filepath.Join(home, ".cache", "deleted", place, t.branch+"-"+time.Now().Format("20060102-150405"))
	for i, path := range ignored {
		target := filepath.Join(kept, path)
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err == nil {
			err = os.Rename(filepath.Join(t.path, path), target)
		}
		if err != nil {
			return "", refuse(failed, "ignored file %s could not be kept (%v); %d of %d are in %s, and the worktree is left as it is.", path, err, i, len(ignored), kept)
		}
	}
	return fmt.Sprintf("Its %s (%s) %s kept in %s.", plural(len(ignored), "ignored file"), strings.Join(ignored, ", "), map[bool]string{true: "is", false: "are"}[len(ignored) == 1], kept), nil
}
