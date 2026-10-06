package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
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
	expectLine(t, out, "Started fix-login from local main at "+f.git(f.local, "rev-parse", "--short", "main")+" in "+dir+", owned by Claude session 9cb74d03-a065.")
	if branch := f.git(dir, "symbolic-ref", "--short", "HEAD"); branch != "fix-login" {
		t.Errorf("the worktree is on %q", branch)
	}
	record := f.readRecord(dir)
	if record.Task != "fix-login" || record.Harness != "claude" || record.Session != "9cb74d03-a065-48ca" || record.PID != 4121 ||
		record.Started != "Wed Sep 30 09:00:00 2026" {
		t.Errorf("owner record: %+v", record)
	}
}

func TestStartThenStatusShowsTheTaskLive(t *testing.T) {
	f := newFixture(t)
	f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	out, _ := f.runIn(inClaude, f.local, claudeRunning, "status")
	expectLine(t, out, "Claude session 9cb74d03-a065, live:")
	expectLine(t, out, "fix-login at "+f.taskFolder("fix-login")+": clean, nothing main lacks.")
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
	expectLine(t, out, "Pushed 1 commit of local main that GitHub lacked; GitHub's main is now "+f.git(f.local, "rev-parse", "--short", "main")+".")
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
	expectLine(t, out, "Local main and GitHub's have diverged: 1 commit here, 2 there. Landing this task will bring GitHub's commits in.")
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
	expectLine(t, out, "Not started: fix-login is taken by Claude session 4e7a91d2-other, which is live; its worktree is at "+f.taskFolder("fix-login")+". Choose another name.")
}

func TestStartSaysATaskIsAlreadyYours(t *testing.T) {
	f := newFixture(t)
	f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: fix-login is already yours, at "+f.taskFolder("fix-login")+"; work there.")
}

// The trial of 2026-09-30: a Pi started from inside a Claude session inherits Claude's variables, and was recorded as Claude.
func TestStartUnderPiInsideClaudeRecordsPi(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "4121", "PI_SESSION_ID": "01a0f100-a845"}, f.local, claudeRunning, "start", "fix-login")
	if record := f.readRecord(f.taskFolder("fix-login")); record.Harness != "pi" || record.PID != 700 {
		t.Errorf("owner record of Pi inside Claude: %+v", record)
	}
}

func TestStartUnderClaudeInsidePiRecordsClaude(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "800", "PI_SESSION_ID": "01a0f100-a845"}, f.local, claudeRunning, "start", "fix-login")
	if record := f.readRecord(f.taskFolder("fix-login")); record.Harness != "claude" || record.PID != 800 {
		t.Errorf("owner record of Claude inside Pi: %+v", record)
	}
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
	expectLine(t, out, "Not started: branch fix-login already exists, with 1 commit not on main. Adopt it with: carson adopt fix-login")
}

func TestStartRefusesWhenMainTreeIsOffMainAndGitHubIsAhead(t *testing.T) {
	f := newFixture(t)
	f.otherMachine()
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: GitHub's main is 1 commit ahead, and the main working tree is on elsewhere, not main, so local main cannot be brought forward there. GitHub's main was fetched; nothing else was changed.")
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
	expectLine(t, out, "Started fix-login from local main at ")
}

