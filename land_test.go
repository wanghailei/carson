package main

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

func (f *fixture) land(dir string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, dir, claudeRunning, "land", filepath.Base(dir))
}

func (f *fixture) short(dir, revision string) string {
	return f.git(dir, "rev-parse", "--short", revision)
}

func TestLandFastForwardsMainAndPushes(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.commit(dir, "login_test.rb")
	tip := f.git(dir, "rev-parse", "HEAD")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+short+" (2 commits) and pushed; GitHub's main is "+short+". No checks declared (no bin/check). Remove it with: carson remove fix-login (from outside its worktree).")
	if f.git(f.local, "rev-parse", "main") != tip || f.git(f.github, "rev-parse", "main") != tip {
		t.Error("main, here or on GitHub, is not the task's tip")
	}
	if record := f.readRecord(dir); record.Landed != tip {
		t.Errorf("the owner record does not name the merge: %+v", record)
	}
}

func TestLandRebasesOntoANewerMainFirst(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.otherMachine()
	out, code := f.land(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+short+" (1 commit, rebased onto main first) and pushed; GitHub's main is "+short+".")
	if f.git(f.github, "rev-parse", "main") != f.git(dir, "rev-parse", "HEAD") {
		t.Error("GitHub's main is not the rebased task")
	}
}

func TestLandRefusesUncommittedFiles(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.write(dir, "notes.txt", "unsaved\n")
	f.write(dir, "login.rb", "changed\n")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: 2 files are uncommitted in fix-login's worktree — login.rb, notes.txt. Commit them there, then run carson land fix-login again.")
}

func TestLandRefusesATaskWithNothingMainLacks(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fix-login has no commits that main lacks: its tip, "+f.short(f.local, "fix-login")+", is on main and on GitHub; remove it with: carson remove fix-login")
}

func TestLandUndoesAConflictingRebase(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "the task's line\n")
	f.git(dir, "commit", "-q", "-am", "change first here")
	before := f.git(dir, "rev-parse", "HEAD")
	other := f.otherClone()
	f.write(other, "first.txt", "the other machine's line\n")
	f.git(other, "commit", "-q", "-am", "change first there")
	f.git(other, "push", "-q", "origin", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: rebasing onto main ("+f.short(f.local, "main")+") conflicts in first.txt. The rebase was undone; fix-login is as it was, at "+f.short(dir, "HEAD")+". Run git rebase main in fix-login's worktree, resolve, then run carson land fix-login again.")
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

func TestLandStopsWhenTheChecksFail(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "echo 2 tests failed; exit 1")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: bin/check failed (exit 1). Its output ends:")
	if !strings.Contains(out, "Fix what bin/check reports, commit, then run carson land fix-login again.") {
		t.Errorf("no way on after failed checks:\n%s", out)
	}
	expectLine(t, out, "2 tests failed")
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved although the checks failed")
	}
}

func TestLandSaysTheChecksPassed(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 0")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	if !strings.Contains(out, "Checks: bin/check passed.") {
		t.Errorf("the checks are not reported:\n%s", out)
	}
}

