// Package carson starts, shows, merges and removes the tasks agents work on, each in its own worktree, so that local main only moves
// forward, and only by a finished task landing (rules 11.1–11.8). It keeps no state of its own beyond one owner record per worktree,
// runs only when called, and reports what it observed, not what it attempted.
package carson

import (
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

// Machine is what one run of carson sees of the world: the folder it runs in, where it writes, this machine's name, its environment,
// and its processes. Tests give it a machine of their own.
type Machine struct {
	Dir       string
	Out       io.Writer
	Host      string
	Env       func(string) string
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
	case "start", "merge", "remove":
		fmt.Fprintf(machine.Out, "carson %s: not built yet; this carson has only status. Nothing was changed.\n", args[0])
		return failed
	default:
		fmt.Fprintf(machine.Out, "carson: no command %q. Its commands:\n%s", args[0], usage)
		return refused
	}
}
