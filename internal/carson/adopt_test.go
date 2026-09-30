package carson

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
	expectLine(t, out, "Adopted fix-login from Claude session 4e7a91d2-other on test-mac, which has ended: its worktree at "+dir+" is yours now, as it was left.")
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
	expectLine(t, out, "Not adopted: fix-login belongs to Claude session 4e7a91d2-other on test-mac, which is live; only an ended agent's task is adopted.")
}

func TestAdoptRefusesAnOwnerWhoseStateIsUnknown(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	record := claude("fix-login", 5000)
	record.Machine = "linux-box"
	f.own(dir, record)
	out, code := f.adopt(claudeRunning, "fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not adopted: fix-login belongs to Claude session 4e7a91d2-aaaa on linux-box, whose state is unknown (it cannot be checked from test-mac); only an agent seen to have ended gives up its task.")
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
	expectLine(t, out, "Adopted fix-login: its abandoned work, 1 commit not on main, now back on branch fix-login, is in "+dir+", owned by Claude session 9cb74d03-a065 on test-mac.")
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
	expectLine(t, out, "Adopted fix-login: branch fix-login, left without a worktree with 1 commit not on main, is in "+f.taskFolder("fix-login")+", owned by Claude session 9cb74d03-a065 on test-mac.")
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
	expectLine(t, out, "Adopted fix-login from Claude session 4e7a91d2-other on test-mac, which has ended. Its worktree folder, "+dir+", is gone: keep its 1 commit with: carson abandon fix-login")
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
