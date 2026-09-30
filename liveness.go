package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

// Processes tells when a process started, as ps reports it, and which process started it along with its own command name, or
// errNotRunning when no process has the id; and which processes work inside a folder.
type Processes interface {
	Started(pid int) (string, error)
	Process(pid int) (ppid int, command string, err error)
	Inside(dir string) ([]string, error)
}

var errNotRunning = errors.New("not running")

// PS is this machine's processes, as ps reports them.
type PS struct{}

func (PS) Started(pid int) (string, error) {
	if pid <= 0 {
		return "", fmt.Errorf("%d is no process id", pid)
	}
	command := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid))
	var out, errs bytes.Buffer
	command.Stdout, command.Stderr = &out, &errs
	err := command.Run()
	started := strings.TrimSpace(out.String())
	// ps names no process and says nothing else: none has that id. Anything ps says on its error stream is a failure to tell.
	if complaint := firstLine(errs.String()); complaint != "" {
		return "", fmt.Errorf("ps: %s", complaint)
	}
	var exit *exec.ExitError
	if started == "" && (err == nil || errors.As(err, &exit)) {
		return "", errNotRunning
	}
	if err != nil {
		return "", err
	}
	return started, nil
}

func (PS) Process(pid int) (int, string, error) {
	if pid <= 0 {
		return 0, "", fmt.Errorf("%d is no process id", pid)
	}
	out, err := exec.Command("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid)).Output()
	fields := strings.Fields(string(out))
	if len(fields) < 2 {
		if err == nil {
			return 0, "", errNotRunning
		}
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return 0, "", errNotRunning
		}
		return 0, "", err
	}
	ppid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, "", fmt.Errorf("ps gave no parent for %d: %q", pid, out)
	}
	// ps may give the command's whole path, and a path may hold spaces.
	command := strings.Join(fields[1:], " ")
	return ppid, command[strings.LastIndex(command, "/")+1:], nil
}

// Inside names the processes of the user running carson that work inside dir — whose working folder is dir or below it — as "puma
// (pid 4121)", from lsof. Other users' processes are not visible to carson, so they are not looked for. carson itself is left out.
func (PS) Inside(dir string) ([]string, error) {
	out, err := exec.Command("lsof", "-a", "-u", strconv.Itoa(os.Getuid()), "-d", "cwd", "-F", "pcn").Output()
	if len(out) == 0 && err != nil {
		return nil, fmt.Errorf("lsof: %v", err)
	}
	self := strconv.Itoa(os.Getpid())
	var found []string
	var pid, command string
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		switch line[0] {
		case 'p':
			pid, command = line[1:], ""
		case 'c':
			command = line[1:]
		case 'n':
			if path := line[1:]; (path == dir || strings.HasPrefix(path, dir+"/")) && pid != self {
				found = append(found, fmt.Sprintf("%s (pid %s)", command, pid))
			}
		}
	}
	return found, nil
}

// liveness is whether a task's owner is still at work. Only ended is ever acted on; unknown never counts as ended.
type liveness int

const (
	live liveness = iota
	ended
	unknown
)

func (l liveness) String() string {
	switch l {
	case live:
		return "live"
	case ended:
		return "ended"
	default:
		return "unknown"
	}
}

// livenessOf observes a record's owner: live when its process runs with the recorded start time; ended when it does not run, or
// another process has since taken its id; unknown when it cannot be checked — a record naming no process, or ps unable to answer.
// Every record carson reads was made on the machine reading it: a worktree's record lives in its clone's own git folder, and never
// travels to another machine.
func (m Machine) livenessOf(record Record) (liveness, string) {
	if record.PID <= 0 {
		return unknown, "the record names no process"
	}
	if record.Started == "" {
		return unknown, fmt.Sprintf("the record has no start time for process %d", record.PID)
	}
	started, err := m.Processes.Started(record.PID)
	switch {
	case errors.Is(err, errNotRunning):
		return ended, ""
	case err != nil:
		return unknown, "ps could not tell: " + err.Error()
	case started == record.Started:
		return live, ""
	default:
		return ended, ""
	}
}
