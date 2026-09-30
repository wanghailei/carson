package carson

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// startTask starts a task as this test's Claude session and returns its worktree.
func (f *fixture) startTask(name string) string {
	f.t.Helper()
	if out, code := f.runIn(inClaude, f.local, claudeRunning, "start", name); code != 0 {
		f.t.Fatalf("carson start %s: %s", name, out)
	}
	return f.taskFolder(name)
}

func (f *fixture) merge(dir string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, dir, claudeRunning, "merge")
}

func (f *fixture) short(dir, revision string) string {
	return f.git(dir, "rev-parse", "--short", revision)
}

func TestMergeFastForwardsMainAndPushes(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.commit(dir, "login_test.rb")
	tip := f.git(dir, "rev-parse", "HEAD")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Merged fix-login into main by fast-forward at "+short+" (2 commits) and pushed; GitHub's main is "+short+". No checks declared (no bin/check). Remove the worktree with: carson remove fix-login (from outside it).")
	if f.git(f.local, "rev-parse", "main") != tip || f.git(f.github, "rev-parse", "main") != tip {
		t.Error("main, here or on GitHub, is not the task's tip")
	}
	if record := f.readRecord(dir); record.Merged != tip {
		t.Errorf("the owner record does not name the merge: %+v", record)
	}
}

func TestMergeRebasesOntoANewerMainFirst(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.otherMachine()
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Merged fix-login into main by fast-forward at "+short+" (1 commit, rebased onto main first) and pushed; GitHub's main is "+short+".")
	if f.git(f.github, "rev-parse", "main") != f.git(dir, "rev-parse", "HEAD") {
		t.Error("GitHub's main is not the rebased task")
	}
}

func TestMergeRefusesUncommittedFiles(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.write(dir, "notes.txt", "unsaved\n")
	f.write(dir, "login.rb", "changed\n")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: 2 files are uncommitted — login.rb, notes.txt. Commit them in this worktree, then run carson merge.")
}

func TestMergeRefusesATaskWithNothingMainLacks(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: fix-login has no commits that main lacks. Its work is on main and on GitHub at "+f.short(f.local, "main")+"; remove it with: carson remove fix-login")
}

func TestMergeUndoesAConflictingRebase(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "the task's line\n")
	f.git(dir, "commit", "-q", "-am", "change first here")
	before := f.git(dir, "rev-parse", "HEAD")
	other := f.otherClone()
	f.write(other, "first.txt", "the other machine's line\n")
	f.git(other, "commit", "-q", "-am", "change first there")
	f.git(other, "push", "-q", "origin", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: rebasing onto main ("+f.short(f.local, "main")+") conflicts in first.txt. The rebase was undone; fix-login is as it was, at "+f.short(dir, "HEAD")+". Run git rebase main in this worktree, resolve, then carson merge.")
	if f.git(dir, "rev-parse", "HEAD") != before || f.git(dir, "status", "--porcelain") != "" || f.exists(filepath.Join(f.git(dir, "rev-parse", "--absolute-git-dir"), "rebase-merge")) {
		t.Error("the task is not as it was")
	}
}

func (f *fixture) check(dir, script string) {
	f.t.Helper()
	os.MkdirAll(filepath.Join(dir, "bin"), 0o755)
	if err := os.WriteFile(filepath.Join(dir, "bin", "check"), []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	f.git(dir, "add", "bin/check")
	f.git(dir, "commit", "-q", "-m", "add bin/check")
}

func TestMergeStopsWhenTheChecksFail(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "echo 2 tests failed; exit 1")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: bin/check failed (exit 1). Its output ends:")
	if !strings.Contains(out, "Fix what bin/check reports, commit, then run carson merge again.") {
		t.Errorf("no way on after failed checks:\n%s", out)
	}
	expectLine(t, out, "2 tests failed")
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved although the checks failed")
	}
}

func TestMergeSaysTheChecksPassed(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 0")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	if !strings.Contains(out, "Checks: bin/check passed.") {
		t.Errorf("the checks are not reported:\n%s", out)
	}
}

