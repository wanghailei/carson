package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func (f *fixture) adopt(processes Processes, args ...string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, f.local, processes, append([]string{"adopt"}, args...)...)
}

// otherSession starts a task as another Claude session, whose process is 5000.
func (f *fixture) otherSession(task string) string {
	f.t.Helper()
	f.runIn(environment{"CLAUDE_CODE_SESSION_ID": "4e7a91d2-other", "CLAUDE_PID": "5000"}, f.local, stranger{5000: "Wed Sep 30 07:00:00 2026"}, "start", task)
	return f.taskFolder(task)
}

func TestAdoptAnEndedAgentsTask(t *testing.T) {
	f := newFixture(t)
	dir := f.otherSession("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.adopt(claudeRunning, "fix-login") // process 5000 has ended
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login from Claude session 4e7a91d2-other, which has ended: its worktree at "+dir+" is yours now, as it was left.")
	record := f.readRecord(dir)
	if record.Session != "9cb74d03-a065-48ca" || len(record.Previous) != 1 || record.Previous[0].Session != "4e7a91d2-other" {
		t.Errorf("the owner record after adoption: %+v", record)
	}
	if out, code := f.land(dir); code != 0 {
		t.Errorf("the adopted task does not land:\n%s", out)
	}
}

func TestAdoptRefusesALiveOwnersTask(t *testing.T) {
	f := newFixture(t)
	f.otherSession("fix-login")
	out, code := f.adopt(stranger{5000: "Wed Sep 30 07:00:00 2026", 4121: "Wed Sep 30 09:00:00 2026"}, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: fix-login belongs to Claude session 4e7a91d2-other, which is live; only an ended agent's task is adopted.")
}

func TestAdoptRefusesAnOwnerWhoseStateIsUnknown(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	record := claude("fix-login", 5000)
	record.Started = ""
	f.own(dir, record)
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: fix-login belongs to Claude session 4e7a91d2-aaaa, whose state is unknown (the record has no start time for process 5000); only an agent seen to have ended gives up its task.")
}

func TestAdoptSaysATaskIsAlreadyYours(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: fix-login is already yours, at "+dir+"; work there.")
}

func TestAdoptRefusesAWorktreeMadeOutsideCarson(t *testing.T) {
	f := newFixture(t)
	f.worktree("fix-login")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: fix-login was made outside carson, so whose it is cannot be told; a person must settle it; leave it until then.")
}

func TestAdoptTakesUpAbandonedWork(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "draft.txt", "half done\n")
	f.abandon("fix-login")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login: its abandoned work, 1 commit not on main, now back on branch fix-login, is in "+dir+", owned by Claude session 9cb74d03-a065.")
	if !f.exists(filepath.Join(dir, "draft.txt")) || f.git(f.local, "branch", "--list", "abandoned/fix-login") != "" {
		t.Error("the abandoned work is not back as the task")
	}
	if record := f.readRecord(dir); record.Task != "fix-login" || record.Harness != "claude" {
		t.Errorf("owner record: %+v", record)
	}
}

func TestAdoptTakesUpABranchLeftWithoutAWorktree(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "-c", "fix-login")
	f.commit(f.local, "login.rb")
	f.git(f.local, "switch", "-q", "main")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login: branch fix-login, left without a worktree with 1 commit not on main, is in "+f.taskFolder("fix-login")+", owned by Claude session 9cb74d03-a065.")
}

// Before the first landing there is no main, and the first task's work is all of the repository's.
func TestTheFirstTaskIsAbandonedAdoptedAndLanded(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, "draft.txt", "half done\n")
	out, code := f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Abandoned fix-login: its work — 1 commit, holding what was uncommitted — is kept as branch abandoned/fix-login")
	out, _ = f.runIn(inClaude, f.local, claudeRunning, "status")
	expectLine(t, out, "fix-login: branch abandoned/fix-login at "+f.short(f.local, "abandoned/fix-login")+", 1 commit not on main.")
	out, code = f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login: its abandoned work, 1 commit not on main, now back on branch fix-login, is in "+dir+", owned by Claude session 9cb74d03-a065.")
	if out, code := f.land(dir); code != 0 {
		t.Errorf("the first task does not land:\n%s", out)
	}
}

// A first task started by mistake, with nothing in it, goes as any task does.
func TestRemoveOfAnEmptyFirstTask(t *testing.T) {
	f := newEmptyFixture(t)
	dir := f.startTask("fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed fix-login: its worktree at "+dir+", which held no commit.")
	if f.exists(dir) {
		t.Error("the worktree is still there")
	}
}

