package carson

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// merge merges the task whose worktree carson runs in into main: rebased onto the latest main, checked, fast-forwarded in the main
// working tree, and pushed, reporting what it observed after each step. Everything that can refuse without a change refuses first.
func merge(m Machine, args []string) int {
	say := func(text string) { fmt.Fprintln(m.Out, text) }
	if len(args) > 0 {
		say("Not merged: carson merge takes no arguments; run it inside the task's worktree.")
		return refused
	}
	repo, t, record, err := m.taskHere()
	if err != nil {
		say("Not merged: " + err.Error())
		return codeOf(err)
	}
	notes, err := repo.mergeTask(m, t, record)
	for _, note := range notes {
		say(note)
	}
	if err != nil {
		// A result that is not a refusal to merge — the merge already made and pushed now, or made but not pushed — carries its
		// words in the notes, and only its exit code here.
		var result *refusal
		if errors.As(err, &result) && result.text == "" {
			return result.code
		}
		say("Not merged: " + err.Error())
		return codeOf(err)
	}
	return done
}

// taskHere is the task whose worktree carson runs in, and its owner record, when the session running carson owns it.
func (m Machine) taskHere() (*repository, task, Record, error) {
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		return nil, task{}, Record{}, refuse(failed, "%s is not inside a git repository.", m.Dir)
	}
	if err != nil {
		return nil, task{}, Record{}, refuse(failed, "the repository could not be read (%s).", reason(err))
	}
	here, err := git(m.Dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return nil, task{}, Record{}, refuse(failed, "the worktree carson runs in cannot be told (%s).", reason(err))
	}
	if here == repo.top {
		return nil, task{}, Record{}, refuse(refused, "carson merge runs inside a task's worktree; %s is the main working tree.", here)
	}
	var t task
	for _, candidate := range repo.tasks() {
		if candidate.path == here {
			t = candidate
		}
	}
	if t.path != "" && t.branch == "" {
		t.branch = branchUnderRebase(t.path)
	}
	switch {
	case t.path == "":
		return nil, task{}, Record{}, refuse(failed, "%s is not among git's worktrees for this repository.", here)
	case t.branch == "":
		return nil, task{}, Record{}, refuse(refused, "this worktree is on a detached HEAD, not a task's branch.")
	}
	record, found, err := readOwner(t.admin)
	switch {
	case t.admin == "" || err != nil:
		return nil, task{}, Record{}, refuse(failed, "the owner record of %s cannot be read (%v).", t.branch, err)
	case !found:
		return nil, task{}, Record{}, refuse(refused, "%s was made outside carson, so whose it is cannot be told; that is the master's to settle.", t.branch)
	}
	if me, _ := m.ownerRecord(t.branch); !sameOwner(record, me) {
		state, why := m.livenessOf(record)
		switch state {
		case live:
			return nil, task{}, Record{}, refuse(refused, "%s belongs to %s, which is live. Only its owner merges it.", t.branch, ownerName(record))
		case ended:
			return nil, task{}, Record{}, refuse(refused, "%s belongs to %s, which has ended. Taking it over (carson start %s --existing) is not built yet.", t.branch, ownerName(record), t.branch)
		default:
			return nil, task{}, Record{}, refuse(refused, "%s belongs to %s, whose state is unknown (%s). Only its owner merges it.", t.branch, ownerName(record), why)
		}
	}
	return repo, t, record, nil
}

// branchUnderRebase is the branch a rebase in the worktree is rewriting — during a rebase git leaves HEAD detached — or "".
func branchUnderRebase(dir string) string {
	gitdir, err := git(dir, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return ""
	}
	for _, folder := range []string{"rebase-merge", "rebase-apply"} {
		if name, err := os.ReadFile(filepath.Join(gitdir, folder, "head-name")); err == nil {
			return strings.TrimPrefix(strings.TrimSpace(string(name)), "refs/heads/")
		}
	}
	return ""
}

// sameOwner is whether two records name one owner: one harness session on one machine, or one terminal's shell.
func sameOwner(a, b Record) bool {
	if a.Harness != b.Harness {
		return false
	}
	if a.MachineID != "" && b.MachineID != "" {
		if a.MachineID != b.MachineID {
			return false
		}
	} else if a.Machine != b.Machine {
		return false
	}
	if a.Harness == "terminal" {
		return a.PID == b.PID && a.Started == b.Started
	}
	return a.Session == b.Session
}

