package carson

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// busy is a machine where some processes work inside a folder, or where that cannot be told.
type busy struct {
	stranger
	inside []string
	err    error
}

func (b busy) Inside(dir string) ([]string, error) { return b.inside, b.err }

func (f *fixture) remove(args ...string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, f.local, claudeRunning, append([]string{"remove"}, args...)...)
}

func (f *fixture) abandon(args ...string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, f.local, claudeRunning, append([]string{"abandon"}, args...)...)
}

// mergedTask starts a task, commits in it and merges it, as the steps before carson remove.
func (f *fixture) mergedTask(name string) string {
	f.t.Helper()
	dir := f.startTask(name)
	f.commit(dir, name+".rb")
	if out, code := f.land(dir); code != 0 {
		f.t.Fatalf("carson land: %s", out)
	}
	return dir
}

func TestRemoveRemovesAMergedTask(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed fix-login: its worktree at "+dir+", and its branch, landed on main at "+f.short(f.local, "main")+". It was owned by Claude session 9cb74d03-a065 on test-mac.")
	if f.exists(dir) || f.git(f.local, "branch", "--list", "fix-login") != "" {
		t.Error("the worktree or the branch is still there")
	}
}

func TestRemoveRefusesFromInsideTheWorktree(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	out, code := f.runIn(inClaude, dir, claudeRunning, "remove", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: carson remove runs from outside the worktree it removes; run it from "+f.local+".")
}

func TestRemoveRefusesUncommittedFiles(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	f.write(dir, "notes.txt", "unsaved\n")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login holds 1 uncommitted file — notes.txt. Commit it and land it, or abandon the task: carson abandon fix-login")
}

func TestRemoveRefusesWorkNotOnMain(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login holds 1 commit not on main. Land it with carson land fix-login, or abandon the task: carson abandon fix-login")
}

func TestRemoveKeepsIgnoredFiles(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, ".gitignore", "local.env\n")
	f.git(dir, "add", ".gitignore")
	f.git(dir, "commit", "-q", "-m", "ignore local.env")
	f.land(dir)
	f.write(dir, "local.env", "SECRET=kept\n")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	kept := filepath.Join(f.root, ".cache", "deleted", "local")
	matches, _ := filepath.Glob(filepath.Join(kept, "fix-login-*", "local.env"))
	if len(matches) != 1 {
		t.Fatalf("the ignored file is not kept under %s:\n%s", kept, out)
	}
	if content, _ := os.ReadFile(matches[0]); string(content) != "SECRET=kept\n" {
		t.Errorf("kept with %q", content)
	}
	expectLine(t, out, "Its 1 ignored file (local.env) is kept in "+filepath.Dir(matches[0])+".")
}

func TestRemoveRefusesWhileProcessesWorkInside(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	out, code := f.runIn(inClaude, f.local, busy{stranger: claudeRunning, inside: []string{"puma (pid 4121)"}}, "remove", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: processes are working inside it — puma (pid 4121). Stop them, then run carson remove fix-login again.")
}

func TestRemoveRefusesWhenProcessesCannotBeChecked(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	out, code := f.runIn(inClaude, f.local, busy{stranger: claudeRunning, err: errors.New("lsof: not found")}, "remove", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not removed: whether any process works inside it cannot be checked (lsof: not found). Nothing was changed.")
}

func TestRemoveRefusesAnotherSessionsTask(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", "fix-login")
	out, code := f.runIn(inClaude, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}, "remove", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login belongs to Claude session 4e7a91d2-other on test-mac, which is live. Only its owner removes it.")
}

func TestRemoveRefusesAWorktreeMadeOutsideCarson(t *testing.T) {
	f := newFixture(t)
	f.worktree("fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login was made outside carson, so whose it is cannot be told; that is the master's to settle.")
}

func TestRemoveClearsALeftoverBranchWhoseWorkIsOnMain(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed the leftover branch fix-login: it had no worktree, and its work is on main.")
	if f.git(f.local, "branch", "--list", "fix-login") != "" {
		t.Error("the branch is still there")
	}
}

func TestRemoveRefusesAnUnknownName(t *testing.T) {
	f := newFixture(t)
	out, code := f.remove("no-such-task")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: no task or branch is named no-such-task.")
}

func TestRemoveWithoutANameShowsHow(t *testing.T) {
	f := newFixture(t)
	out, code := f.remove()
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: name the task, as in carson remove fix-login.")
}

func TestRemoveAbandonedKeepsEverything(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.write(dir, "draft.txt", "half done\n")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 0)
	kept := f.git(f.local, "rev-parse", "--short", "abandoned/fix-login")
	expectLine(t, out, "Abandoned fix-login: its work — 2 commits, the last holding what was uncommitted — is kept as branch abandoned/fix-login at "+kept+", and its worktree is removed. Take it up again with: carson adopt fix-login")
	if f.exists(dir) {
		t.Error("the worktree is still there")
	}
	if _, err := git(f.local, "cat-file", "-e", "abandoned/fix-login:draft.txt"); err != nil {
		t.Error("the uncommitted file is not kept on the branch")
	}
}

// The real boundary: a process whose working folder is inside a folder is found there.
func TestPSFindsAProcessWorkingInsideAFolder(t *testing.T) {
	dir, _ := filepath.EvalSymlinks(t.TempDir())
	sleeper := exec.Command("sleep", "5")
	sleeper.Dir = dir
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	defer sleeper.Process.Kill()
	var inside []string
	var err error
	for waited := 0; waited < 40 && len(inside) == 0; waited++ {
		time.Sleep(50 * time.Millisecond)
		if inside, err = (PS{}).Inside(dir); err != nil {
			t.Fatal(err)
		}
	}
	if !strings.Contains(strings.Join(inside, ", "), "sleep (pid ") {
		t.Errorf("the sleeping process is not found inside %s: %v", dir, inside)
	}
}

// Cases from the review of 532fdde, each staged there against the slice before it was fixed.

func TestRemoveRefusesTheTrunk(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "--detach", "main")
	for _, name := range []string{"main", "master"} {
		out, code := f.remove(name)
		expectCode(t, code, 2)
		expectLine(t, out, "Not removed: "+name+" is a trunk's name, not a task's.")
	}
	if _, err := git(f.local, "rev-parse", "--verify", "-q", "refs/heads/main"); err != nil {
		t.Error("main was deleted")
	}
}

