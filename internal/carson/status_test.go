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
	expectCode(t, code, 1)
	expectLine(t, out, "carson: "+f.root+" is not inside a git repository.")
}

func expectNoLine(t *testing.T, out, unwanted string) {
	t.Helper()
	if strings.Contains(out, unwanted) {
		t.Errorf("found %q in:\n%s", unwanted, out)
	}
}

func TestStatusRepositoryWithoutMainSaysTaskStateUnknown(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "-m", "main", "master")
	dir := filepath.Join(f.root, "worktrees", "task")
	f.git(f.local, "worktree", "add", "-q", dir, "-b", "task", "master")
	f.commit(dir, "work.txt")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: this repository has no main yet.")
	expectLine(t, out, "task at "+dir+": state unknown (")
	expectNoLine(t, out, "merged and clean")
}

func TestStatusFolderPresentButUnknownToGitIsNotGone(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("lost")
	f.write(dir, "draft.txt", "unsaved work\n")
	if err := os.Remove(filepath.Join(dir, ".git")); err != nil {
		t.Fatal(err)
	}
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "lost at "+dir+": git cannot find its checkout (")
	expectNoLine(t, out, "folder is gone")
}

func TestStatusUnreadableFolderIsNotGone(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("locked")
	f.write(dir, "draft.txt", "unsaved work\n")
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	out, _ := f.run(f.local, stranger{}, "status")
	expectNoLine(t, out, "folder is gone")
	expectNoLine(t, out, "merged and clean")
	if !strings.Contains(out, "locked at "+dir+": ") || !strings.Contains(out, "unknown") {
		t.Errorf("an unreadable worktree is not reported as unknown:\n%s", out)
	}
}

func TestStatusRecordNamingNoProcessIsUnknown(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("fix-login")
	f.own(dir, Record{Task: "fix-login", Harness: "terminal", Machine: "test-mac"})
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "A terminal, process 0, on test-mac, unknown (the record names no process):")
}

func TestStatusRecordWithRelativeGitdirIsFound(t *testing.T) {
	f := newFixture(t)
	dir := filepath.Join(f.root, "worktrees", "relative")
	f.git(f.local, "-c", "worktree.useRelativePaths=true", "worktree", "add", "-q", dir, "-b", "relative", "main")
	f.own(dir, claude("relative", 4121))
	out, _ := f.run(f.local, stranger{4121: "Wed Sep 30 09:00:00 2026"}, "status")
	expectLine(t, out, "Claude session 4e7a91d2 on test-mac, live:")
	expectNoLine(t, out, "No owner record")
}

func TestStatusCountsTheFilesOfAnUntrackedFolder(t *testing.T) {
	f := newFixture(t)
	dir := f.worktree("new-folder")
	if err := os.Mkdir(filepath.Join(dir, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.md", "b.md", "c.md"} {
		f.write(filepath.Join(dir, "docs"), name, name)
	}
	f.own(dir, claude("new-folder", 4121))
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "new-folder at "+dir+": working, 3 uncommitted files.")
}

func TestStatusLeavesTheIndexUntouched(t *testing.T) {
	f := newFixture(t)
	f.write(f.local, "first.txt", "changed\n")
	index := filepath.Join(f.local, ".git", "index")
	before, err := os.Stat(index)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(1100 * time.Millisecond)
	f.run(f.local, stranger{}, "status")
	after, _ := os.Stat(index)
	if !after.ModTime().Equal(before.ModTime()) {
		t.Errorf("status rewrote the index: %v, then %v", before.ModTime(), after.ModTime())
	}
}

func TestStatusGivesUpOnASilentGitHubWithinTheLimit(t *testing.T) {
	f := newFixture(t)
	// A remote helper that answers nothing and keeps its pipes open, as a server that accepts and never replies.
	bin := filepath.Join(f.root, "bin")
	os.Mkdir(bin, 0o755)
	if err := os.WriteFile(filepath.Join(bin, "git-remote-silent"), []byte("#!/bin/sh\nsleep 20\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	f.git(f.local, "remote", "set-url", "github", "silent::nowhere")
	limit := networkLimit
	networkLimit = time.Second
	t.Cleanup(func() { networkLimit = limit })
	began := time.Now()
	out, code := f.run(f.local, stranger{}, "status")
	if took := time.Since(began); took > 8*time.Second {
		t.Errorf("status took %v against a silent GitHub", took)
	}
	expectCode(t, code, 0)
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+". GitHub could not be reached (no answer within 1s).")
}

func TestStatusGroupsTwoTasksOfOneSessionAndPutsUnownedLast(t *testing.T) {
	f := newFixture(t)
	unowned := f.worktree("aaa-unowned")
	first, second := f.worktree("fix-one"), f.worktree("fix-two")
	f.own(first, claude("fix-one", 4121))
	f.own(second, claude("fix-two", 4121))
	out, _ := f.run(f.local, stranger{4121: "Wed Sep 30 09:00:00 2026"}, "status")
	session := strings.Index(out, "Claude session 4e7a91d2 on test-mac, live:")
	one, two := strings.Index(out, "fix-one at "+first), strings.Index(out, "fix-two at "+second)
	orphan := strings.Index(out, noOwnerHeading)
	if strings.Count(out, "Claude session 4e7a91d2") != 1 || session < 0 || !(session < one && session < two && two < orphan) || !strings.Contains(out, "aaa-unowned at "+unowned) {
		t.Errorf("tasks not grouped by session with the unowned last:\n%s", out)
	}
}

func TestStatusDetachedMainTree(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "switch", "-q", "--detach")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "Main working tree: on a detached HEAD at "+f.git(f.local, "rev-parse", "--short", "HEAD")+", not main.")
}

func TestStatusUsesTheOnlyRemoteWhenMainTracksNone(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "--unset-upstream", "main")
	f.git(f.local, "remote", "rename", "github", "backup")
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", the same as GitHub's.")
}

func TestStatusPrefersTheRemoteNamedGithubAmongSeveral(t *testing.T) {
	f := newFixture(t)
	f.git(f.local, "branch", "--unset-upstream", "main")
	f.git(f.local, "remote", "add", "mirror", filepath.Join(f.root, "no-such-mirror.git"))
	out, _ := f.run(f.local, stranger{}, "status")
	expectLine(t, out, "main: at "+f.git(f.local, "rev-parse", "--short", "main")+", the same as GitHub's.")
}