// Bringing local main forward never overwrites what the main working tree holds that main does not: modified, untracked or ignored.
func TestStartRefusesAFastForwardThatWouldOverwriteAnIgnoredFile(t *testing.T) {
	f := newFixture(t)
	f.write(f.local, ".gitignore", "build/\n")
	f.git(f.local, "add", ".gitignore")
	f.git(f.local, "commit", "-q", "-m", "ignore build")
	f.git(f.local, "push", "-q", "github", "main")
	os.Mkdir(filepath.Join(f.local, "build"), 0o755)
	f.write(filepath.Join(f.local, "build"), "out.txt", "my local output\n")
	other := f.otherClone()
	os.Mkdir(filepath.Join(other, "build"), 0o755)
	f.write(filepath.Join(other, "build"), "out.txt", "from the other machine\n")
	f.git(other, "add", "-f", "build/out.txt")
	f.git(other, "commit", "-q", "-m", "track build output")
	f.git(other, "push", "-q", "origin", "main")
	before := f.git(f.local, "rev-parse", "main")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: bringing local main forward would overwrite what the main working tree holds in build/out.txt (ignored, changed ")
	if !strings.Contains(out, "). carson did not touch them and cannot tell whose they are. GitHub's main was fetched; nothing else was changed.") {
		t.Errorf("the refusal does not say what was and was not changed:\n%s", out)
	}
	if content, _ := os.ReadFile(filepath.Join(f.local, "build", "out.txt")); string(content) != "my local output\n" {
		t.Errorf("the ignored file now holds %q", content)
	}
	if f.git(f.local, "rev-parse", "main") != before || f.exists(f.taskFolder("fix-login")) {
		t.Error("local main moved, or a worktree was made")
	}
}

func TestStartNamesModifiedAndUntrackedFilesInTheWay(t *testing.T) {
	f := newFixture(t)
	other := f.otherClone()
	f.write(other, "first.txt", "changed there\n")
	f.write(other, "new.txt", "new there\n")
	f.git(other, "add", "first.txt", "new.txt")
	f.git(other, "commit", "-q", "-m", "change and add")
	f.git(other, "push", "-q", "origin", "main")
	f.write(f.local, "first.txt", "changed here\n")
	f.write(f.local, "new.txt", "made here\n")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	for _, want := range []string{"first.txt (modified, changed ", "new.txt (untracked, changed "} {
		if !strings.Contains(out, want) {
			t.Errorf("%q not named in:\n%s", want, out)
		}
	}
}

// When git worktree add fails, carson looks at what is there rather than guessing.
func TestStartReportsAWorktreeMadeDespiteAFailingHook(t *testing.T) {
	f := newFixture(t)
	hook := filepath.Join(f.local, ".git", "hooks", "post-checkout")
	if err := os.WriteFile(hook, []byte("#!/bin/sh\necho hook refuses >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Started fix-login from local main at ")
	if !strings.Contains(out, "but git reported a failure after making it (hook refuses)") {
		t.Errorf("the hook's failure is not reported:\n%s", out)
	}
	if record := f.readRecord(f.taskFolder("fix-login")); record.Harness != "claude" {
		t.Errorf("the worktree carson made has no owner record: %+v", record)
	}
}

func TestAfterAFailedAddANameTakenMeanwhileIsNamed(t *testing.T) {
	f := newFixture(t)
	repo, err := openRepository(f.local)
	if err != nil {
		t.Fatal(err)
	}
	winner := f.worktree("fix-login")
	f.own(winner, Record{Task: "fix-login", Harness: "claude", Session: "4e7a91d2-other", PID: 5000, Started: "Wed Sep 30 07:00:00 2026"})
	var machine Machine
	machine.Env, machine.Processes = environment{}.get, stranger{5000: "Wed Sep 30 07:00:00 2026"}
	repo, _ = openRepository(f.local)
	err = repo.afterFailedAdd(machine, "fix-login", f.taskFolder("fix-login"), errors.New("fatal: a branch named 'fix-login' already exists"))
	if err == nil || !strings.Contains(err.Error(), "fix-login was taken meanwhile by Claude session 4e7a91d2-other, which is live; its worktree is at ") {
		t.Errorf("got %v", err)
	}
}

func TestStartRecordsAndSaysWhenTheHarnessProcessCannotBeObserved(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "99999"}, f.local, stranger{}, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Its process, 99999, could not be observed (not running), so status will show this task's owner as unknown.")
	status, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, status, "Claude session 9cb74d03-a065, unknown (the record has no start time for process 99999):")
}

