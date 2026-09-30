package carson

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

// merge merges the task whose worktree carson runs in into main: brought up to the latest main, checked, fast-forwarded in the main
// working tree, and pushed, reporting what it observed after each step. Everything that can refuse without a change refuses first.
// Ctrl-C is caught for the whole run: the step under way ends, and the run stops there with one line, the merge lock given back.
func merge(m Machine, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(m.Out, "Not merged: carson merge takes no arguments; run it inside the task's worktree.")
		return refused
	}
	interrupted, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// The first Ctrl-C lets the step under way end; after it, a second Ctrl-C ends carson at once, as it would without the catch —
	// leaving the merge lock, which the next run takes over and says so.
	go func() {
		<-interrupted.Done()
		stop()
	}()
	repo, t, record, err := m.taskHere()
	if err != nil {
		fmt.Fprintln(m.Out, "Not merged: "+err.Error())
		return codeOf(err)
	}
	said, code := repo.mergeTask(m, t, record, interrupted)
	for _, line := range said {
		fmt.Fprintln(m.Out, line)
	}
	return code
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
		return nil, task{}, Record{}, refuse(refused, "carson merge runs inside a task's worktree; %s is the main working tree. Run it in the task's worktree; carson status lists them.", here)
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
	record, err := m.ownRecord(t, "merges it")
	if err != nil {
		return nil, task{}, Record{}, err
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

// merging is one merge under way: what carson has done to the task so far, so every refusal says the state the task is left in.
type merging struct {
	repo     *repository
	task     task
	original string // the task's commit before carson touched it
	commits  int    // the commits the task holds that main lacks
	update   string // how it was brought up to main: "rebased onto main", "with main merged in", or ""
	joined   bool   // GitHub's main merged in
	said     []string
}

// state says what the task holds now: "fix-login still holds its 2 commits, now rebased onto main (it was at 1a2b3c4 before carson)".
func (g *merging) state() string {
	s := fmt.Sprintf("%s still holds its %s", g.task.branch, plural(g.commits, "commit"))
	if g.commits == 0 {
		s = g.task.branch + " holds nothing of its own that main lacks"
	}
	if g.update != "" {
		s += ", now " + g.update
	}
	if g.joined {
		s += ", with GitHub's main merged in"
	}
	if g.update != "" || g.joined {
		s += fmt.Sprintf(" (it was at %s before carson)", g.repo.short(g.original))
	}
	return s
}

func (g *merging) note(format string, args ...any) {
	g.said = append(g.said, fmt.Sprintf(format, args...))
}

// stop ends the merge with a refusal; its text says the state the task is left in.
func (g *merging) stop(code int, format string, args ...any) ([]string, int) {
	return append(g.said, "Not merged: "+fmt.Sprintf(format, args...)), code
}

// mergeTask carries out the merge, step by step, and returns what it says and the exit code.
func (r *repository) mergeTask(m Machine, t task, record Record, interrupted context.Context) ([]string, int) {
	g := &merging{repo: r, task: t}
	var err error
	if g.original, err = git(t.path, "rev-parse", "HEAD"); err != nil {
		return g.stop(failed, "the task's commit cannot be read (%s). Nothing was changed.", reason(err))
	}
	if g.commits, err = r.count("main.." + t.branch); err != nil {
		return g.stop(failed, "what %s holds against main cannot be read (%s). Nothing was changed.", t.branch, reason(err))
	}
	if err := t.readyToMerge(); err != nil {
		return g.stop(codeOf(err), "%s", err.Error())
	}
	if branch := r.mainTreeBranch(); branch != "main" {
		return g.stop(refused, "the main working tree is on %s, not main, so main cannot be fast-forwarded there. Nothing was changed; %s.", branch, g.state())
	}
	if r.remote != "" {
		if _, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main"); err != nil {
			return g.stop(failed, "GitHub could not be reached (%s). Nothing was changed; %s.", reason(err), g.state())
		}
	}
	release, note, err := r.lockMerge(m, t.branch)
	if err != nil {
		return g.stop(codeOf(err), "%s", err.Error())
	}
	defer release()
	if note != "" {
		g.note("%s", note)
	}
	stopped := func() bool { return interrupted.Err() != nil }

	diverged, finished, code := g.bringMainCurrent(m)
	if finished {
		return g.said, code
	}
	if stopped() {
		return g.stop(failed, "interrupted while bringing local main current. %s.", g.state())
	}
	if g.commits, err = r.count("main.." + t.branch); err != nil {
		return g.stop(failed, "what %s holds against main cannot be read (%s). %s.", t.branch, reason(err), g.state())
	}
	// A task already on local main is merged only to join a GitHub that moved on meanwhile (a retry after a failed push).
	alreadyMerged := g.commits == 0
	if alreadyMerged && !diverged {
		where := "on main"
		if r.remote != "" {
			if _, err := git(r.top, "merge-base", "--is-ancestor", t.branch, "refs/remotes/"+r.remote+"/main"); err == nil {
				where = "on main and on GitHub"
			}
		}
		return g.stop(refused, "%s has no commits that main lacks: its tip, %s, is %s; remove it with: carson remove %s", t.branch, r.short(t.branch), where, t.branch)
	}
	if said, code, ok := g.bringTaskUpToMain(); !ok {
		return said, code
	}
	if stopped() {
		return g.stop(failed, "interrupted while bringing %s up to main. %s.", t.branch, g.state())
	}
	if diverged {
		carried := len(g.said)
		if said, code, ok := g.joinGitHub(); !ok {
			return said, code
		}
		if len(g.said) == carried {
			g.note("GitHub's main had diverged; its commits are merged into %s first.", t.branch)
		}
	}
	head, _ := git(t.path, "rev-parse", "HEAD")
	branch, _ := git(t.path, "symbolic-ref", "--short", "-q", "HEAD")
	checks, err := runChecks(t.path)
	if stopped() {
		return g.stop(failed, "interrupted during the checks. %s.", g.state())
	}
	if err != nil && codeOf(err) == refused {
		return g.stop(refused, "%s\n%s. Fix what bin/check reports, commit, then run carson merge again.", err.Error(), g.state())
	}
	if err != nil {
		return g.stop(codeOf(err), "%s\n%s.", err.Error(), g.state())
	}
	if changed := g.checksChanged(head, branch); changed != "" {
		return g.stop(failed, "bin/check changed the task: %s; the merge stops. Look at the worktree before going on.", changed)
	}
	tip := head
	if g.commits, err = r.ownCommits(tip); err != nil {
		return g.stop(failed, "what %s holds against main cannot be read (%s). %s.", t.branch, reason(err), g.state())
	}
	if said, code, ok := g.fastForward(tip); !ok {
		if stopped() {
			now, _ := git(r.top, "rev-parse", "main")
			return g.stop(failed, "interrupted while fast-forwarding main; main is at %s, the task's tip is %s. %s.", r.short(now), r.short(tip), g.state())
		}
		return said, code
	}
	if stopped() {
		return g.stop(failed, "interrupted after main was fast-forwarded to %s, before it was pushed. Run carson merge again to push.", r.short(tip))
	}
	record.Merged = tip
	if err := writeOwner(t.admin, record); err != nil {
		g.note("The owner record could not note the merge (%s).", err.Error())
	}
	shortTip := r.short(tip)
	how := g.how(alreadyMerged)
	if r.remote == "" {
		g.note("Merged %s into main by fast-forward at %s (%s). No GitHub remote: main is on this machine only. %s", t.branch, shortTip, how, checks)
		return g.said, done
	}
	now, err := r.pushMain()
	var unchecked pushedUnchecked
	switch {
	case wasCut(err):
		g.note("Merged %s into local main at %s. Whether it reached GitHub is unknown (%s). Run carson merge again to push or confirm it.", t.branch, shortTip, reason(err))
		return g.said, failed
	case errors.As(err, &unchecked):
		g.note("Merged %s into local main at %s and pushed, but %s. Run carson merge again to check it.", t.branch, shortTip, unchecked.why)
		return g.said, failed
	case err != nil:
		g.note("Merged %s into local main at %s. Not on GitHub (%s). Run carson merge again to push.", t.branch, shortTip, reason(err))
		return g.said, failed
	}
	g.note("Merged %s into main by fast-forward at %s (%s) and pushed; GitHub's main is %s. %s Remove the worktree with: carson remove %s (from outside it).", t.branch, shortTip, how, now, checks, t.branch)
	return g.said, done
}