// configure writes carson's configuration, ~/.carson/config.json, in the test's home.
func (f *fixture) configure(content string) {
	f.t.Helper()
	os.MkdirAll(filepath.Join(f.root, ".carson"), 0o755)
	if err := os.WriteFile(filepath.Join(f.root, ".carson", "config.json"), []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// landCheck puts a land check, script, at ~/checks/<name> in the test's home, and lists it alone in carson's configuration; it returns
// the check as the configuration lists it.
func (f *fixture) landCheck(name, script string) string {
	f.t.Helper()
	listed := f.checkFile(name, script)
	f.configure(`{"land": {"checks": ["` + listed + `"]}}`)
	return listed
}

// checkFile puts script at ~/checks/<name> in the test's home, and returns it as carson's configuration would list it.
func (f *fixture) checkFile(name, script string) string {
	f.t.Helper()
	os.MkdirAll(filepath.Join(f.root, "checks"), 0o755)
	if err := os.WriteFile(filepath.Join(f.root, "checks", name), []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	return "~/checks/" + name
}

// calls is what the land checks wrote to ~/check-calls: the range each was given and the folder it ran in, a line each.
func (f *fixture) calls() string {
	f.t.Helper()
	content, _ := os.ReadFile(filepath.Join(f.root, "check-calls"))
	return string(content)
}

// oneChange stands in for a check of the master's rule that one change is one commit: it refuses a commit in its range whose subject
// joins two changes with " and ", and notes the range and folder it ran with in ~/check-calls.
const oneChange = `subjects=$(git log --format=%s "$1") || exit 2
echo "$1 $(pwd -P)" >> "$HOME/check-calls"
bundled=$(echo "$subjects" | grep ' and ')
if [ -n "$bundled" ]; then echo "one commit holds two changes: $bundled"; exit 1; fi`

// What every refusal over the land checks' configuration ends with: carson lands nothing it cannot check, and a person settles it.
const unsettledCheck = ", and carson lands nothing it cannot check. Nothing was changed; a person must settle it; leave it until then, and run carson land fix-login again once it is settled."

func TestLandRefusesATaskWhoseCommitsALandCheckFails(t *testing.T) {
	f := newFixture(t)
	listed := f.landCheck("one-change", oneChange)
	dir := f.startTask("fix-login")
	f.write(dir, "login.rb", "login\n")
	f.write(dir, "logout.rb", "logout\n")
	f.git(dir, "add", ".")
	f.git(dir, "commit", "-q", "-m", "Add login and logout")
	f.check(dir, "echo bin/check ran first; exit 1") // the land checks run before the repository's own
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: the land check "+listed+" main..fix-login, from ~/.carson/config.json, failed (exit 1). Its output ends:")
	expectLine(t, out, "one commit holds two changes: Add login and logout")
	if !strings.Contains(out, "Fix what "+listed+" reports in fix-login's commits, then run carson land fix-login again.") {
		t.Errorf("no way on after a failed land check:\n%s", out)
	}
	if f.git(f.local, "rev-parse", "main") != main || f.git(f.github, "rev-parse", "main") != main {
		t.Error("main moved, here or on GitHub, although a land check failed")
	}
}

func TestLandRunsTheLandChecksOnTheTasksOwnCommitsInItsWorktree(t *testing.T) {
	f := newFixture(t)
	listed := f.landCheck("one-change", oneChange)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.check(dir, "exit 0")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+short+" (2 commits) and pushed; GitHub's main is "+short+". Checks: "+listed+" and bin/check passed.")
	if calls := f.calls(); calls != "main..fix-login "+dir+"\n" {
		t.Errorf("the land check was run with %q, not on main..fix-login in the task's worktree", calls)
	}
}

// The first task of a repository with no commit has every commit it holds to check: the land checks are given the task alone.
func TestLandOfTheFirstTaskGivesTheLandChecksTheWholeTask(t *testing.T) {
	f := newEmptyFixture(t)
	listed := f.landCheck("one-change", oneChange)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(dir, "HEAD")+" (1 commit) and pushed; GitHub's main is "+f.short(dir, "HEAD")+". Checks: "+listed+" passed; the repository declares none of its own (no bin/check).")
	if calls := f.calls(); calls != "fix-login "+dir+"\n" {
		t.Errorf("the land check was run with %q, not on fix-login alone", calls)
	}
}

// A landing whose range against main is empty — the task landed on local main, and only its push failed — is pushed by the next run
// without any land check asked about a range with nothing in it.
func TestLandOfATaskAlreadyOnMainIsPushedWithTheLandChecksConfigured(t *testing.T) {
	f := newFixture(t)
	f.landCheck("not-empty", `[ "$(git rev-list --count "$1")" -gt 0 ] || { echo "nothing in $1 to check"; exit 1; }`)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	if _, code := f.land(dir); code != 1 {
		t.Fatal("the first landing's push did not fail")
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "fix-login had already landed on local main at "+f.short(dir, "HEAD")+"; pushed it now.")
	if f.git(f.github, "rev-parse", "main") != f.git(dir, "rev-parse", "HEAD") {
		t.Error("GitHub's main is not the task's tip")
	}
}

func TestLandRefusesWhenALandCheckChangesTheTask(t *testing.T) {
	f := newFixture(t)
	listed := f.landCheck("untidy", "echo left > left.txt")
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: the land check "+listed+" main..fix-login, from ~/.carson/config.json, changed the task: it left 1 change in the worktree; the landing stops, since the checks must leave the task as they found it.")
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved")
	}
}

