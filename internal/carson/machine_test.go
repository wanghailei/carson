package carson

import (
	"os"
	"regexp"
	"runtime"
	"testing"
)

// This machine, as the command sees it: a name, and on macOS the platform's UUID as its identity.
func TestThisMachineHasANameAndAStableIdentity(t *testing.T) {
	m := ThisMachine(".", os.Stdout)
	if m.Host == "" || m.Host == "this machine" {
		t.Errorf("no name for this machine: %q", m.Host)
	}
	if runtime.GOOS == "darwin" && !regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`).MatchString(m.ID) {
		t.Errorf("no platform UUID for this Mac: %q", m.ID)
	}
	if m.PID != os.Getpid() {
		t.Errorf("carson's process is %d, not this one", m.PID)
	}
}

// PS finds this test's own process and its parent.
func TestPSNamesAProcessAndItsParent(t *testing.T) {
	ppid, command, err := PS{}.Process(os.Getpid())
	if err != nil || ppid != os.Getppid() || command == "" {
		t.Errorf("this process: parent %d (wanted %d), command %q, %v", ppid, os.Getppid(), command, err)
	}
}