func TestRemoveRefusesALeftoverBranchCheckedOutSomewhere(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, code := f.remove("elsewhere")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: branch elsewhere is checked out in the main working tree, at "+f.local+". Switch it back to main, then run carson remove elsewhere again.")
}

func TestRemoveAbandonedRefusesWhileARebaseIsInProgress(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "here\n")
	f.git(dir, "commit", "-q", "-am", "here")
	f.write(f.local, "first.txt", "main's\n")
	f.git(f.local, "commit", "-q", "-am", "main changes first")
	if _, err := git(dir, "rebase", "main"); err == nil {
		t.Fatal("the staged rebase did not stop")
	}
	out, code := f.abandon("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not abandoned: a rebase is in progress in fix-login's worktree. Finish it with git rebase --continue, or give it up with git rebase --abort, then run carson abandon fix-login again.")
}

func TestRemoveRefusesANestedRepository(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	nested := filepath.Join(dir, "vendor", "lib")
	os.MkdirAll(nested, 0o755)
	f.git(nested, "init", "-q")
	f.commit(nested, "lib.rb")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not abandoned: fix-login holds a git repository of its own at vendor/lib, which git cannot remove with the worktree. Move it out, then run carson abandon fix-login again. Nothing was changed.")
	if !f.exists(filepath.Join(nested, "lib.rb")) || f.git(f.local, "branch", "--list", "abandoned/fix-login") != "" {
		t.Error("something was changed")
	}
}

func TestRemoveAbandonedRefusesATaskWithNothingToKeep(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not abandoned: fix-login holds nothing main lacks and nothing uncommitted, so there is nothing to keep; remove it with: carson remove fix-login")
}

func TestRemoveATaskWhoseFolderIsGone(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	os.RemoveAll(dir)
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed fix-login: its worktree at "+dir+", whose folder was already gone, and its branch, landed on main at "+f.short(f.local, "main")+". It was owned by Claude session 9cb74d03-a065 on test-mac.")
	if f.git(f.local, "branch", "--list", "fix-login") != "" || strings.Contains(f.git(f.local, "worktree", "list"), "fix-login") {
		t.Error("the branch or git's record of the worktree is still there")
	}
}

func TestRemoveATaskWhoseFolderIsGoneWithWorkNotOnMain(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	os.RemoveAll(dir)
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login's folder is gone, and its branch holds 1 commit not on main. Keep its work on a branch by abandoning the task: carson abandon fix-login")
}

func TestRemoveAbandonedATaskWhoseFolderIsGone(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	os.RemoveAll(dir)
	out, code := f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Abandoned fix-login: its work — 1 commit — is kept as branch abandoned/fix-login at "+f.short(f.local, "abandoned/fix-login")+", and git's record of its worktree, whose folder was already gone, is removed.")
	if strings.Contains(f.git(f.local, "worktree", "list"), "fix-login") {
		t.Error("git still records the worktree")
	}
}