// how says what the merge carried: "2 commits, rebased onto main first", or, for a task already on local main, what joined it.
func (g *merging) how(alreadyMerged bool) string {
	if alreadyMerged {
		return "already on local main, with GitHub's main merged in"
	}
	s := plural(g.commits, "commit")
	if g.update != "" {
		s += ", " + g.update + " first"
	}
	if g.joined {
		s += ", carrying GitHub's main"
	}
	return s
}

// readyToMerge refuses a worktree in the middle of a git operation, or holding uncommitted files: carson never commits for anyone.
func (t task) readyToMerge() error {
	gitdir, err := git(t.path, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return refuse(failed, "the worktree's git folder cannot be found (%s).", reason(err))
	}
	if err := operationInProgress(gitdir, "this worktree", "carson merge"); err != nil {
		return err
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
		return refuse(refused, "%s %s uncommitted — %s. Commit them in this worktree, then run carson merge.", plural(len(found), "file"), isOrAre(len(found)), strings.Join(names, ", "))
	}
	return nil
}

// operationInProgress refuses a worktree whose git folder shows a git operation stopped part way, saying how to finish it or give it
// up; where names the worktree, and then is what to run after.
func operationInProgress(gitdir, where, then string) error {
	for _, operation := range []struct{ marker, name, command string }{
		{"rebase-merge", "rebase", "git rebase"}, {"rebase-apply", "rebase", "git rebase"}, {"MERGE_HEAD", "merge", "git merge"},
		{"CHERRY_PICK_HEAD", "cherry-pick", "git cherry-pick"}, {"REVERT_HEAD", "revert", "git revert"},
	} {
		if _, err := os.Stat(filepath.Join(gitdir, operation.marker)); err == nil {
			return refuse(refused, "a %s is in progress in %s. Finish it with %s --continue, or give it up with %s --abort, then run %s.", operation.name, where, operation.command, operation.command, then)
		}
	}
	return nil
}

