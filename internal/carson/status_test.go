package carson

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func expectCode(t *testing.T, got, want int) {
	t.Helper()
	if got != want {
		t.Errorf("exit code %d, wanted %d", got, want)
	}
}

// expectLine fails unless some line of out starts with want.
func expectLine(t *testing.T, out, want string) {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), want) {
			return
		}
	}
	t.Errorf("no line starting %q in:\n%s", want, out)
}

func (f *fixture) own(dir string, record Record) {
	f.t.Helper()
	admin := f.git(dir, "rev-parse", "--absolute-git-dir")
	if err := writeOwner(admin, record); err != nil {
		f.t.Fatal(err)
	}
}

func claude(task string, pid int) Record {
	return Record{Task: task, Harness: "claude", Session: "4e7a91d2-aaaa-bbbb", PID: pid, Started: "Wed Sep 30 09:00:00 2026", Machine: "test-mac", Created: time.Date(2026, 9, 30, 9, 1, 0, 0, time.UTC)}
}

func TestStatusMainTheSameAsGitHub(t *testing.T) {
	f := newFixture(t)
	out, code := f.run(f.local, stranger{}, "status")
	expectCode(t, code, 0)
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", the same as GitHub's.")
	expectLine(t, out, "Main working tree: on main, clean.")
	expectLine(t, out, "No tasks.")
}

func TestStatusMainAheadOfGitHub(t *testing.T) {
	f := newFixture(t)
	f.commit(f.local, "second.txt")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", 1 commit ahead of GitHub (merged here, not pushed).")
}

func TestStatusMainBehindGitHub(t *testing.T) {
	f := newFixture(t)
	f.otherMachine()
	f.otherMachine()
	f.git(f.local, "fetch", "-q", "github")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", 2 commits behind GitHub.")
}

func TestStatusGitHubAheadButNotFetched(t *testing.T) {
	f := newFixture(t)
	f.otherMachine()
	out, _ := f.run(f.local, stranger{}, "status")
	remote := f.git(f.github, "rev-parse", "--short", "main")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+". GitHub's main is at "+remote+", which this machine has not fetched: how far behind, or whether diverged, is unknown.")
}

func TestStatusMainDivergedFromGitHub(t *testing.T) {
	f := newFixture(t)
	f.commit(f.local, "here.txt")
	f.otherMachine()
	f.otherMachine()
	f.git(f.local, "fetch", "-q", "github")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", diverged from GitHub: 1 commit here, 2 there. The next carson merge brings GitHub's commits in.")
}

func TestStatusGitHubUnreachable(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "set-url", "github", filepath.Join(f.root, "no-such-repository.git"))
	out, code := f.run(f.local, stranger{}, "status")
	expectCode(t, code, 0)
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+". GitHub could not be reached (")
	if !strings.Contains(out, "How main stands against it is unknown.") {
		t.Errorf("the unknown state is not named:\n%s", out)
	}
}

func TestStatusNoRemote(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "remote", "remove", "github")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+". No GitHub remote: main is on this machine only.")
}

func TestStatusMainTreeWithChanges(t *testing.T) {
	f := newFixture(t)
	f.write(f.local, "first.txt", "changed\n")
	f.write(f.local, "draft.md", "draft\n")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "Main working tree: on main, with 2 changes: M first.txt, ?? draft.md.")
}

func TestStatusMainTreeOffMain(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "-c", "elsewhere")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "Main working tree: on elsewhere, not main.")
}

func TestStatusLiveTaskAtWork(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.commit(dir, "login.rb")
	f.write(dir, "notes.txt", "notes\n")
	f.own(dir, claude("fix-login", 4121))
	out, _ := f.run(f.local, stranger{4121: "Wed Sep 30 09:00:00 2026"}, "status")
	expectLine(t, out, "Claude session 4e7a91d2 on test-mac, live:")
	expectLine(t, out, "fix-login at "+dir+": working, 1 commit not on main, 1 uncommitted file.")
}

func TestStatusEndedTaskMergedAndClean(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("done-task")
	f.own(dir, claude("done-task", 4121))
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "Claude session 4e7a91d2 on test-mac, ended:")
	expectLine(t, out, "done-task at "+dir+": merged and clean.")
}

func TestStatusProcessReusedIsEnded(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.own(dir, claude("fix-login", 4121))
	out, _ := f.run(f.local, stranger{4121: "Wed Sep 30 11:45:00 2026"}, "status")
	expectLine(t, out, "Claude session 4e7a91d2 on test-mac, ended:")
}

func TestStatusOwnerOnAnotherMachineIsUnknown(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	record := claude("fix-login", 4121)
	record.Machine = "linux-box"
	f.own(dir, record)
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "Claude session 4e7a91d2 on linux-box, unknown (it cannot be checked from test-mac):")
}

func TestStatusWorktreeWithoutOwnerRecord(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("old-thing")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "No owner record (made outside carson; whose it is is the master's to settle):")
	expectLine(t, out, "old-thing at "+dir+": merged and clean.")
}

func TestStatusWorktreeFolderGone(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("vanished")
	f.commit(dir, "work.txt")
	f.own(dir, claude("vanished", 4121))
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "vanished at "+dir+": its folder is gone; branch vanished holds 1 commit not on main.")
}

func TestBareCarsonPrintsItsFourCommands(t *testing.T) {
	f := newFixture(t)
	out, code := f.run(f.local, stranger{})
	expectCode(t, code, 0)
	for _, command := range []string{"carson start <task>", "carson status", "carson merge", "carson remove <task>"} {
		expectLine(t, out, command)
	}
}

func TestUnknownCommandIsRefused(t *testing.T) {
	f := newFixture(t)
	out, code := f.run(f.local, stranger{}, "deliver")
	expectCode(t, code, 2)
	expectLine(t, out, "carson: no command \"deliver\". Its commands:")
}

func TestStatusOutsideARepository(t *testing.T) {
	f := newFixture(t)
	out, code := f.run(f.root, stranger{}, "status")
	expectCode(t, code, 2)
	expectLine(t, out, "carson: "+f.root+" is not inside a git repository.")
}