// expectNothingChanged fails unless the task and local main are where they were: a land check that cannot be run refuses the landing
// before anything changes, even when GitHub's main has moved on and a landing would bring both up to it.
func (f *fixture) expectNothingChanged(dir, task, main string) {
	f.t.Helper()
	if f.git(dir, "rev-parse", "HEAD") != task || f.git(f.local, "rev-parse", "main") != main {
		f.t.Error("the task or main changed, though the landing was refused")
	}
}

func TestLandRunsEveryLandCheckInTurnBeforeBinCheck(t *testing.T) {
	f := newFixture(t)
	first := f.checkFile("first", `echo first >> "$HOME/check-calls"`)
	second := f.checkFile("second", `echo second >> "$HOME/check-calls"`)
	f.configure(`{"land": {"checks": ["` + first + `", "` + second + `"]}}`)
	dir := f.startTask("fix-login")
	f.check(dir, `echo bin/check >> "$HOME/check-calls"`)
	out, code := f.land(dir)
	expectCode(t, code, 0)
	if !strings.Contains(out, "Checks: "+first+", "+second+" and bin/check passed.") {
		t.Errorf("the checks that passed are not all said:\n%s", out)
	}
	if calls := f.calls(); calls != "first\nsecond\nbin/check\n" {
		t.Errorf("the checks ran as %q, not each land check in turn and then bin/check", calls)
	}
}

func TestLandRefusesWhenALandCheckIsMissing(t *testing.T) {
	f := newFixture(t)
	present := f.checkFile("present", "exit 0")
	f.configure(`{"land": {"checks": ["` + present + `", "~/checks/one-change"]}}`)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.otherMachine()
	task, main := f.git(dir, "rev-parse", "HEAD"), f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: the land check ~/checks/one-change, listed in ~/.carson/config.json, does not exist"+unsettledCheck)
	f.expectNothingChanged(dir, task, main)
}

// Not executable is what carson's own user cannot run: no one may (0644), or others may but not its owner (0641).
func TestLandRefusesWhenALandCheckIsNotExecutable(t *testing.T) {
	f := newFixture(t)
	listed := f.landCheck("one-change", "exit 0")
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.otherMachine()
	task, main := f.git(dir, "rev-parse", "HEAD"), f.git(f.local, "rev-parse", "main")
	for _, mode := range []os.FileMode{0o644, 0o641} {
		os.Chmod(filepath.Join(f.root, "checks", "one-change"), mode)
		out, code := f.land(dir)
		expectCode(t, code, 2)
		expectLine(t, out, "Not landed: the land check "+listed+", listed in ~/.carson/config.json, is not an executable file"+unsettledCheck)
		f.expectNothingChanged(dir, task, main)
	}
}

// A land check is named by its full path, since the folders a bare name is looked for in differ from shell to shell.
func TestLandRefusesALandCheckNotGivenByItsFullPath(t *testing.T) {
	f := newFixture(t)
	f.configure(`{"land": {"checks": ["check-commits"]}}`)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, `Not landed: the land check "check-commits", listed in ~/.carson/config.json, is not a full path starting / or ~/`+unsettledCheck)
}