func TestStartRefusesTheTrunkAsATaskName(t *testing.T) {
	f := newFixture(t)
	for _, name := range []string{"main", "master"} {
		out, code := f.runIn(inClaude, f.local, claudeRunning, "start", name)
		expectCode(t, code, 2)
		expectLine(t, out, "Not started: "+name+" is a trunk's name, not a task's.")
	}
}

func TestStartWithAHomeEndingInASlash(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"HOME": f.root + "/", "CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "4121"}, f.local, claudeRunning, "start", "fix-login")
	if !f.exists(f.taskFolder("fix-login")) {
		t.Errorf("the worktree is not at %s", f.taskFolder("fix-login"))
	}
}

func TestStartRefusesWithoutAHome(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(environment{"HOME": ""}, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not started: HOME is not set, so there is no ~/.worktrees to start the task in.")
}

func TestStartRefusesAFolderInTheWay(t *testing.T) {
	f := newFixture(t)
	os.MkdirAll(f.taskFolder("fix-login"), 0o755)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: "+f.taskFolder("fix-login")+" already exists, and is not a worktree of this task. Nothing was changed; move that folder out of the way, or choose another name.")
}

func TestStartRefusesANameHeldByAnEndedSession(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", "fix-login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: fix-login is held by Claude session 4e7a91d2-other, which has ended. Adopt it with: carson adopt fix-login")
}

func TestStartRefusesANameWhoseOwnerCannotBeTold(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.own(dir, Record{Task: "fix-login", Harness: "claude", Session: "4e7a91d2-other", PID: 5000})
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: fix-login is held by Claude session 4e7a91d2-other, whose state is unknown (the record has no start time for process 5000).")
}

func TestStartRefusesANameHeldByAWorktreeMadeOutsideCarson(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: fix-login is held by a worktree made outside carson, at "+dir+", whose owner cannot be told. Choose another name.")
}

func TestStartPushesMainToAGitHubThatHasNone(t *testing.T) {
	f := newFixture(t)
	empty := filepath.Join(f.root, "empty.git")
	f.git(f.root, "init", "-q", "--bare", "-b", "main", empty)
	f.git(f.local, "remote", "set-url", "github", empty)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "GitHub had no main; local main is pushed there, and GitHub's main is now "+f.git(f.local, "rev-parse", "--short", "main")+".")
}

func TestStartWithoutARemoteStartsFromLocalMain(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "No GitHub remote: the task starts from local main.")
}

// From carson#529: a repository made empty on GitHub and cloned had no main to start from, so its first commit had to bypass carson.
func TestStartMakesTheFirstTaskOfAnEmptyRepository(t *testing.T) {
	f := newEmptyFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	dir := f.taskFolder("fix-login")
	expectLine(t, out, "Started fix-login in "+dir+", owned by Claude session 9cb74d03-a065. The repository has no commit yet, so the task starts empty; landing it makes main and pushes it to GitHub.")
	if branch := f.git(dir, "symbolic-ref", "--short", "HEAD"); branch != "fix-login" {
		t.Errorf("the worktree is on %q", branch)
	}
	if record := f.readRecord(dir); record.Task != "fix-login" {
		t.Errorf("owner record: %+v", record)
	}
	if answer := f.git(f.local, "ls-remote", "github"); answer != "" {
		t.Errorf("GitHub was changed: %s", answer)
	}
}

func TestStartMakesTheFirstTaskOfAnEmptyRepositoryWithoutARemote(t *testing.T) {
	f := newEmptyFixture(t)
	f.git(f.local, "remote", "remove", "github")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Started fix-login in "+f.taskFolder("fix-login")+", owned by Claude session 9cb74d03-a065. The repository has no commit yet, so the task starts empty; landing it makes main.")
	expectNoLine(t, out, "No GitHub remote: the task starts from local main.")
}

