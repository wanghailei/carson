package carson

import (
	"os"
	"path/filepath"
	"testing"
)

func (f *fixture) readRecord(dir string) Record {
	f.t.Helper()
	record, found, err := readOwner(f.git(dir, "rev-parse", "--absolute-git-dir"))
	if err != nil || !found {
		f.t.Fatalf("no owner record in %s: %v", dir, err)
	}
	return record
}

func (f *fixture) exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (f *fixture) taskFolder(task string) string {
	return filepath.Join(f.root, ".worktrees", "local", task)
}

var claudeRunning = stranger{4121: "Wed Sep 30 09:00:00 2026", 700: "Wed Sep 30 08:00:00 2026", 800: "Wed Sep 30 08:30:00 2026"}

func TestStartMakesTheTaskWorktreeAndItsOwnerRecord(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	dir := f.taskFolder("fix-login")
	expectLine(t, out, "Started fix-login from main at "+f.git(f.local, "rev-parse", "--short", "main")+" in "+dir+", owned by Claude session 9cb74d03 on test-mac.")
	if branch := f.git(dir, "symbolic-ref", "--short", "HEAD"); branch != "fix-login" {
		t.Errorf("the worktree is on %q", branch)
	}
	record := f.readRecord(dir)
	if record.Task != "fix-login" || record.Harness != "claude" || record.Session != "9cb74d03-a065-48ca" || record.PID != 4121 ||
		record.Started != "Wed Sep 30 09:00:00 2026" || record.Machine != "test-mac" || record.MachineID != "test-id" {
		t.Errorf("owner record: %+v", record)
	}
}

func TestStartThenStatusShowsTheTaskLive(t *testing.T) {
	f := newFixture(t)
	f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	out, _ := f.runIn(inClaude, f.local, claudeRunning, "status")
	expectLine(t, out, "Claude session 9cb74d03 on test-mac, live:")
	expectLine(t, out, "fix-login at "+f.taskFolder("fix-login")+": merged and clean.")
}

func TestStartBringsLocalMainForwardToGitHubs(t *testing.T) {
	f := newFixture(t)
	f.otherMachine()
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Local main was 1 commit behind GitHub's and is brought forward to it.")
	if local, remote := f.git(f.local, "rev-parse", "main"), f.git(f.github, "rev-parse", "main"); local != remote {
		t.Errorf("local main %s, GitHub's %s", local, remote)
	}
	if f.git(f.taskFolder("fix-login"), "rev-parse", "HEAD") != f.git(f.github, "rev-parse", "main") {
		t.Error("the task did not start from the latest main")
	}
}

func TestStartPushesMergedWorkGitHubLacks(t *testing.T) {
	f := newFixture(t)
	f.commit(f.local, "merged.txt")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Pushed 1 commit of local main that GitHub lacked.")
	if local, remote := f.git(f.local, "rev-parse", "main"), f.git(f.github, "rev-parse", "main"); local != remote {
		t.Errorf("local main %s, GitHub's %s", local, remote)
	}
}

func TestStartWhenMainsDivergedSaysTheMergeWillJoinThem(t *testing.T) {
	f := newFixture(t)
	f.commit(f.local, "here.txt")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git")) // the earlier push failed and still fails
	f.otherMachine()
	f.otherMachine()
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Local main and GitHub's have diverged: 1 commit here, 2 there. Merging this task will bring GitHub's commits in.")
}

func TestStartRefusesWhenGitHubCannotBeReached(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "set-url", "github", filepath.Join(f.root, "no-such-repository.git"))
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not started: GitHub could not be reached (")
	if f.exists(f.taskFolder("fix-login")) || f.git(f.local, "branch", "--list", "fix-login") != "" {
		t.Error("something was made although GitHub could not be reached")
	}
}

func TestStartRefusesANameThatIsNotLowercaseWordsJoinedByHyphens(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "Fix_Login")
	expectCode(t, code, 2)
	expectLine(t, out, `Not started: "Fix_Login" is not a task name: use lowercase words joined by hyphens, like fix-login.`)
}

func TestStartWithoutANameShowsHow(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: name the task, as in carson start fix-login.")
}

func TestStartRefusesANameALiveSessionHolds(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", "fix-login")
	out, code := f.runIn(inClaude, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: fix-login is taken by Claude session 4e7a91d2 on test-mac, which is live.")
}

func TestStartRefusesALeftoverBranchWhoseWorkIsOnMain(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "fix-login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: branch fix-login already exists, and its work is on main. Remove it with: carson remove fix-login")
}

func TestStartRefusesABranchThatHoldsWork(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.commit(dir, "work.txt")
	f.git(f.local, "worktree", "remove", dir)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: branch fix-login already exists, with 1 commit not on main. Taking it up again (carson start fix-login --existing) is not built yet.")
}

func TestStartRefusesWhenMainTreeIsOffMainAndGitHubIsAhead(t *testing.T) {
	f := newFixture(t)
	f.otherMachine()
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: GitHub's main is 1 commit ahead, and the main working tree is on elsewhere, not main, so local main cannot be brought forward there. Nothing was changed.")
	if f.exists(f.taskFolder("fix-login")) {
		t.Error("a worktree was made")
	}
}

func TestStartUnderPiFindsThePiProcess(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"PI_SESSION_ID": "01a0f100-a845"}, f.local, claudeRunning, "start", "fix-login")
	record := f.readRecord(f.taskFolder("fix-login"))
	if record.Harness != "pi" || record.Session != "01a0f100-a845" || record.PID != 700 || record.Started != "Wed Sep 30 08:00:00 2026" {
		t.Errorf("owner record under Pi: %+v", record)
	}
}

func TestStartInATerminalRecordsItsShell(t *testing.T) {
	f := newFixture(t)
	out, _ := f.runIn(environment{}, f.local, claudeRunning, "start", "fix-login")
	record := f.readRecord(f.taskFolder("fix-login"))
	if record.Harness != "terminal" || record.PID != 800 || record.Started != "Wed Sep 30 08:30:00 2026" {
		t.Errorf("owner record in a terminal: %+v", record)
	}
	expectLine(t, out, "Started fix-login from main at ")
}

func TestStartExistingIsNotBuiltYet(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login", "--existing")
	expectCode(t, code, 1)
	expectLine(t, out, "carson start --existing: not built yet. Nothing was changed.")
}