// mergeTask carries out the merge, step by step. A refusal with code done is a merge already made, whose push is now done.
func (r *repository) mergeTask(m Machine, t task, record Record) ([]string, error) {
	commits, err := r.count("main.." + t.branch)
	if err != nil {
		return nil, refuse(failed, "what %s holds against main cannot be read (%s). Nothing was changed.", t.branch, reason(err))
	}
	holds := fmt.Sprintf("%s still holds its %s", t.branch, plural(commits, "commit"))
	if err := t.readyToMerge(); err != nil {
		return nil, err
	}
	if branch := r.mainTreeBranch(); branch != "main" {
		return nil, refuse(refused, "the main working tree is on %s, not main, so main cannot be fast-forwarded there. Nothing was changed; %s.", branch, holds)
	}
	if r.remote != "" {
		if _, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main"); err != nil {
			return nil, refuse(failed, "GitHub could not be reached (%s). Nothing was changed; %s.", reason(err), holds)
		}
	}
	release, note, err := r.lockMerge(m, t.branch)
	if err != nil {
		return nil, err
	}
	defer release()
	var notes []string
	if note != "" {
		notes = append(notes, note)
	}
	diverged, current, err := r.mainForMerge(t, holds)
	notes = append(notes, current...)
	if err != nil {
		return notes, err
	}
	if commits, err = r.count("main.." + t.branch); err != nil {
		return notes, refuse(failed, "what %s holds against main cannot be read (%s).", t.branch, reason(err))
	}
	if commits == 0 {
		where := "on main"
		if r.remote != "" {
			if _, err := git(r.top, "merge-base", "--is-ancestor", t.branch, "refs/remotes/"+r.remote+"/main"); err == nil {
				where = "on main and on GitHub"
			}
		}
		return notes, refuse(refused, "%s has no commits that main lacks. Its work is %s at %s; remove it with: carson remove %s", t.branch, where, r.short("main"), t.branch)
	}
	rebased, err := r.rebaseOntoMain(t)
	if err != nil {
		return notes, err
	}
	if diverged {
		if err := r.joinGitHub(t); err != nil {
			return notes, err
		}
		notes = append(notes, fmt.Sprintf("GitHub's main had diverged; its commits are merged into %s first.", t.branch))
	}
	checks, err := runChecks(t.path)
	if err != nil {
		return notes, err
	}
	tip, _ := git(t.path, "rev-parse", "HEAD")
	if after, err := changes(t.path); err != nil || len(after) > 0 {
		return notes, refuse(refused, "bin/check left the worktree changed (%s); the merge stops. %s, rebased onto main.", strings.Join(after, ", "), holds)
	}
	if err := r.fastForward(t, tip, holds); err != nil {
		return notes, err
	}
	record.Merged = tip
	if err := writeOwner(t.admin, record); err != nil {
		notes = append(notes, "The owner record could not note the merge ("+err.Error()+").")
	}
	shortTip := r.short(tip)
	how := plural(commits, "commit")
	if rebased {
		how += ", rebased onto main first"
	}
	if r.remote == "" {
		return append(notes, fmt.Sprintf("Merged %s into main by fast-forward at %s (%s). No GitHub remote: main is on this machine only.", t.branch, shortTip, how)), nil
	}
	now, err := r.pushMain()
	var unchecked pushedUnchecked
	switch {
	case errors.As(err, &unchecked):
		notes = append(notes, fmt.Sprintf("Merged %s into local main at %s and pushed, but %s. Run carson merge again to check it.", t.branch, shortTip, unchecked.why))
		return notes, &refusal{code: failed}
	case err != nil:
		notes = append(notes, fmt.Sprintf("Merged %s into local main at %s. Not on GitHub (%s). Run carson merge again to push.", t.branch, shortTip, reason(err)))
		return notes, &refusal{code: failed, text: ""}
	}
	return append(notes, fmt.Sprintf("Merged %s into main by fast-forward at %s (%s) and pushed; GitHub's main is %s. %s Remove the worktree with: carson remove %s (from outside it).", t.branch, shortTip, how, now, checks, t.branch)), nil
}

