package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// git answered and exited 0, but a process it started still holds its error stream: the answer is complete, not a failure.
func TestGitAnswerStandsWhenAChildHoldsThePipes(t *testing.T) {
	f := newFixture(t)
	began := time.Now()
	out, err := git(f.local, "-c", "alias.answer=!echo ok; sleep 3 >&2 &", "answer")
	if err != nil || out != "ok" {
		t.Errorf("got %q, %v; wanted the answer ok", out, err)
	}
	if took := time.Since(began); took > 2500*time.Millisecond {
		t.Errorf("waited %v for a child that git left behind", took)
	}
}

// noSuchRepositoryOnGitHub points GitHub's remote at a repository GitHub does not have, reached over SSH, whose answer is GitHub's:
// ssh, here a script, says the repository is not found and fails. It returns the remote's address.
func (f *fixture) noSuchRepositoryOnGitHub() string {
	f.t.Helper()
	ssh := filepath.Join(f.root, "ssh")
	if err := os.WriteFile(ssh, []byte("#!/bin/sh\necho 'ERROR: Repository not found.' >&2\nexit 1\n"), 0o755); err != nil {
		f.t.Fatal(err)
	}
	address := "git@github.com:someone/no-such-repo.git"
	f.git(f.local, "remote", "set-url", "github", address)
	f.git(f.local, "config", "core.sshCommand", ssh)
	return address
}

// From wanghailei/carson#541: GitHub said the repository was not found, and git followed with a line of its own saying only that the
// remote could not be read; carson kept git's line, and said GitHub could not be reached.
func TestGitHubsWordThatTheRepositoryIsNotFoundIsKept(t *testing.T) {
	said := "ERROR: Repository not found.\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n"
	if got := explanation(said); got != "ERROR: Repository not found." {
		t.Errorf("got %q; wanted GitHub's own line", got)
	}
}

// Ctrl-C during a call to GitHub stops git and its helpers with it, rather than leaving them running after carson.
func TestInterruptingACallToGitHubStopsItsHelpers(t *testing.T) {
	f := newFixture(t)
	bin := filepath.Join(f.root, "bin")
	os.Mkdir(bin, 0o755)
	if err := os.WriteFile(filepath.Join(bin, "git-remote-silent"), []byte("#!/bin/sh\nsleep 21.7319\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	go func() {
		time.Sleep(500 * time.Millisecond)
		syscall.Kill(os.Getpid(), syscall.SIGINT)
	}()
	_, err := gitNetwork(f.local, "ls-remote", "silent::nowhere", "refs/heads/main")
	if err == nil || !strings.Contains(err.Error(), "interrupted") {
		t.Errorf("got %v; wanted the call reported as interrupted", err)
	}
	time.Sleep(300 * time.Millisecond)
	if out, _ := exec.Command("pgrep", "-f", "sleep 21.7319").Output(); len(out) > 0 {
		t.Errorf("the helper outlived the interrupted call: %s", out)
	}
}