func TestAdoptRefusesABranchWithNothingMainLacks(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "fix-login")
	f.git(f.local, "branch", "abandoned/fix-login")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: branch fix-login holds nothing main lacks, and its name stands in the way of the abandoned work on abandoned/fix-login. Remove it with carson remove fix-login, then adopt again to take up that work.")
}

func TestAdoptRefusesWhatIsNotThere(t *testing.T) {
	f := newFixture(t)
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: no task or branch is named fix-login, and no abandoned work either. Start it with: carson start fix-login")
	out, code = f.adopt(claudeRunning, "main")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: main is a trunk's name, not a task's.")
}

func TestAdoptRefusesAFolderInTheWay(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "-c", "fix-login")
	f.commit(f.local, "login.rb")
	f.git(f.local, "switch", "-q", "main")
	os.MkdirAll(f.taskFolder("fix-login"), 0o755)
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: "+f.taskFolder("fix-login")+" already exists, and is not a worktree of this task. Nothing was changed; move that folder out of the way, then run carson adopt fix-login again.")
}

// Of two sessions adopting one task at once, the one that finds the old record already moved aside gets errOwned.
func TestReplaceOwnerLetsOnlyOneAdopterWin(t *testing.T) {
	admin := t.TempDir()
	if err := createOwner(admin, claude("fix-login", 5000)); err != nil {
		t.Fatal(err)
	}
	os.Rename(filepath.Join(admin, ownerFile), filepath.Join(admin, ownerFile+".1.old")) // the other adopter's step
	if err := replaceOwner(admin, claude("fix-login", 5000), claude("fix-login", 4121)); err != errOwned {
		t.Errorf("the second adopter got %v", err)
	}
}

// From the review of 36da910: an adopter coming after another has finished must not replace the winner's record.
func TestReplaceOwnerRefusesAfterAnotherAdopterFinished(t *testing.T) {
	admin := t.TempDir()
	ended := claude("fix-login", 5000)
	createOwner(admin, ended)
	first := claude("fix-login", 4121)
	first.Session = "11111111-first"
	if err := replaceOwner(admin, ended, first); err != nil {
		t.Fatal(err)
	}
	second := claude("fix-login", 6000)
	second.Session = "22222222-second"
	if err := replaceOwner(admin, ended, second); err != errOwned {
		t.Errorf("the later adopter got %v", err)
	}
	if record, _, _ := readOwner(admin); record.Session != "11111111-first" {
		t.Errorf("the record is now %+v", record)
	}
}

// From the review of 36da910: an ended agent's task whose folder is gone could be neither adopted, abandoned nor removed.
func TestAdoptAnEndedAgentsTaskWhoseFolderIsGone(t *testing.T) {
	f := newFixture(t)
	dir := f.otherSession("fix-login")
	f.commit(dir, "login.rb")
	os.RemoveAll(dir)
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login from Claude session 4e7a91d2-other, which has ended. Its worktree folder, "+dir+", is gone: keep its 1 commit with: carson abandon fix-login")
	out, code = f.abandon("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Abandoned fix-login: its work — 1 commit — is kept as branch abandoned/fix-login")
}

// From the review of 36da910: "then adopt again" was said with no abandoned work to adopt.
func TestAdoptSaysThereIsNothingToAdopt(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "fix-login")
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: branch fix-login holds nothing main lacks, so there is nothing to adopt. Remove it with: carson remove fix-login")
}

// moveRepository moves the local repository to a folder of another name, as the master moved ~/Dev/Prepwise to ~/Dev/Acemon: its
// worktrees stay where they are, each still linked to the old folder. It returns the old folder.
func (f *fixture) moveRepository() string {
	f.t.Helper()
	old, moved := f.local, filepath.Join(f.root, "moved")
	if err := os.Rename(old, moved); err != nil {
		f.t.Fatal(err)
	}
	f.local = moved
	return old
}

// From wanghailei/carson#542: the master moved a repository's folder, and the five tasks it held could be neither worked, landed nor
// removed; carson adopt took one of them over without a word.
func TestAdoptRelinksAnEndedAgentsTaskAfterTheRepositoryMoved(t *testing.T) {
	f := newFixture(t)
	dir := f.otherSession("fix-login")
	f.commit(dir, "login.rb")
	old := f.moveRepository()
	out, code := f.adopt(claudeRunning, "fix-login") // process 5000 has ended
	expectCode(t, code, 0)
	expectLine(t, out, "Adopted fix-login from Claude session 4e7a91d2-other, which has ended: its worktree at "+dir+" is yours now, as it was left.")
	expectLine(t, out, "fix-login's worktree was still linked to "+filepath.Join(old, ".git", "worktrees", "fix-login")+", which is gone; it is linked to the repository at "+f.local+" again.")
	if out, code := f.land(dir); code != 0 {
		t.Errorf("the relinked task does not land:\n%s", out)
	}
	if out, code := f.remove("fix-login"); code != 0 {
		t.Errorf("the relinked task is not removed:\n%s", out)
	}
}

