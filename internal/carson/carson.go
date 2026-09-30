// Package carson starts, shows, merges and removes the tasks agents work on, each in its own worktree, so that local main only moves
// forward, and only by a finished task landing (rules 11.1–11.8). It keeps no state of its own beyond one owner record per worktree,
// runs only when called, and reports what it observed, not what it attempted.
package carson

import (
	"errors"
	"fmt"
	"io"
)

// Exit codes mean one thing each: done, as reported; could not finish, with the state things are left in; refused, because a rule
// forbids it. Nothing else ever exits 0.
const (
	done    = 0
	failed  = 1
	refused = 2
)

// refusal is why carson did not do what it was asked, with the exit code that means.
type refusal struct {
	code int
	text string
}

func (r *refusal) Error() string { return r.text }

func refuse(code int, format string, args ...any) error {
	return &refusal{code: code, text: fmt.Sprintf(format, args...)}
}

// codeOf is the exit code an error means: a refusal's own, or could-not-finish for any other.
func codeOf(err error) int {
	var r *refusal
	if errors.As(err, &r) {
		return r.code
	}
	return failed
}

// Machine is what one run of carson sees of the world: the folder it runs in, where it writes, this machine's name and its stable
// identity, its environment, carson's own process and the machine's processes. Tests give it a machine of their own.
type Machine struct {
	Dir       string
	Out       io.Writer
	Host      string
	ID        string
	Env       func(string) string
	PID       int
	Processes Processes
}

const usage = `carson start <task>    start a task in its own worktree, from the latest main
carson status          show main, the main working tree and every task; changes nothing
carson merge           merge the task you are in into main, and push main to GitHub
carson remove <task>   remove a task's worktree and branch
`

// Main runs carson with its arguments on machine and returns its exit code.
func Main(args []string, machine Machine) int {
	if len(args) == 0 {
		fmt.Fprint(machine.Out, usage)
		return done
	}
	switch args[0] {
	case "status":
		return status(machine)
	case "start":
		return start(machine, args[1:])
	case "merge":
		return merge(machine, args[1:])
	case "remove":
		fmt.Fprintf(machine.Out, "carson %s: not built yet; this carson has status, start and merge. Nothing was changed.\n", args[0])
		return failed
	default:
		fmt.Fprintf(machine.Out, "carson: no command %q. Its commands:\n%s", args[0], usage)
		return refused
	}
}
