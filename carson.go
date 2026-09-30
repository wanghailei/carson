package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// Version is Carson's version. The major version is the master's; agents set the minor and patch versions (rule 10.8).
const Version = "5.1.0"

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

// Machine is what one run of carson sees of the world: the folder it runs in, where it writes, its environment, carson's own process
// and the machine's processes. Tests give it a machine of their own.
type Machine struct {
	Dir       string
	Out       io.Writer
	Env       func(string) string
	PID       int
	Processes Processes
}

// ThisMachine is the machine carson runs on, as the command sees it.
func ThisMachine(dir string, out io.Writer) Machine {
	return Machine{Dir: dir, Out: out, Env: os.Getenv, PID: os.Getpid(), Processes: PS{}}
}

const usage = `carson start <task>     start a task in its own worktree, from the latest main
carson status           show main, the main working tree, every task and abandoned work; changes nothing
carson land <task>      land a finished task on main, checked, and push main to GitHub
carson remove <task>    remove a landed task's worktree and branch, from outside its worktree
carson abandon <task>   keep an unfinished task's work on a branch abandoned/<task>, and remove its worktree
carson adopt <task>     make yours an ended agent's task, abandoned work, or a branch left without a worktree
carson --version        show carson's version
`

// Main runs carson with its arguments on machine and returns its exit code.
func Main(args []string, machine Machine) int {
	machine.Out = &badged{out: machine.Out}
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Fprint(machine.Out, usage)
			return done
		}
	}
	if len(args) == 1 && args[0] == "--version" {
		fmt.Fprintln(machine.Out, "carson "+Version)
		return done
	}
	if len(args) == 0 || args[0] == "help" {
		fmt.Fprint(machine.Out, usage)
		return done
	}
	switch args[0] {
	case "status":
		return status(machine, args[1:])
	case "start":
		return start(machine, args[1:])
	case "land":
		return land(machine, args[1:])
	case "remove":
		return remove(machine, args[1:])
	case "abandon":
		return abandon(machine, args[1:])
	case "adopt":
		return adopt(machine, args[1:])
	default:
		fmt.Fprintf(machine.Out, "No command %q. Carson's commands:\n%s", args[0], usage)
		return refused
	}
}

// Badge marks every line carson writes, so a person reading an agent's conversation can tell carson's words from the rest, as Carson 4
// did: ⧓, BLACK BOWTIE (U+29D3).
const Badge = "⧓"

// badged writes what it is given with the badge in front of every line that has something on it.
type badged struct {
	out     io.Writer
	midLine bool
}

func (b *badged) Write(p []byte) (int, error) {
	marked := make([]byte, 0, len(p)+8)
	for _, c := range p {
		if !b.midLine && c != '\n' {
			marked = append(marked, Badge+" "...)
			b.midLine = true
		}
		marked = append(marked, c)
		if c == '\n' {
			b.midLine = false
		}
	}
	if _, err := b.out.Write(marked); err != nil {
		return 0, err
	}
	return len(p), nil
}

// What every command says when it cannot open the repository it runs in.
const (
	notARepository       = "%s is not inside a git repository; run carson from inside one."
	unreadableRepository = "the repository could not be read (%s); run carson again once that is cleared."
	// settled says who decides what carson cannot: a person, not another agent.
	settled = "a person must settle it; leave it until then"
)

// repository opens the repository carson runs in, with its main, or says why it cannot.
func (m Machine) repository() (*repository, error) {
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		return nil, refuse(failed, notARepository, m.Dir)
	}
	if err != nil {
		return nil, refuse(failed, unreadableRepository, reason(err))
	}
	if missing := repo.mainMissing(); missing != "" {
		return nil, refuse(failed, "%s. Nothing was changed.", missing)
	}
	return repo, nil
}

// oneTask reads a command's arguments: one task's name, and no options.
func oneTask(args []string, command string) (string, error) {
	var name string
	for _, arg := range args {
		switch {
		case strings.HasPrefix(arg, "-"):
			return "", refuse(refused, "%s has no option %q.", command, arg)
		case name != "":
			return "", refuse(refused, "one task at a time; %q and %q were given.", name, arg)
		default:
			name = arg
		}
	}
	if name == "" {
		return "", refuse(refused, "name the task, as in %s fix-login.", command)
	}
	return name, nil
}

// newTaskName refuses a name no new task may take: lowercase words joined by hyphens, and neither a trunk's nor where abandoned work
// is kept.
func newTaskName(name string) error {
	switch {
	case name == "main" || name == "master":
		return refuse(refused, "%s is a trunk's name, not a task's.", name)
	case name == "abandoned":
		return refuse(refused, "abandoned is where carson keeps the branches of abandoned tasks, not a task's name.")
	case !taskNamePattern.MatchString(name):
		return refuse(refused, "%q is not a task name: use lowercase words joined by hyphens, like fix-login.", name)
	}
	return nil
}