func TestRemoveAbandonedTakesTheNextFreeName(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "abandoned/fix-login")
	dir := f.startTask("fix-login")
	f.write(dir, "draft.txt", "half done\n")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Abandoned fix-login: its work — 1 commit, holding what was uncommitted — is kept as branch abandoned/fix-login-2 at "+f.short(f.local, "abandoned/fix-login-2")+", and its worktree is removed.")
}

func TestRemoveRefusesACheckedOutSubmodule(t *testing.T) {
	f := newFixture(t)
	library := filepath.Join(f.root, "library")
	os.MkdirAll(library, 0o755)
	f.git(library, "init", "-q")
	f.commit(library, "lib.rb")
	dir := f.startTask("fix-login")
	f.git(dir, "-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "vendor/library")
	f.git(dir, "commit", "-q", "-m", "add the library")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not abandoned: fix-login holds a git repository of its own at vendor/library, which git cannot remove with the worktree.")
}

// Half-done: carson stops where the failure is, and says what it had done and where things stand.

func TestRemoveStopsWhenIgnoredFilesCannotBeKept(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, ".gitignore", "local.env\n")
	f.git(dir, "add", ".gitignore")
	f.git(dir, "commit", "-q", "-m", "ignore local.env")
	f.land(dir)
	f.write(dir, "local.env", "SECRET=kept\n")
	os.MkdirAll(filepath.Join(f.root, ".cache"), 0o755)
	f.write(f.root, ".cache/deleted", "a file where the folder would be\n")
	out, code := f.remove("fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not removed: no folder could be made to keep the worktree's ignored files in (")
	if !strings.Contains(out, "Nothing was changed. Branch fix-login is left as it is.") {
		t.Errorf("the state is not said:\n%s", out)
	}
	if !f.exists(filepath.Join(dir, "local.env")) {
		t.Error("the ignored file was not left in the worktree")
	}
}

func TestRemoveSaysWhereThingsStandWhenGitDeletesOnlyPartOfTheFolder(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	os.MkdirAll(filepath.Join(dir, "locked"), 0o755)
	f.write(dir, "locked/file.txt", "committed\n")
	f.git(dir, "add", "locked")
	f.git(dir, "commit", "-q", "-m", "locked")
	f.land(dir)
	os.Chmod(filepath.Join(dir, "locked"), 0o555)
	t.Cleanup(func() { os.Chmod(filepath.Join(dir, "locked"), 0o755) })
	out, code := f.remove("fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not removed: git could not delete all of its worktree's folder (")
	if !strings.Contains(out, "What is left of the folder, all of it committed, is at "+dir+". Branch fix-login is left as it is.") {
		t.Errorf("the state is not said:\n%s", out)
	}
	out, code = f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed the leftover branch fix-login: it had no worktree, and its work is on main.")
}

// Cases from the re-review of 2d9450a, each staged there against it.

func TestRemoveRefusesATaskWorktreeOffItsBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	f.git(dir, "switch", "-q", "--detach")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login's worktree at "+dir+" is on a detached HEAD, not its branch. Switch it back there with git switch fix-login, then run carson remove fix-login again.")
	if f.git(f.local, "branch", "--list", "fix-login") == "" {
		t.Error("the branch was deleted")
	}
}

func TestRemoveAbandonedChangesNothingWhenTheCommitIsRefused(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "draft.txt", "half done\n")
	hooks := filepath.Join(f.root, "hooks")
	os.MkdirAll(hooks, 0o755)
	os.WriteFile(filepath.Join(hooks, "pre-commit"), []byte("#!/bin/sh\necho 'commit check: refused' >&2\nexit 1\n"), 0o755)
	f.git(f.local, "config", "core.hooksPath", hooks)
	out, code := f.abandon("fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not abandoned: what was uncommitted could not be committed (commit check: refused). Its files are left as they are, none of them staged, on branch fix-login; run carson abandon fix-login again once that is cleared.")
	if f.git(dir, "status", "--porcelain") != "?? draft.txt" || f.git(f.local, "branch", "--list", "abandoned/fix-login") != "" {
		t.Errorf("something was changed: %q", f.git(dir, "status", "--porcelain"))
	}
}