// readyToMerge refuses a worktree in the middle of a git operation, or holding uncommitted files: carson never commits for anyone.
func (t task) readyToMerge() error {
	gitdir, err := git(t.path, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return refuse(failed, "the worktree's git folder cannot be found (%s).", reason(err))
	}
	for _, operation := range []struct{ marker, name, command string }{
		{"rebase-merge", "rebase", "git rebase"}, {"rebase-apply", "rebase", "git rebase"}, {"MERGE_HEAD", "merge", "git merge"},
		{"CHERRY_PICK_HEAD", "cherry-pick", "git cherry-pick"}, {"REVERT_HEAD", "revert", "git revert"},
	} {
		if _, err := os.Stat(filepath.Join(gitdir, operation.marker)); err == nil {
			return refuse(refused, "a %s is in progress in this worktree. Finish it with %s --continue, or give it up with %s --abort, then run carson merge.", operation.name, operation.command, operation.command)
		}
	}
	found, err := changes(t.path)
	if err != nil {
		return refuse(failed, "what the worktree holds cannot be read (%s).", reason(err))
	}
	if len(found) > 0 {
		names := make([]string, len(found))
		for i, line := range found {
			names[i] = strings.TrimSpace(line[2:])
		}
		verb := "are"
		if len(found) == 1 {
			verb = "is"
		}
		return refuse(refused, "%s %s uncommitted — %s. Commit them in this worktree, then run carson merge.", plural(len(found), "file"), verb, strings.Join(names, ", "))
	}
	return nil
}

func (r *repository) mainTreeBranch() string {
	branch, err := git(r.top, "symbolic-ref", "--short", "-q", "HEAD")
	if err != nil || branch == "" {
		return "a detached HEAD"
	}
	return branch
}

// mainForMerge brings local main current for the merge: merged work GitHub lacks is pushed first (and if the task was all it lacked,
// the merge is done); GitHub's commits come in by fast-forward; a divergence is returned, for the task to join.
func (r *repository) mainForMerge(t task, holds string) (diverged bool, notes []string, err error) {
	if r.remote == "" {
		return false, nil, nil
	}
	tracking := "refs/remotes/" + r.remote + "/main"
	if _, err := gitNetwork(r.top, "fetch", "-q", r.remote, "+refs/heads/main:"+tracking); err != nil {
		return false, nil, refuse(failed, "GitHub's main could not be fetched (%s). Nothing was changed; %s.", reason(err), holds)
	}
	ahead, err := r.count(tracking + "..main")
	if err != nil {
		return false, nil, refuse(failed, "how local main stands against GitHub's is unknown (%s). %s.", reason(err), holds)
	}
	behind, err := r.count("main.." + tracking)
	if err != nil {
		return false, nil, refuse(failed, "how local main stands against GitHub's is unknown (%s). %s.", reason(err), holds)
	}
	switch {
	case ahead > 0 && behind > 0:
		return true, nil, nil
	case ahead > 0:
		now, err := r.pushMain()
		var unchecked pushedUnchecked
		if errors.As(err, &unchecked) {
			return false, nil, refuse(failed, "local main held %s GitHub lacked; it was pushed, but %s. %s.", plural(ahead, "commit"), unchecked.why, holds)
		}
		if err != nil {
			return false, nil, refuse(failed, "local main holds %s GitHub lacks, and pushing them failed (%s). %s.", plural(ahead, "commit"), reason(err), holds)
		}
		if merged, _ := r.count("main.." + t.branch); merged == 0 {
			return false, []string{fmt.Sprintf("%s was already merged into local main at %s; pushed it now. GitHub's main is %s.", t.branch, r.short("main"), now)}, &refusal{code: done}
		}
		return false, []string{fmt.Sprintf("Pushed %s of local main that GitHub lacked; GitHub's main is now %s.", plural(ahead, "commit"), now)}, nil
	case behind > 0:
		inTheWay, err := r.inTheWay(tracking)
		if err != nil {
			return false, nil, refuse(failed, "what the main working tree holds could not be read (%s). %s.", reason(err), holds)
		}
		if len(inTheWay) > 0 {
			return false, nil, refuse(refused, "bringing local main forward would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s.", strings.Join(inTheWay, ", "), holds)
		}
		if _, err := git(r.top, "merge", "--ff-only", "-q", tracking); err != nil {
			return false, nil, refuse(refused, "local main could not be brought forward to GitHub's (%s). %s.", reason(err), holds)
		}
		return false, []string{fmt.Sprintf("Local main was %s behind GitHub's and is brought forward to it.", plural(behind, "commit"))}, nil
	}
	return false, nil, nil
}