// bringMainCurrent brings local main current for the merge: merged work GitHub lacks is pushed first — and when the task was all it
// lacked, the merge is finished; GitHub's commits come in by fast-forward; a divergence is returned, for the task to join.
func (g *merging) bringMainCurrent(m Machine) (diverged, finished bool, code int) {
	r := g.repo
	if r.remote == "" {
		return false, false, done
	}
	tracking, err := r.fetchMain()
	if err != nil {
		g.said, code = g.stop(failed, "GitHub's main could not be fetched (%s). Nothing was changed; %s.", reason(err), g.state())
		return false, true, code
	}
	ahead, behind, err := r.aheadBehind(tracking)
	if err != nil {
		g.said, code = g.stop(failed, "how local main stands against GitHub's is unknown (%s). %s.", reason(err), g.state())
		return false, true, code
	}
	switch {
	case ahead > 0 && behind > 0:
		return true, false, done
	case ahead > 0:
		now, err := r.pushMain()
		var unchecked pushedUnchecked
		switch {
		case wasCut(err):
			g.said, code = g.stop(failed, "local main holds %s GitHub lacked; whether pushing them reached GitHub is unknown (%s). %s.", plural(ahead, "commit"), reason(err), g.state())
			return false, true, code
		case errors.As(err, &unchecked):
			g.said, code = g.stop(failed, "local main held %s GitHub lacked; it was pushed, but %s. %s.", plural(ahead, "commit"), unchecked.why, g.state())
			return false, true, code
		case err != nil:
			g.said, code = g.stop(failed, "local main holds %s GitHub lacks, and pushing them failed (%s). %s.", plural(ahead, "commit"), reason(err), g.state())
			return false, true, code
		}
		if merged, _ := r.count("main.." + g.task.branch); merged == 0 {
			g.note("%s was already merged into local main at %s; pushed it now. GitHub's main is %s.", g.task.branch, r.short("main"), now)
			return false, true, done
		}
		g.note("Pushed %s of local main that GitHub lacked; GitHub's main is now %s.", plural(ahead, "commit"), now)
	case behind > 0:
		inTheWay, err := r.forwardMain(tracking)
		if len(inTheWay) > 0 {
			g.said, code = g.stop(refused, "bringing local main forward would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s.", strings.Join(inTheWay, ", "), g.state())
			return false, true, code
		}
		if err != nil {
			g.said, code = g.stop(failed, "local main could not be brought forward to GitHub's (%s). %s.", reason(err), g.state())
			return false, true, code
		}
		g.note("Local main was %s behind GitHub's and is brought forward to it.", plural(behind, "commit"))
	}
	return false, false, done
}

