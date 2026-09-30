package carson

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