func TestLandRefusesAConfigurationItCannotRead(t *testing.T) {
	f := newFixture(t)
	f.configure(`{"land": {"checks": "~/checks/one-change"}}`)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.otherMachine()
	task, main := f.git(dir, "rev-parse", "HEAD"), f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: ~/.carson/config.json is not JSON whose land.checks is a list of commands (")
	if !strings.Contains(out, "so which land checks apply cannot be told"+unsettledCheck) {
		t.Errorf("the refusal does not say why or what next:\n%s", out)
	}
	f.expectNothingChanged(dir, task, main)
}

// HOME names no folder when it is empty, or names one that is not there: either way the configuration, and the land checks it may
// list, cannot be found.
func TestLandRefusesWhenHOMEDoesNotNameAFolder(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	task, main := f.git(dir, "rev-parse", "HEAD"), f.git(f.local, "rev-parse", "main")
	for _, home := range []string{"", filepath.Join(f.root, "no-such-home")} {
		noHome := environment{"HOME": home}
		for name, value := range inClaude {
			noHome[name] = value
		}
		out, code := f.runIn(noHome, dir, claudeRunning, "land", "fix-login")
		expectCode(t, code, 1)
		expectLine(t, out, "Not landed: HOME does not name a folder, so carson's configuration, ~/.carson/config.json, cannot be read, and carson lands nothing it cannot check. Nothing was changed; set HOME to your home folder, then run carson land fix-login again.")
		f.expectNothingChanged(dir, task, main)
	}
}

// A configuration that lists no land checks — Carson 4's, as a machine may still keep it — leaves carson land as it was.
func TestLandWithAConfigurationListingNoLandChecksIsAsBefore(t *testing.T) {
	f := newFixture(t)
	f.configure(`{"govern": {"repos": ["/Users/someone/Dev/notes"]}, "git": {"remote": "github"}}`)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+short+" (1 commit) and pushed; GitHub's main is "+short+". No checks declared (no bin/check). Remove it with: carson remove fix-login (from outside its worktree).")
}

func TestLandWhosePushFailsSaysSoAndIsPushedByTheNextMerge(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	out, code := f.land(dir)
	expectCode(t, code, 1)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on local main at "+short+". Not on GitHub (")
	if !strings.Contains(out, "Run carson land fix-login again to push.") {
		t.Errorf("the way to push is not named:\n%s", out)
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	out, code = f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "fix-login had already landed on local main at "+short+"; pushed it now. GitHub's main is "+short+".")
}

func TestLandRefusesAnotherSessionsTask(t *testing.T) {
	f := newFixture(t)
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", "fix-login")
	dir := f.taskFolder("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.runIn(inClaude, dir, stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}, "land", "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fix-login belongs to Claude session 4e7a91d2-other, which is live. Only its owner lands it; leave it to that session.")
}

// carson land runs from anywhere in the repository: the main working tree as well as the task's worktree.
func TestLandFromTheMainWorkingTree(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.runIn(inClaude, f.local, claudeRunning, "land", "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(f.local, "main")+" (1 commit) and pushed")
}

func TestLandRefusesAnUnknownTask(t *testing.T) {
	f := newFixture(t)
	out, code := f.runIn(inClaude, f.local, claudeRunning, "land", "no-such-task")
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: no task is named no-such-task; carson status lists them.")
}

func TestLandRefusesATaskMadeOutsideCarson(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fix-login was made outside carson, so whose it is cannot be told; a person must settle it; leave it until then.")
}

// From wanghailei/carson#543: after the repository's folder moved, land run in the task's worktree said the folder was not inside a git
// repository, with no cause and no way on.
func TestLandNamesAdoptAfterTheRepositoryMoved(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	old := f.moveRepository()
	main := f.git(f.local, "rev-parse", "main")
	// Run in the worktree, in a folder inside it, and in the repository.
	os.MkdirAll(filepath.Join(dir, "sub"), 0o755)
	for _, here := range []string{dir, filepath.Join(dir, "sub"), f.local} {
		out, code := f.runIn(inClaude, here, claudeRunning, "land", "fix-login")
		expectCode(t, code, 1)
		expectLine(t, out, "Not landed: "+linkedToGone(dir, old))
	}
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved")
	}
}

func TestLandRefusesWhenGitHubCannotBeReached(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "remote", "set-url", "github", filepath.Join(f.root, "no-such-repository.git"))
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: GitHub could not be reached (")
	if !strings.Contains(out, "Nothing was changed; fix-login still holds its 1 commit.") || f.git(f.local, "rev-parse", "main") != main {
		t.Errorf("not refused before any change:\n%s", out)
	}
}

func TestLandRefusesWhileARebaseIsInProgress(t *testing.T) {
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
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: a rebase is in progress in fix-login's worktree. Finish it with git rebase --continue, or give it up with git rebase --abort, then run carson land fix-login again.")
}

func TestLandRefusesWhenTheMainTreeIsOffMain(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: the main working tree is on elsewhere, not main, so main cannot be fast-forwarded there. Nothing was changed; fix-login still holds its 1 commit.")
}

func TestLandRefusesToOverwriteWhatTheMainTreeHolds(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "notes.md")
	f.write(f.local, "notes.md", "the master's own notes\n")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fast-forwarding main would overwrite what the main working tree holds in notes.md (untracked, changed ")
	if content, _ := os.ReadFile(filepath.Join(f.local, "notes.md")); string(content) != "the master's own notes\n" || f.git(f.local, "rev-parse", "main") != main {
		t.Error("the main working tree's file or main was changed")
	}
}

func TestLandJoinsDivergedMains(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.commit(f.local, "merged-here.txt") // merged here, not yet pushed
	f.otherMachine()
	theirs := f.git(f.github, "rev-parse", "main")
	out, code := f.land(dir)
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

func TestLandRefusesWhileALiveMergeHoldsTheLockAndTakesOverAStaleOne(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), landingLockFile)
	held := Record{Task: "other-task", Harness: "claude", Session: "4e7a91d2-other", PID: 5000, Started: "Wed Sep 30 07:00:00 2026"}
	if err := writeRecordFile(lock, held); err != nil {
		t.Fatal(err)
	}
	running := stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}
	out, code := f.runIn(inClaude, dir, running, "land", "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: another landing is running in this repository — other-task, by Claude session 4e7a91d2-other. Run carson land fix-login again when it has finished. Nothing was changed.")
	out, code = f.land(dir) // process 5000 has ended
	expectCode(t, code, 0)
	expectLine(t, out, "The landing lock left by an ended carson (other-task, by Claude session 4e7a91d2-other) is taken over.")
	if f.exists(lock) {
		t.Error("the merge lock was not released")
	}
}

