package carson

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Cases from the review of c15a993, each staged there against the first slice before it was fixed.

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

// PS is carson's boundary with the machine: this test's own process is running, and a process that has exited is not.
func TestPSTellsARunningProcessFromAnEndedOne(t *testing.T) {
	started, err := PS{}.Started(os.Getpid())
	if err != nil || started == "" {
		t.Errorf("this process: %q, %v", started, err)
	}
	exited := exec.Command("true")
	if err := exited.Run(); err != nil {
		t.Fatal(err)
	}
	if _, err := (PS{}).Started(exited.Process.Pid); err != errNotRunning {
		t.Errorf("an exited process: %v, wanted not running", err)
	}
	if _, err := (PS{}).Started(0); err == errNotRunning {
		t.Error("process 0 is read as not running; it is no process at all")
	}
}