func TestMergeWhosePushFailsSaysSoAndIsPushedByTheNextMerge(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Merged fix-login into local main at "+short+". Not on GitHub (")
	if !strings.Contains(out, "Run carson merge again to push.") {
		t.Errorf("the way to push is not named:\n%s", out)
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	out, code = f.merge(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "fix-login was already merged into local main at "+short+"; pushed it now. GitHub's main is "+short+".")
}

func TestMergeRefusesAnotherSessionsTask(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", "fix-login")
	dir := f.taskFolder("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.runIn(inClaude, dir, stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}, "merge")
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: fix-login belongs to Claude session 4e7a91d2-other on test-mac, which is live. Only its owner merges it.")
}

func TestMergeRefusesInTheMainWorkingTree(t *testing.T) {
	f := newFixture(t)
	out, code := f.merge(f.local)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: carson merge runs inside a task's worktree; "+f.local+" is the main working tree.")
}

func TestMergeRefusesATaskMadeOutsideCarson(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: fix-login was made outside carson, so whose it is cannot be told; that is the master's to settle.")
}

func TestMergeRefusesWhenGitHubCannotBeReached(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "remote", "set-url", "github", filepath.Join(f.root, "no-such-repository.git"))
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: GitHub could not be reached (")
	if !strings.Contains(out, "Nothing was changed; fix-login still holds its 1 commit.") || f.git(f.local, "rev-parse", "main") != main {
		t.Errorf("not refused before any change:\n%s", out)
	}
}

func TestMergeRefusesWhileARebaseIsInProgress(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "here\n")
	f.git(dir, "commit", "-q", "-am", "here")
	f.git(f.local, "commit", "-q", "--allow-empty", "-m", "on main") // a commit main has and the task lacks
	f.write(f.local, "first.txt", "main's\n")
	f.git(f.local, "commit", "-q", "-am", "main changes first")
	f.git(f.local, "push", "-q", "github", "main")
	command := []string{"rebase", "main"}
	if out, err := git(dir, command...); err == nil {
		t.Fatalf("the staged rebase did not stop: %s", out)
	}
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: a rebase is in progress in this worktree. Finish it with git rebase --continue, or give it up with git rebase --abort, then run carson merge.")
}

func TestMergeRefusesWhenTheMainTreeIsOffMain(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: the main working tree is on elsewhere, not main, so main cannot be fast-forwarded there. Nothing was changed; fix-login still holds its 1 commit.")
}

func TestMergeRefusesToOverwriteWhatTheMainTreeHolds(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "notes.md")
	f.write(f.local, "notes.md", "the master's own notes\n")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: fast-forwarding main would overwrite what the main working tree holds in notes.md (untracked, changed ")
	if content, _ := os.ReadFile(filepath.Join(f.local, "notes.md")); string(content) != "the master's own notes\n" || f.git(f.local, "rev-parse", "main") != main {
		t.Error("the main working tree's file or main was changed")
	}
}

func TestMergeJoinsDivergedMains(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.commit(f.local, "merged-here.txt") // merged here, not yet pushed
	f.otherMachine()
	theirs := f.git(f.github, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	if !strings.Contains(out, "GitHub's main had diverged; its commits are merged into fix-login first.") {
		t.Errorf("the divergence is not reported:\n%s", out)
	}
	for _, file := range []string{"merged-here.txt", "login.rb"} {
		if _, err := git(f.github, "cat-file", "-e", "main:"+file); err != nil {
			t.Errorf("GitHub's main lacks %s", file)
		}
	}
	if _, err := git(f.github, "merge-base", "--is-ancestor", theirs, "main"); err != nil {
		t.Error("GitHub's main lost the other machine's commit")
	}
}

func TestMergeRefusesWhileALiveMergeHoldsTheLockAndTakesOverAStaleOne(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), mergeLockFile)
	held := Record{Task: "other-task", Harness: "claude", Session: "4e7a91d2-other", PID: 5000, Started: "Wed Sep 30 07:00:00 2026", Machine: "test-mac"}
	if err := writeRecordFile(lock, held); err != nil {
		t.Fatal(err)
	}
	running := stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}
	out, code := f.runIn(inClaude, dir, running, "merge")
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: another merge is running in this repository — other-task, by Claude session 4e7a91d2-other on test-mac. Run carson merge again when it has finished. Nothing was changed.")
	out, code = f.merge(dir) // process 5000 has ended
	expectCode(t, code, 0)
	expectLine(t, out, "The merge lock left by an ended carson (other-task, by Claude session 4e7a91d2-other on test-mac) is taken over.")
	if f.exists(lock) {
		t.Error("the merge lock was not released")
	}
}