func TestLandWithoutARemoteMergesLocally(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(dir, "HEAD")+" (1 commit). No GitHub remote: main is on this machine only.")
}

// From carson#529 and #528: in a repository made empty on GitHub, the first landing makes main and pushes it.
func TestLandOfTheFirstTaskMakesMainAndPushesIt(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.commit(dir, "login_test.rb")
	tip := f.git(dir, "rev-parse", "HEAD")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	short := f.short(dir, "HEAD")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+short+" (2 commits) and pushed; GitHub's main is "+short+".")
	if f.git(f.local, "rev-parse", "main") != tip || f.git(f.github, "rev-parse", "main") != tip {
		t.Error("main, here or on GitHub, is not the task's tip")
	}
	if held := f.git(f.local, "status", "--porcelain"); held != "" || !f.exists(filepath.Join(f.local, "login.rb")) {
		t.Errorf("the main working tree does not hold main: %q", held)
	}
}

func TestLandOfTheFirstTaskWithoutARemoteMakesMain(t *testing.T) {
	f := newEmptyFixture(t)
	f.git(f.local, "remote", "remove", "github")
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(dir, "HEAD")+" (1 commit). No GitHub remote: main is on this machine only.")
}

// A folder may hold files before its first commit; making main must not overwrite them.
func TestLandOfTheFirstTaskRefusesToOverwriteAFileInTheMainTree(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.write(f.local, "login.rb", "someone's draft\n")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fast-forwarding main would overwrite what the main working tree holds in login.rb (untracked")
	if f.git(f.local, "for-each-ref", "refs/heads/main") != "" {
		t.Error("main was made")
	}
}

func TestLandOfAFirstTaskWithNoCommitSaysToCommit(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fix-login has no commit yet. Commit its work in its worktree, then run carson land fix-login again.")
}

// The first task started empty, and GitHub was given a main meanwhile: the task lands on top of that main, which it then carries.
func TestLandOfTheFirstTaskAfterGitHubWasGivenAMain(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.pushFirstCommit()
	github := f.git(f.github, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Local main was 1 commit behind GitHub's and is brought forward to it.")
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(dir, "HEAD")+" (1 commit, rebased onto main first) and pushed")
	f.git(f.local, "merge-base", "--is-ancestor", github, "main") // fails the test when main does not carry GitHub's main
}

// From the review of 2bfec0f: once GitHub's first main was fetched, a landing refused for a file in the way could not be run again.
func TestLandOfTheFirstTaskRunsAgainOnceAFileIsOutOfTheWayOfGitHubsMain(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.pushFirstCommit()
	github := f.git(f.github, "rev-parse", "main")
	f.write(f.local, "readme.md", "someone's draft\n")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: bringing local main forward would overwrite what the main working tree holds in readme.md (untracked")
	if err := os.Rename(filepath.Join(f.local, "readme.md"), filepath.Join(f.root, "readme.md")); err != nil {
		t.Fatal(err)
	}
	out, code = f.land(dir)
	expectCode(t, code, 0)
	expectLine(t, out, "Landed fix-login on main by fast-forward at "+f.short(dir, "HEAD"))
	tip := f.git(dir, "rev-parse", "HEAD")
	if f.git(f.local, "rev-parse", "main") != tip || f.git(f.github, "rev-parse", "main") != tip {
		t.Error("main, here or on GitHub, is not the task's tip")
	}
	f.git(f.local, "merge-base", "--is-ancestor", github, "main") // fails the test when main does not carry GitHub's first main
	if !f.exists(filepath.Join(f.local, "login.rb")) || !f.exists(filepath.Join(f.local, "readme.md")) {
		t.Error("the main working tree does not hold both GitHub's first commit and the task's work")
	}
}

// Cases from the review of cca4a81, each staged there against the slice before it was fixed.

func TestLandStopsWhenTheCheckMovesTheBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.check(dir, "git reset -q --hard main")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: bin/check changed the task: fix-login moved from ")
	if f.git(f.local, "rev-parse", "main") != main {
		t.Error("main moved")
	}
}

func TestLandStopsWhenTheCheckSwitchesBranch(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "git switch -q -c scratch && echo x > x.txt && git add x.txt && git commit -q -m scratch")
	main := f.git(f.local, "rev-parse", "main")
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: bin/check changed the task: the worktree is now on scratch, not fix-login")
	if f.git(f.local, "rev-parse", "main") != main || f.git(f.github, "rev-parse", "main") != main {
		t.Error("main moved, here or on GitHub")
	}
}

