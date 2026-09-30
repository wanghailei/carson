package carson

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Processes tells when a process started, as ps reports it, or errNotRunning when no process has that id.
type Processes interface {
	Started(pid int) (string, error)
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
// another process has since taken its id; unknown when it cannot be checked — a record naming no process, a record from another
// machine, or ps unable to answer.
func (m Machine) livenessOf(record Record) (liveness, string) {
	if record.PID <= 0 || record.Started == "" {
		return unknown, "the record names no process"
	}
	if record.Machine != m.Host {
		return unknown, "it cannot be checked from " + m.Host
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
