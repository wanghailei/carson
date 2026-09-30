package carson

import (
	"errors"
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
	out, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	started := strings.TrimSpace(string(out))
	var exit *exec.ExitError
	if (err == nil || errors.As(err, &exit)) && started == "" {
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

// livenessOf observes a record's owner: live when its process runs with the recorded start time; ended when it does not run, or
// another process has since taken its id; unknown when it cannot be checked — on another machine, or when ps cannot answer.
func (m Machine) livenessOf(record Record) (liveness, string) {
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