// From wanghailei/carson#542: a task adopted before carson could relink, and so already the session's, was answered "work there",
// where no one could.
func TestAdoptRelinksATaskAlreadyYoursAfterTheRepositoryMoved(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	old := f.moveRepository()
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "fix-login is already yours, at "+dir+"; work there.")
	expectLine(t, out, "fix-login's worktree was still linked to "+filepath.Join(old, ".git", "worktrees", "fix-login")+", which is gone; it is linked to the repository at "+f.local+" again.")
	if out, code := f.land(dir); code != 0 {
		t.Errorf("the relinked task does not land:\n%s", out)
	}
}

func TestAdoptSaysWhyAWorktreeCannotBeRelinkedAndChangesNothing(t *testing.T) {
	f := newFixture(t)
	dir := f.otherSession("fix-login")
	old := f.moveRepository()
	// A worktree whose folder and .git file cannot be written cannot be relinked; both are put back as they were, so the test's folder
	// can go.
	link := filepath.Join(dir, ".git")
	os.Chmod(link, 0o444)
	os.Chmod(dir, 0o555)
	t.Cleanup(func() { os.Chmod(dir, 0o755); os.Chmod(link, 0o644) })
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 1)
	expectLine(t, out, "Not adopted: fix-login's worktree at "+dir+" is linked to "+filepath.Join(old, ".git", "worktrees", "fix-login")+", which is gone, and could not be linked back (")
	if !strings.Contains(out, "Nothing was changed; run carson adopt fix-login again once that is cleared.") {
		t.Errorf("the refusal does not say that nothing was changed:\n%s", out)
	}
	if record, _, _ := readOwner(filepath.Join(f.local, ".git", "worktrees", "fix-login")); record.Session != "4e7a91d2-other" {
		t.Errorf("the owner record changed: %+v", record)
	}
}

// From the review of the plan for #542: git's own repair, run from the repository, relinks every worktree the repository holds, so
// adopting one task would change the worktrees of others.
func TestAdoptRelinksOnlyTheTaskItAdopts(t *testing.T) {
	f := newFixture(t)
	f.otherSession("fix-login")
	other := f.otherSession("dark-mode")
	old := f.moveRepository()
	if _, code := f.adopt(claudeRunning, "fix-login"); code != 0 {
		t.Fatal("fix-login is not adopted")
	}
	link, _ := os.ReadFile(filepath.Join(other, ".git"))
	if want := "gitdir: " + filepath.Join(old, ".git", "worktrees", "dark-mode"); strings.TrimSpace(string(link)) != want {
		t.Errorf("dark-mode's worktree was relinked too: its .git file now reads %q", link)
	}
}

// From the review of the plan for #542: a landed task already yours is answered "remove it", and must be relinked for carson remove
// to work.
func TestAdoptRelinksALandedTaskSoThatItIsRemoved(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	old := f.moveRepository()
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "fix-login is already yours, and has landed; remove it with: carson remove fix-login (from outside its worktree)")
	expectLine(t, out, "fix-login's worktree was still linked to "+filepath.Join(old, ".git", "worktrees", "fix-login")+", which is gone; it is linked to the repository at "+f.local+" again.")
	if out, code := f.remove("fix-login"); code != 0 || f.exists(dir) {
		t.Errorf("the relinked task is not removed:\n%s", out)
	}
}

// From the review of 36da910: adoption dropped the landed mark, which the branch's unchanged tip still earns.
func TestAdoptKeepsTheLandedMark(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	record := claude("fix-login", 5000)
	record.Landed = f.git(f.local, "rev-parse", "main")
	f.own(dir, record)
	f.adopt(claudeRunning, "fix-login")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "fix-login at "+dir+": landed and clean.")
}

// From the third trial: a landed task that is already yours was answered "work there", where the next step is to remove it.
func TestALandedTaskThatIsYoursIsToBeRemoved(t *testing.T) {
	f := newFixture(t)
	f.mergedTask("fix-login")
	for _, command := range []string{"start", "adopt"} {
		out, code := f.runIn(inClaude, f.local, claudeRunning, command, "fix-login")
		expectCode(t, code, 2)
		expectLine(t, out, "Not ")
		if !strings.Contains(out, "fix-login is already yours, and has landed; remove it with: carson remove fix-login (from outside its worktree)") {
			t.Errorf("carson %s:\n%s", command, out)
		}
	}
}