// bringTaskUpToMain brings the task up to local main when main holds commits it lacks: by rebasing, or — for a task that already
// carries a merge, which a rebase would flatten into duplicates — by merging main into it.
func (g *merging) bringTaskUpToMain() ([]string, int, bool) {
	r, t := g.repo, g.task
	behind, err := r.count(t.branch + "..main")
	if err != nil {
		said, code := g.stop(failed, "how %s stands against main cannot be read (%s). %s.", t.branch, reason(err), g.state())
		return said, code, false
	}
	if behind == 0 {
		return nil, 0, true
	}
	merges, _ := git(t.path, "rev-list", "--merges", "main.."+t.branch)
	operation, update := step{name: "rebase", doing: "rebasing onto main (" + r.short("main") + ")", command: "git rebase main", args: []string{"rebase", "-q", "main"}}, "rebased onto main"
	if merges != "" {
		operation, update = step{name: "merge", doing: "merging main (" + r.short("main") + ")", command: "git merge main", args: []string{"merge", "-q", "--no-edit", "main"}}, "with main merged in"
	}
	if said, code, ok := g.run(operation); !ok {
		return said, code, false
	}
	g.update = update
	return nil, 0, true
}

// joinGitHub merges GitHub's main into the task, when the two mains have diverged, so the task carries both (§3.4 of the design).
// A task that already carries it — a re-run after an earlier join — is said to, not merged again.
func (g *merging) joinGitHub() ([]string, int, bool) {
	tracking := g.repo.remote + "/main"
	if _, err := git(g.task.path, "merge-base", "--is-ancestor", "refs/remotes/"+tracking, "HEAD"); err == nil {
		g.joined = true
		g.note("%s already carries GitHub's main.", g.task.branch)
		return nil, 0, true
	}
	operation := step{name: "merge", doing: "merging GitHub's main (" + g.repo.short("refs/remotes/"+tracking) + ")", command: "git merge " + tracking, args: []string{"merge", "-q", "--no-edit", "refs/remotes/" + tracking}}
	if said, code, ok := g.run(operation); !ok {
		return said, code, false
	}
	g.joined = true
	return nil, 0, true
}

// step is a rebase or merge carson runs in the task's worktree.
type step struct {
	name, doing, command string
	args                 []string
}

