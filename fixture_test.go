package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// A world for one test: a bare repository standing in for GitHub, a clone of it as the local repository with main, and folders for
// worktrees — all under the test's own temporary folder, with git's user and global configuration isolated from the machine's.
type fixture struct {
	t      *testing.T
	root   string
	github string
	local  string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	root := t.TempDir()
	// On macOS the temporary folder is reached through a link; git reports real paths, so the fixture uses them too.
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	// Worktrees go under the home folder, so the test gives carson a home of its own.
	t.Setenv("HOME", root)
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(root, "gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("GIT_AUTHOR_NAME", "Tester")
	t.Setenv("GIT_AUTHOR_EMAIL", "tester@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "Tester")
	t.Setenv("GIT_COMMITTER_EMAIL", "tester@example.com")
	f := &fixture{t: t, root: root, github: filepath.Join(root, "github.git"), local: filepath.Join(root, "local")}
	f.git(root, "init", "-q", "--bare", "-b", "main", f.github)
	f.git(root, "clone", "-q", f.github, f.local)
	f.git(f.local, "remote", "rename", "origin", "github")
	f.commit(f.local, "first.txt")
	f.git(f.local, "push", "-q", "-u", "github", "main")
	return f
}

// git runs git in dir and returns its output, failing the test when git fails.
func (f *fixture) git(dir string, args ...string) string {
	f.t.Helper()
	command := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var out, errs bytes.Buffer
	command.Stdout, command.Stderr = &out, &errs
	if err := command.Run(); err != nil {
		f.t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, errs.String())
	}
	return strings.TrimSpace(out.String())
}

// commit adds a file named name in dir and commits it.
func (f *fixture) commit(dir, name string) string {
	f.t.Helper()
	f.write(dir, name, name+"\n")
	f.git(dir, "add", name)
	f.git(dir, "commit", "-q", "-m", "add "+name)
	return f.git(dir, "rev-parse", "--short", "HEAD")
}

func (f *fixture) write(dir, name, content string) {
	f.t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		f.t.Fatal(err)
	}
}

// otherClone is the master's other machine: a second clone of GitHub, up to date.
func (f *fixture) otherClone() string {
	f.t.Helper()
	other := filepath.Join(f.root, "other")
	if _, err := os.Stat(other); err != nil {
		f.git(f.root, "clone", "-q", f.github, other)
	} else {
		f.git(other, "pull", "-q", "--ff-only")
	}
	return other
}

// otherMachine pushes a commit to GitHub from the other machine.
func (f *fixture) otherMachine() {
	f.t.Helper()
	other := f.otherClone()
	f.commit(other, fmt.Sprintf("other-%d.txt", len(f.git(other, "log", "--oneline"))))
	f.git(other, "push", "-q", "origin", "main")
}

// worktree makes a worktree for task beside the repository, as carson start will, and returns its folder.
func (f *fixture) worktree(task string) string {
	f.t.Helper()
	dir := filepath.Join(f.root, "worktrees", task)
	f.git(f.local, "worktree", "add", "-q", dir, "-b", task, "main")
	return dir
}

// stranger is a machine whose processes the test describes: started times by process id, a missing id being a process not running;
// and each process's parent and its own command name.
type stranger map[int]string

func (s stranger) Started(pid int) (string, error) {
	if started, ok := s[pid]; ok {
		return started, nil
	}
	return "", errNotRunning
}

// parents describes the process tree the test's carson runs in: carson is process 900, its shell 800, and above that a harness.
var parents = map[int]struct {
	ppid    int
	command string
}{900: {800, "carson"}, 800: {700, "bash"}, 700: {1, "pi"}}

// Inside finds no process working inside any folder: the test's machine is idle.
func (s stranger) Inside(dir string) ([]string, error) { return nil, nil }

func (s stranger) Process(pid int) (int, string, error) {
	if p, ok := parents[pid]; ok {
		return p.ppid, p.command, nil
	}
	return 0, "", errNotRunning
}

// environment is the variables a test's carson sees; the empty one is a plain terminal.
type environment map[string]string

func (e environment) get(name string) string { return e[name] }

// inClaude is the environment of a Claude Code session whose process is 4121.
var inClaude = environment{"CLAUDE_CODE_SESSION_ID": "9cb74d03-a065-48ca", "CLAUDE_PID": "4121"}

// run runs carson with args in dir, in a plain terminal on this test's machine, and returns its output and exit code.
func (f *fixture) run(dir string, processes Processes, args ...string) (string, int) {
	f.t.Helper()
	return f.runIn(environment{}, dir, processes, args...)
}

// runIn runs carson in the environment given.
func (f *fixture) runIn(env environment, dir string, processes Processes, args ...string) (string, int) {
	f.t.Helper()
	// Every environment has a home, as a real one does: the test's own folder.
	withHome := environment{"HOME": f.root}
	for name, value := range env {
		withHome[name] = value
	}
	var out bytes.Buffer
	code := Main(args, Machine{Dir: dir, Out: &out, Host: "test-mac", ID: "test-id", Env: withHome.get, PID: 900, Processes: processes})
	return out.String(), code
}