// pushFirstCommit gives GitHub a main from the other machine, after this one cloned it empty.
func (f *fixture) pushFirstCommit() string {
	f.t.Helper()
	other := f.otherClone()
	f.commit(other, "readme.md")
	f.git(other, "push", "-q", "origin", "main")
	return f.git(other, "rev-parse", "--short", "main")
}

// Cloned empty, while GitHub has since been given a main: the task starts from that main, not as an unrelated history beside it.
func TestStartBringsInTheMainGitHubWasGivenSinceTheEmptyClone(t *testing.T) {
	f := newEmptyFixture(t)
	github := f.pushFirstCommit()
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: no commit yet here; GitHub's main is at "+github+", which the next carson start or carson land brings here.")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Local main was 1 commit behind GitHub's and is brought forward to it.")
	expectLine(t, out, "Started fix-login from local main at "+github+" in "+f.taskFolder("fix-login"))
	if held := f.git(f.local, "status", "--porcelain"); held != "" || !f.exists(filepath.Join(f.local, "readme.md")) {
		t.Errorf("the main working tree does not hold GitHub's main: %q", held)
	}
}

// Without main, and with the main working tree on another branch, the repository's trunk has another name.
func TestStartInARepositoryWhoseTrunkIsNotMainSaysHowToRenameIt(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	f.git(f.local, "branch", "-m", "main", "master")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not started: this repository has no main, which carson starts every task from; the main working tree is on master. If master is its trunk, rename it with: git branch -m master main. Nothing was changed.")
}

func TestStartWithoutMainOnADetachedHeadSaysHowToMakeMain(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	f.git(f.local, "switch", "-q", "--detach")
	f.git(f.local, "branch", "-D", "main")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not started: this repository has no main, which carson starts every task from; the main working tree is on a detached HEAD. If its commit is where main belongs, make main there with: git switch -c main. Nothing was changed.")
}

// Two sessions starting one name aim at one folder; the winner's record must survive the loser's failed add.
func TestAfterAFailedAddTheWinnersWorktreeInTheSameFolderIsNotTakenOver(t *testing.T) {
	f := newFixture(t)
	folder := f.taskFolder("fix-login")
	f.git(f.local, "worktree", "add", "-q", "-b", "fix-login", folder, "main")
	f.own(folder, Record{Task: "fix-login", Harness: "claude", Session: "bbbb2222-winner", PID: 5000, Started: "Wed Sep 30 07:00:00 2026"})
	repo, _ := openRepository(f.local)
	var machine Machine
	machine.Env, machine.Processes = environment{}.get, stranger{5000: "Wed Sep 30 07:00:00 2026"}
	err := repo.afterFailedAdd(machine, "fix-login", folder, errors.New("cannot lock ref 'refs/heads/fix-login'"))
	if err == nil || !strings.Contains(err.Error(), "fix-login was taken meanwhile by Claude session bbbb2222-winner, which is live; its worktree is at ") {
		t.Errorf("got %v", err)
	}
	if record := f.readRecord(folder); record.Session != "bbbb2222-winner" {
		t.Errorf("the winner's record was replaced: %+v", record)
	}
}

// An owner record is created only where none is: of two creators, one wins and the other learns it.
func TestAnOwnerRecordIsCreatedOnlyOnce(t *testing.T) {
	admin := t.TempDir()
	if err := createOwner(admin, Record{Task: "fix-login", Session: "first"}); err != nil {
		t.Fatal(err)
	}
	if err := createOwner(admin, Record{Task: "fix-login", Session: "second"}); !errors.Is(err, errOwned) {
		t.Errorf("second creation: %v, wanted errOwned", err)
	}
	record, _, _ := readOwner(admin)
	if record.Session != "first" {
		t.Errorf("the record is %+v", record)
	}
	if entries, _ := os.ReadDir(admin); len(entries) != 1 {
		t.Errorf("left behind in the administrative folder: %v", entries)
	}
}