func TestLandRetryAfterAFailedPushJoinsAGitHubThatMovedOn(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	if _, code := f.land(dir); code != 1 {
		t.Fatal("the first merge's push did not fail")
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	f.otherMachine()
	theirs := f.git(f.github, "rev-parse", "main")
	out, code := f.land(dir)
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

func TestLandConflictJoiningGitHubSaysTheTaskWasRebased(t *testing.T) {
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
	out, code := f.land(dir)
	expectCode(t, code, 2)
	if !strings.Contains(out, "The merge was undone; fix-login is rebased onto main at "+f.short(dir, "HEAD")+" (it was at "+original+" before carson).") {
		t.Errorf("the rebase is not said:\n%s", out)
	}
}

func TestLandFailedCheckAfterARebaseSaysSo(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 1")
	original := f.short(dir, "HEAD")
	f.otherMachine()
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: bin/check failed (exit 1). It printed nothing.")
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

func TestLandWhosePushIsCutOffDoesNotClaimItFailed(t *testing.T) {
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
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Landed fix-login on local main at "+f.short(dir, "HEAD")+". Whether it reached GitHub is unknown (no answer within 2s). Run carson land fix-login again to push or confirm it.")
}

func TestLandKeepsATaskThatCarriesAJoinUnflattened(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "exit 1")
	f.commit(f.local, "merged-here.txt")
	f.otherMachine()
	if _, code := f.land(dir); code != 2 {
		t.Fatal("the failing check did not stop the first merge")
	}
	f.write(filepath.Join(dir, "bin"), "check", "#!/bin/sh\nexit 0\n")
	f.git(dir, "commit", "-q", "-am", "fix the check")
	f.commit(f.local, "merged-here-2.txt")
	out, code := f.land(dir)
	expectCode(t, code, 0)
	if n := f.git(f.github, "log", "main", "--format=%s"); strings.Count(n, "add other-") != 1 {
		t.Errorf("GitHub's main holds the other machine's commit more than once:\n%s\n%s", n, out)
	}
}

func TestLandInterruptedDuringTheCheckEndsInOneLineAndGivesBackTheLock(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.check(dir, "sleep 2")
	main := f.git(f.local, "rev-parse", "main")
	go func() {
		time.Sleep(700 * time.Millisecond)
		syscall.Kill(os.Getpid(), syscall.SIGINT)
	}()
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: interrupted during the checks.")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), landingLockFile)
	if f.exists(lock) || f.git(f.local, "rev-parse", "main") != main {
		t.Error("the lock is still held, or main moved")
	}
}

func TestLandRefusesToOverwriteAModifiedFileInTheMainTree(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "first.txt", "the task's\n")
	f.git(dir, "commit", "-q", "-am", "task changes first")
	f.write(f.local, "first.txt", "the master's edit\n")
	out, code := f.land(dir)
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fast-forwarding main would overwrite what the main working tree holds in first.txt (modified, changed ")
}

func TestLandRefusesALockWhoseHolderCannotBeChecked(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	lock := filepath.Join(f.git(f.local, "rev-parse", "--path-format=absolute", "--git-common-dir"), landingLockFile)
	writeRecordFile(lock, Record{Task: "other-task", Harness: "claude", Session: "4e7a91d2-other", PID: 5000})
	out, code := f.land(dir)
	expectCode(t, code, 1)
	expectLine(t, out, "Not landed: the landing lock is held by other-task's landing, by Claude session 4e7a91d2-other, whose state is unknown (the record has no start time for process 5000). Nothing was changed; run carson land fix-login again when that landing has finished, and if its session is gone, a person must settle it.")
}

// From the review of fdb5297: a task already on local main, and a re-run over a join already made.
func TestLandOfATaskAlreadyOnMainSaysItHoldsNothingOfItsOwn(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	flag := filepath.Join(f.root, "fail-checks")
	f.check(dir, "test ! -e "+flag)
	f.git(f.local, "config", "remote.github.pushurl", filepath.Join(f.root, "no-push.git"))
	if _, code := f.land(dir); code != 1 {
		t.Fatal("the first merge's push did not fail")
	}
	f.git(f.local, "config", "--unset", "remote.github.pushurl")
	f.otherMachine()
	os.WriteFile(flag, nil, 0o644)
	out, code := f.land(dir)
	expectCode(t, code, 2)
	if !strings.Contains(out, "fix-login holds nothing of its own that main lacks, with GitHub's main merged in") {
		t.Errorf("the task's state is not said truly:\n%s", out)
	}
}

func TestLandRerunOverAJoinAlreadyMadeCountsOnlyTheTasksOwnCommits(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	flag := filepath.Join(f.root, "fail-checks")
	f.check(dir, "test ! -e "+flag)
	f.commit(dir, "login.rb")
	f.commit(f.local, "merged-here.txt")
	f.otherMachine()
	os.WriteFile(flag, nil, 0o644)
	if _, code := f.land(dir); code != 2 {
		t.Fatal("the failing check did not stop the first merge")
	}
	os.Remove(flag)
	out, code := f.land(dir)
	expectCode(t, code, 0)
	if strings.Contains(out, "its commits are merged into fix-login first") {
		t.Errorf("a join that changed nothing is reported as made:\n%s", out)
	}
	if !strings.Contains(out, "fix-login already carries GitHub's main.") || !strings.Contains(out, "(2 commits, ") {
		t.Errorf("not said that the task carries GitHub's main, or its own commits miscounted:\n%s", out)
	}
}
