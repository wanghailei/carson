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

// mergedTask starts a task, commits in it and merges it, as the steps before carson remove.
func (f *fixture) mergedTask(name string) string {
	f.t.Helper()
	dir := f.startTask(name)
	f.commit(dir, name+".rb")
	if out, code := f.merge(dir); code != 0 {
		f.t.Fatalf("carson merge: %s", out)
	}
	return dir
}

func TestRemoveRemovesAMergedTask(t *testing.T) {
	f := newFixture(t)
	dir := f.mergedTask("fix-login")
	out, code := f.remove("fix-login")
	expectCode(t, code, 0)
	expectLine(t, out, "Removed fix-login: its worktree at "+dir+", and its branch, whose work is on main at "+f.short(f.local, "main")+". It was owned by Claude session 9cb74d03 on test-mac.")
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
	expectLine(t, out, "Not removed: fix-login holds 1 uncommitted file — notes.txt. Commit and merge it, or declare the task abandoned: carson remove fix-login --abandoned")
}

func TestRemoveRefusesWorkNotOnMain(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.commit(dir, "login.rb")
	out, code := f.remove("fix-login")
	expectCode(t, code, 2)
	expectLine(t, out, "Not removed: fix-login holds 1 commit not on main. Merge it with carson merge, or declare the task abandoned: carson remove fix-login --abandoned")
}

func TestRemoveKeepsIgnoredFiles(t *testing.T) {
	f := newFixture(t)
	dir := f.startTask("fix-login")
	f.write(dir, ".gitignore", "local.env\n")
	f.git(dir, "add", ".gitignore")
	f.git(dir, "commit", "-q", "-m", "ignore local.env")
	f.merge(dir)
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
	expectLine(t, out, "Not removed: processes are working inside it — puma (pid 4121). Stop them, then run carson remove again.")
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
	expectLine(t, out, "Not removed: fix-login belongs to Claude session 4e7a91d2 on test-mac, which is live. Only its owner removes it.")
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
	out, code := f.remove("fix-login", "--abandoned")
	expectCode(t, code, 0)
	kept := f.git(f.local, "rev-parse", "--short", "abandoned/fix-login")
	expectLine(t, out, "Removed fix-login's worktree, its task declared abandoned. Its work — 2 commits, the last holding what was uncommitted — is kept as branch abandoned/fix-login at "+kept+". To take it up again: git worktree add <folder> abandoned/fix-login")
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
	time.Sleep(200 * time.Millisecond)
	inside, err := PS{}.Inside(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(inside, ", "), "sleep (pid ") {
		t.Errorf("the sleeping process is not found inside %s: %v", dir, inside)
	}
}