// rebaseOntoMain rebases the task onto local main when main holds commits the task lacks. On a conflict it undoes the rebase, looks
// that the task is as it was, and names the files and the command to run.
func (r *repository) rebaseOntoMain(t task) (bool, error) {
	behind, err := r.count(t.branch + "..main")
	if err != nil {
		return false, refuse(failed, "how %s stands against main cannot be read (%s).", t.branch, reason(err))
	}
	if behind == 0 {
		return false, nil
	}
	before, _ := git(t.path, "rev-parse", "HEAD")
	if _, err := git(t.path, "rebase", "-q", "main"); err != nil {
		return false, r.undo(t, before, "rebase", "rebasing onto main ("+r.short("main")+")", "git rebase main", err)
	}
	return true, nil
}

// joinGitHub merges GitHub's main into the task, when the two mains have diverged, so the task carries both.
func (r *repository) joinGitHub(t task) error {
	tracking := r.remote + "/main"
	before, _ := git(t.path, "rev-parse", "HEAD")
	if _, err := git(t.path, "merge", "-q", "--no-edit", "refs/remotes/"+tracking); err != nil {
		return r.undo(t, before, "merge", "merging GitHub's main ("+r.short("refs/remotes/"+tracking)+")", "git merge "+tracking, err)
	}
	return nil
}

// undo gives up a rebase or merge that stopped, and says what it found: the files in conflict, and whether the task is as it was.
func (r *repository) undo(t task, before, operation, doing, command string, cause error) error {
	conflicts, _ := git(t.path, "diff", "--name-only", "--diff-filter=U")
	git(t.path, operation, "--abort")
	now, _ := git(t.path, "rev-parse", "HEAD")
	left, _ := changes(t.path)
	if now != before || len(left) > 0 {
		return refuse(failed, "%s failed (%s), and undoing it left %s at %s with %s — not as it was, at %s. Look before going on.", doing, reason(cause), t.branch, r.short(now), plural(len(left), "change"), r.short(before))
	}
	files := strings.Join(lines(conflicts), ", ")
	if files == "" {
		return refuse(failed, "%s failed (%s). It was undone; %s is as it was, at %s.", doing, reason(cause), t.branch, r.short(before))
	}
	return refuse(refused, "%s conflicts in %s. The %s was undone; %s is as it was, at %s. Run %s in this worktree, resolve, then carson merge.", doing, files, operation, t.branch, r.short(before), command)
}

// runChecks runs the repository's declared checks, bin/check, in the task's worktree, and says how they went.
func runChecks(dir string) (string, error) {
	path := filepath.Join(dir, "bin", "check")
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return "No checks declared (no bin/check).", nil
	}
	command := exec.Command(path)
	command.Dir = dir
	output, err := command.CombinedOutput()
	if err == nil {
		return "Checks: bin/check passed.", nil
	}
	exit := err.Error()
	var failure *exec.ExitError
	if errors.As(err, &failure) {
		exit = fmt.Sprintf("exit %d", failure.ExitCode())
	}
	tail := lines(strings.TrimRight(string(output), "\n"))
	if len(tail) > 20 {
		tail = tail[len(tail)-20:]
	}
	return "", refuse(refused, "bin/check failed (%s). Its output ends:\n%s", exit, strings.Join(tail, "\n"))
}

// fastForward moves main to the task's tip in the main working tree, never over what that tree holds, and looks that it moved.
func (r *repository) fastForward(t task, tip, holds string) error {
	if branch := r.mainTreeBranch(); branch != "main" {
		return refuse(refused, "the main working tree is on %s, not main, so main cannot be fast-forwarded there. %s, rebased onto main.", branch, holds)
	}
	inTheWay, err := r.inTheWay(tip)
	if err != nil {
		return refuse(failed, "what the main working tree holds could not be read (%s). %s, rebased onto main.", reason(err), holds)
	}
	if len(inTheWay) > 0 {
		return refuse(refused, "fast-forwarding main would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s, now rebased onto main.", strings.Join(inTheWay, ", "), holds)
	}
	if _, err := git(r.top, "merge", "--ff-only", "-q", tip); err != nil {
		return refuse(failed, "main could not be fast-forwarded (%s). %s, rebased onto main.", reason(err), holds)
	}
	if now, _ := git(r.top, "rev-parse", "main"); now != tip {
		return refuse(failed, "main was fast-forwarded, but it is at %s, not the task's %s. Look before going on.", r.short(now), r.short(tip))
	}
	return nil
}
