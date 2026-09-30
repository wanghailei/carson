package main

import (
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// ThisMachine is the machine carson runs on, as the command sees it.
func ThisMachine(dir string, out io.Writer) Machine {
	return Machine{Dir: dir, Out: out, Host: machineName(), ID: machineID(), Env: os.Getenv, PID: os.Getpid(), Processes: PS{}}
}

// machineName is the name people know the machine by: macOS's local host name, else the host name without its domain.
func machineName() string {
	if runtime.GOOS == "darwin" {
		if out, err := exec.Command("scutil", "--get", "LocalHostName").Output(); err == nil && strings.TrimSpace(string(out)) != "" {
			return strings.TrimSpace(string(out))
		}
	}
	host, err := os.Hostname()
	if err != nil || host == "" {
		return "this machine"
	}
	name, _, _ := strings.Cut(host, ".")
	return name
}

// machineID is the machine's own stable identity — macOS's platform UUID, Linux's machine id — or "" where there is none. Unlike a
// host name, which mDNS can change, it stays the same, so a record says truly whether its owner is on this machine.
func machineID() string {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.Command("ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
		if err != nil {
			return ""
		}
		for _, line := range strings.Split(string(out), "\n") {
			if strings.Contains(line, `"IOPlatformUUID"`) {
				_, value, _ := strings.Cut(line, "=")
				return strings.Trim(strings.TrimSpace(value), `"`)
			}
		}
	case "linux":
		if data, err := os.ReadFile("/etc/machine-id"); err == nil {
			return strings.TrimSpace(string(data))
		}
	}
	return ""
}