// run runs a rebase or merge in the task's worktree. When it stops, carson gives it up, looks that the task is back where the step
// found it, and says so — with the files in conflict and the command to run — or says what it found instead.
func (g *merging) run(s step) ([]string, int, bool) {
	t := g.task
	before, _ := git(t.path, "rev-parse", "HEAD")
	_, err := git(t.path, s.args...)
	if err == nil {
		return nil, 0, true
	}
	conflicts, _ := git(t.path, "diff", "--name-only", "--diff-filter=U")
	git(t.path, s.name, "--abort")
	now, _ := git(t.path, "rev-parse", "HEAD")
	left, _ := changes(t.path)
	if now != before || len(left) > 0 {
		said, code := g.stop(failed, "%s failed (%s), and giving it up left %s at %s with %s, not at %s where it began. Look before going on.", s.doing, reason(err), t.branch, g.repo.short(now), plural(len(left), "change"), g.repo.short(before))
		return said, code, false
	}
	where := "as it was, at " + g.repo.short(before)
	if before != g.original {
		where = fmt.Sprintf("%s at %s (it was at %s before carson)", g.update, g.repo.short(before), g.repo.short(g.original))
	}
	files := strings.Join(lines(conflicts), ", ")
	if files == "" {
		said, code := g.stop(failed, "%s failed (%s). It was given up; %s is %s.", s.doing, reason(err), t.branch, where)
		return said, code, false
	}
	said, code := g.stop(refused, "%s conflicts in %s. The %s was undone; %s is %s. Run %s in this worktree, resolve, then carson merge.", s.doing, files, s.name, t.branch, where, s.command)
	return said, code, false
}

// checksChanged says how bin/check changed the task, or "": the branch it is on, its commit, and the files it holds must be as before.
func (g *merging) checksChanged(head, branch string) string {
	t := g.task
	nowBranch, _ := git(t.path, "symbolic-ref", "--short", "-q", "HEAD")
	nowHead, _ := git(t.path, "rev-parse", "HEAD")
	left, err := changes(t.path)
	switch {
	case nowBranch != branch:
		if nowBranch == "" {
			nowBranch = "a detached HEAD"
		}
		return fmt.Sprintf("the worktree is now on %s, not %s, and %s is at %s", nowBranch, branch, branch, g.repo.short(head))
	case nowHead != head:
		return fmt.Sprintf("%s moved from %s to %s", branch, g.repo.short(head), g.repo.short(nowHead))
	case err != nil:
		return "what the worktree holds cannot be read (" + reason(err) + ")"
	case len(left) > 0:
		return fmt.Sprintf("it left %s in the worktree", plural(len(left), "change"))
	}
	return ""
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
	if len(tail) == 0 {
		return "", refuse(refused, "bin/check failed (%s). It printed nothing.", exit)
	}
	if len(tail) > 20 {
		tail = tail[len(tail)-20:]
	}
	return "", refuse(refused, "bin/check failed (%s). Its output ends:\n%s", exit, strings.Join(tail, "\n"))
}

// fastForward moves main to the task's tip in the main working tree, never over what that tree holds, and looks that it moved.
func (g *merging) fastForward(tip string) ([]string, int, bool) {
	r := g.repo
	if branch := r.mainTreeBranch(); branch != "main" {
		said, code := g.stop(refused, "the main working tree is on %s, not main, so main cannot be fast-forwarded there. %s.", branch, g.state())
		return said, code, false
	}
	inTheWay, err := r.forwardMain(tip)
	if len(inTheWay) > 0 {
		said, code := g.stop(refused, "fast-forwarding main would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s.", strings.Join(inTheWay, ", "), g.state())
		return said, code, false
	}
	if err != nil {
		said, code := g.stop(failed, "main could not be fast-forwarded (%s). %s.", reason(err), g.state())
		return said, code, false
	}
	if now, _ := git(r.top, "rev-parse", "main"); now != tip {
		said, code := g.stop(failed, "main was fast-forwarded, but it is at %s, not the task's %s. Look before going on.", r.short(now), r.short(tip))
		return said, code, false
	}
	return nil, 0, true
}