func TestRemoveRefusesALockedWorktree(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, ".gitignore", "local.env\n")
	f.git(dir, "add", ".gitignore")
	f.git(dir, "commit", "-q", "-m", "ignore local.env")
	f.land(dir)
	f.write(dir, "local.env", "SECRET=kept\n")
	f.git(f.local, "worktree", "lock", "--reason", "on a slow disk", dir)
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login's worktree is locked (on a slow disk). If the lock is no longer wanted: git worktree unlock "+dir+", then run carson remove fix-login again.")
	if !f.exists(filepath.Join(dir, "local.env")) {
		t.Error("the ignored file was moved")
	}
}

func TestRemoveRefusesWhileTheMainWorkingTreeIsOffMain(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	f.git(f.local, "switch", "-q", "--detach", "main~1")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: the main working tree is on a detached HEAD, not main, so git cannot safely delete branch fix-login. Switch it back to main, then run carson remove fix-login again.")
}

func TestRemoveRefusesWithoutAHome(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	out, code := f.runIn(environment{"HOME": "", "CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "4121"}, f.local, claudeRunning, "remove", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not removed: HOME does not name a folder, so the worktree's ignored files would have nowhere to be kept. Nothing was changed.")
}

// Cases from the trial of 2026-09-30, where agents of four families used carson in sandboxes, and from Sol's review of 80c2b83.

func TestRemoveAnEmptyTaskSaysItHeldNothing(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed fix-login: its worktree at "+dir+", and its branch, which held nothing main lacks.")
}

func TestRemoveAbandonedCanBeRunAgainAfterAFailure(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, ".gitignore", "local.env\n")
	f.write(dir, "local.env", "SECRET=kept\n")
	os.MkdirAll(filepath.Join(f.root, ".cache"), 0o755)
	f.write(f.root, ".cache/deleted", "a file where the folder would be\n")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not abandoned: no folder could be made to keep the worktree's ignored files in (")
	if !strings.Contains(out, "Its work is on branch fix-login, what was uncommitted now committed; run carson abandon fix-login again once that is cleared.") {
		t.Errorf("no way on:\n%s", out)
	}
	os.Rename(filepath.Join(f.root, ".cache", "deleted"), filepath.Join(f.root, ".cache", "deleted-file"))
	out, code = f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Abandoned fix-login: its work — 1 commit — is kept as branch abandoned/fix-login")
}

func TestRemoveAbandonedKeepsALeftoverBranch(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "fix-login")
	f.git(f.local, "switch", "-q", "fix-login")
	f.commit(f.local, "login.rb")
	f.git(f.local, "switch", "-q", "main")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Kept the leftover branch fix-login, its task declared abandoned, as branch abandoned/fix-login at "+f.short(f.local, "abandoned/fix-login")+" (1 commit not on main).")
}

func TestRemoveKeepsAnAbandonedBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "draft.txt", "half done\n")
	f.abandon("fix-login")
	out, code := f.remove("abandoned/fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: branch abandoned/fix-login holds the work of a task declared abandoned, 1 commit not on main, and carson keeps it. Take it up again with: carson adopt fix-login")
}

func TestFreeFolderNeverSharesAFolder(t *testing.T) {
	base := filepath.Join(t.TempDir(), "kept", "fix-login-20260930-164500")
	first, err := freeFolder(base)
	if err != nil || first != base {
		t.Fatalf("first: %q, %v", first, err)
	}
	second, err := freeFolder(base)
	if err != nil || second != base+"-2" {
		t.Errorf("second: %q, %v", second, err)
	}
}

// From the third trial (Grok): on a folder that ignores case, refs/heads/MAIN is the file of refs/heads/main, and carson remove MAIN
// deleted main.
func TestRemoveNeverTakesAnotherCaseForABranch(t *testing.T) {
	f := newFixture(t)
	for _, name := range []string{"MAIN", "Main", "MASTER"} {
		out, code := f.remove(name)
		expectCode(t, code, 2)
		expectLine(t, out, "Not removed: "+name+" is a trunk's name, not a task's.")
	}
	f.git(f.local, "branch", "fix-login")
	for _, command := range []string{"remove", "abandon"} {
		out, code := f.runIn(inClaude, f.local, claudeRunning, command, "Fix-Login")
		expectCode(t, code, 2)
		expectLine(t, out, "Not ")
		if !strings.Contains(out, "no task or branch is named Fix-Login.") {
			t.Errorf("carson %s Fix-Login:\n%s", command, out)
		}
	}
	if _, err := git(f.local, "rev-parse", "--verify", "-q", "refs/heads/main"); err != nil {
		t.Error("main was deleted")
	}
	if f.git(f.local, "branch", "--list", "fix-login") == "" {
		t.Error("fix-login was deleted")
	}
}