func TestMergeWithoutARemoteMergesLocally(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Merged fix-login into main by fast-forward at "+f.short(dir, "HEAD")+" (1 commit). No GitHub remote: main is on this machine only.")
}

// Cases from the review of cca4a81, each staged there against the slice before it was fixed.

func TestMergeStopsWhenTheCheckMovesTheBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.check(dir, "git reset -q --hard main")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: bin/check changed the task: fix-login moved from ")
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved")
	}
}

func TestMergeStopsWhenTheCheckSwitchesBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "git switch -q -c scratch && echo x > x.txt && git add x.txt && git commit -q -m scratch")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: bin/check changed the task: the worktree is now on scratch, not fix-login")
	if f.git(f.local, "rev-parse", "main") != main || f.git(f.github, "rev-parse", "main") != main {
		t.Error("main moved, here or on GitHub")
	}
}

func TestMergeRetryAfterAFailedPushJoinsAGitHubThatMovedOn(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	if _, code := f.merge(dir); code != 1 {
		t.Fatal("the first merge's push did not fail")
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	f.otherMachine()
	theirs := f.git(f.github, "rev-parse", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	if !strings.Contains(out, "and pushed; GitHub's main is ") {
		t.Errorf("not merged and pushed:\n%s", out)
	}
	for _, commit := range []string{theirs, f.git(dir, "rev-parse", "HEAD^1")} {
		if _, err := git(f.github, "merge-base", "--is-ancestor", commit, "main"); err != nil {
			t.Errorf("GitHub's main lacks %s", commit)
		}
	}
}

func TestMergeConflictJoiningGitHubSaysTheTaskWasRebased(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "shared.txt", "the task's\n")
	f.git(dir, "add", "shared.txt")
	f.git(dir, "commit", "-q", "-m", "task adds shared")
	original := f.short(dir, "HEAD")
	f.commit(f.local, "merged-here.txt") // local main moves on: the task will be rebased
	other := f.otherClone()
	f.write(other, "shared.txt", "the other machine's\n")
	f.git(other, "add", "shared.txt")
	f.git(other, "commit", "-q", "-m", "other adds shared")
	f.git(other, "push", "-q", "origin", "main")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	if !strings.Contains(out, "The merge was undone; fix-login is rebased onto main at "+f.short(dir, "HEAD")+" (it was at "+original+" before carson).") {
		t.Errorf("the rebase is not said:\n%s", out)
	}
}

func TestMergeFailedCheckAfterARebaseSaysSo(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 1")
	original := f.short(dir, "HEAD")
	f.otherMachine()
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: bin/check failed (exit 1). It printed nothing.")
	if !strings.Contains(out, "fix-login still holds its 1 commit, now rebased onto main (it was at "+original+" before carson).") {
		t.Errorf("the rebase is not said:\n%s", out)
	}
}

func TestGitGivesTheReasonNotTheURLLine(t *testing.T) {
	f := newFixture(t)
	_, err := git(f.local, "-c", `alias.reject=!printf 'To /x/github.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs\n' >&2; exit 1`, "reject")
	if err == nil || reason(err) != "! [rejected]        main -> main (fetch first)" {
		t.Errorf("reason: %q", reason(err))
	}
}

func TestMergeWhosePushIsCutOffDoesNotClaimItFailed(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	bin := filepath.Join(f.root, "bin")
	os.Mkdir(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "git-remote-silent"), []byte("#!/bin/sh\nsleep 20\n"), 0o755)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	f.git(f.local, "config", "remote.github.pushurl", "silent::nowhere")
	limit := networkLimit
	networkLimit = 2 * time.Second
	t.Cleanup(func() { networkLimit = limit })
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Merged fix-login into local main at "+f.short(dir, "HEAD")+". Whether it reached GitHub is unknown (no answer within 2s). Run carson merge again to push or confirm it.")
}

