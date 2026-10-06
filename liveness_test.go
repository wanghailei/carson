package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

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

// Without lsof the error names the cure — the lack 5.1 hit on Oma, where lsof is no base package. An empty PATH stands in for a
// machine without it.
func TestPSNamesTheCureWhenLsofIsMissing(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if _, err := (PS{}).Inside(t.TempDir()); err == nil || !strings.Contains(err.Error(), "sudo pacman -S lsof") {
		t.Errorf("missing lsof: %v, wanted the install command named", err)
	}
}