// A push that went through but could not be checked afterwards is said as such, not as a failed push.
func TestAPushThatCouldNotBeCheckedIsNotCalledFailed(t *testing.T) {
	f := newFixture(t)
	f.commit(f.local, "merged.txt")
	f.git(f.local, "config", "remote.github.pushurl", f.github)
	f.git(f.local, "remote", "set-url", "github", filepath.Join(f.root, "no-such-repository.git"))
	f.git(f.local, "config", "remote.github.pushurl", f.github)
	repo, _ := openRepository(f.local)
	_, err := repo.bringUpToDate("refs/remotes/github/main", 1, 0, "GitHub's main was fetched; nothing else was changed.", "fix-login")
	if err == nil || !strings.Contains(err.Error(), "local main was pushed, but GitHub's main could not be checked afterwards (") || !strings.Contains(err.Error(), "GitHub's main had been fetched first") {
		t.Errorf("got %v", err)
	}
	if f.git(f.github, "rev-parse", "main") != f.git(f.local, "rev-parse", "main") {
		t.Error("the push did not go through")
	}
}

func TestStartNamesAStagedRenamesOriginInTheWay(t *testing.T) {
	f := newFixture(t)
	other := f.otherClone()
	f.write(other, "first.txt", "changed there\n")
	f.git(other, "commit", "-q", "-am", "change first")
	f.git(other, "push", "-q", "origin", "main")
	f.git(f.local, "mv", "first.txt", "moved.txt")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	if !strings.Contains(out, "first.txt (modified") {
		t.Errorf("the renamed file's origin is not named:\n%s", out)
	}
}

func TestStartNamesAnUntrackedFolderWhereAFileArrives(t *testing.T) {
	f := newFixture(t)
	other := f.otherClone()
	f.write(other, "docs", "a file named docs\n")
	f.git(other, "add", "docs")
	f.git(other, "commit", "-q", "-m", "add docs")
	f.git(other, "push", "-q", "origin", "main")
	os.Mkdir(filepath.Join(f.local, "docs"), 0o755)
	f.write(filepath.Join(f.local, "docs"), "a.md", "mine\n")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	if !strings.Contains(out, "docs (untracked") {
		t.Errorf("the untracked folder is not named:\n%s", out)
	}
}

// git refused the branch because it already existed: git made nothing for this session, whatever the folder holds.
func TestAfterABranchConflictTheWorktreeInTheFolderIsNotClaimed(t *testing.T) {
	f := newFixture(t)
	folder := f.taskFolder("fix-login")
	f.git(f.local, "worktree", "add", "-q", "-b", "fix-login", folder, "main")
	repo, _ := openRepository(f.local)
	err := repo.afterFailedAdd(Machine{Env: environment{}.get, Processes: stranger{}}, "fix-login", folder, errors.New("fatal: a branch named 'fix-login' already exists"))
	if err == nil || !strings.Contains(err.Error(), "fix-login was taken meanwhile by a session that has not recorded itself yet, at "+folder+".") {
		t.Errorf("got %v", err)
	}
}

// From the second trial: a task started under a name whose earlier work was abandoned gave no word of it.
func TestStartMentionsEarlierAbandonedWork(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "abandoned/fix-login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Earlier work on fix-login, declared abandoned, is kept as branch abandoned/fix-login; this task starts afresh from main.")
}

// From the second trial: "abandoned" collided with the abandoned/<task> branches in git's raw words, and a remote's name was taken.
func TestStartRefusesNamesGitCannotTellApart(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "abandoned")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: abandoned is where carson keeps the branches of abandoned tasks, not a task's name.")
	out, code = f.runIn(inClaude, f.local, claudeRunning, "start", "github")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: github is a remote's name, not a task's: git could not tell the two apart.")
}

// From the re-review of 2f003da: a hand-made branch Fix-Login made carson start fix-login say fix-login existed.
func TestStartRefusesANameGitCannotTellFromABranchByCase(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "Fix-Login")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "start", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not started: branch Fix-Login exists, and differs from fix-login only in case, which git cannot always tell apart; choose another name.")
}