func TestMergeKeepsATaskThatCarriesAJoinUnflattened(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 1")
	f.commit(f.local, "merged-here.txt")
	f.otherMachine()
	if _, code := f.merge(dir); code != 2 {
		t.Fatal("the failing check did not stop the first merge")
	}
	f.write(filepath.Join(dir, "bin"), "check", "#!/bin/sh\nexit 0\n")
	f.git(dir, "commit", "-q", "-am", "fix the check")
	f.commit(f.local, "merged-here-2.txt")
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	if n := f.git(f.github, "log", "main", "--format=%s"); strings.Count(n, "add other-") != 1 {
		t.Errorf("GitHub's main holds the other machine's commit more than once:\n%s\n%s", n, out)
	}
}

func TestMergeInterruptedDuringTheCheckEndsInOneLineAndGivesBackTheLock(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "sleep 2")
	main := f.git(f.local, "rev-parse", "main")
	go func() {
		time.Sleep(700 * time.Millisecond)
		syscall.Kill(os.Getpid(), syscall.SIGINT)
	}()
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: interrupted during the checks.")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), mergeLockFile)
	if f.exists(lock) || f.git(f.local, "rev-parse", "main") != main {
		t.Error("the lock is still held, or main moved")
	}
}

func TestMergeRefusesToOverwriteAModifiedFileInTheMainTree(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "the task's\n")
	f.git(dir, "commit", "-q", "-am", "task changes first")
	f.write(f.local, "first.txt", "the master's edit\n")
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not merged: fast-forwarding main would overwrite what the main working tree holds in first.txt (modified, changed ")
}

func TestMergeRefusesALockWhoseHolderCannotBeChecked(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), mergeLockFile)
	writeRecordFile(lock, Record{Task: "other-task", Harness: "claude", Session: "4e7a91d2-other", PID: 5000, Started: "x", Machine: "linux-box", MachineID: "linux-id"})
	out, code := f.merge(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not merged: the merge lock is held by other-task's merge, by Claude session 4e7a91d2-other on linux-box, whose state is unknown (it cannot be checked from test-mac). Nothing was changed.")
}

// From the review of fdb5297: a task already on local main, and a re-run over a join already made.
func TestMergeOfATaskAlreadyOnMainSaysItHoldsNothingOfItsOwn(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	flag := filepath.Join(f.root, "fail-checks")
	f.check(dir, "test ! -e "+flag)
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	if _, code := f.merge(dir); code != 1 {
		t.Fatal("the first merge's push did not fail")
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	f.otherMachine()
	os.WriteFile(flag, nil, 0o644)
	out, code := f.merge(dir)
	expectCode(t, code, 2)
	if !strings.Contains(out, "fix-login holds nothing of its own that main lacks, with GitHub's main merged in") {
		t.Errorf("the task's state is not said truly:\n%s", out)
	}
}

func TestMergeRerunOverAJoinAlreadyMadeCountsOnlyTheTasksOwnCommits(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	flag := filepath.Join(f.root, "fail-checks")
	f.check(dir, "test ! -e "+flag)
	f.commit(dir, "login.rb")
	f.commit(f.local, "merged-here.txt")
	f.otherMachine()
	os.WriteFile(flag, nil, 0o644)
	if _, code := f.merge(dir); code != 2 {
		t.Fatal("the failing check did not stop the first merge")
	}
	os.Remove(flag)
	out, code := f.merge(dir)
	expectCode(t, code, 0)
	if strings.Contains(out, "its commits are merged into fix-login first") {
		t.Errorf("a join that changed nothing is reported as made:\n%s", out)
	}
	if !strings.Contains(out, "fix-login already carries GitHub's main.") || !strings.Contains(out, "(2 commits, ") {
		t.Errorf("not said that the task carries GitHub's main, or its own commits miscounted:\n%s", out)
	}
}
