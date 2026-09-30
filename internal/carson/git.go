package carson

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// gitError is a git command that failed, with git's own explanation. cut marks a call to GitHub stopped before git finished —
// interrupted, or given up on at the time limit — after which what reached GitHub is unknown.
type gitError struct {
	args    []string
	message string
	cut     bool
}

// wasCut is whether err is a call to GitHub stopped before git finished.
func wasCut(err error) bool {
	var failure *gitError
	return errors.As(err, &failure) && failure.cut
}

func (e *gitError) Error() string {
	return fmt.Sprintf("git %s: %s", strings.Join(e.args, " "), e.message)
}

// reason is what went wrong, in git's words when git said it.
func reason(err error) string {
	var failure *gitError
	if errors.As(err, &failure) {
		return failure.message
	}
	return err.Error()
}

// git runs git in dir and returns its output without the final newline. Leading spaces are kept: `status --porcelain` starts its
// lines with them. git stays in carson's process group, so Ctrl-C stops both.
func git(dir string, args ...string) (string, error) {
	return run(exec.Command("git", append([]string{"-C", dir}, args...)...), args)
}

// networkLimit is how long carson waits for GitHub before saying it gave no answer.
var networkLimit = 30 * time.Second

// gitNetwork runs a git command that reaches GitHub. It runs in a process group of its own, so that at networkLimit — or on Ctrl-C,
// which carson catches for the length of the call — the whole group is stopped: git and every helper it started, none left behind.
// An interrupted call is reported as interrupted; status carries on, but a command that changes things must end its run on it.
func gitNetwork(dir string, args ...string) (string, error) {
	interrupted, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(interrupted, networkLimit)
	defer cancel()
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	out, err := run(command, args)
	switch {
	case err == nil:
		return out, nil
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return out, &gitError{args: args, message: "no answer within " + networkLimit.String(), cut: true}
	case interrupted.Err() != nil:
		return out, &gitError{args: args, message: "interrupted", cut: true}
	default:
		return out, err
	}
}

func run(command *exec.Cmd, args []string) (string, error) {
	// git never asks for a password here: a remote that wants one fails at once instead of waiting for an answer no one will type.
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	// A process git started may keep the output pipes open after git has finished; carson waits a second for it, no longer.
	command.WaitDelay = time.Second
	var out, errs bytes.Buffer
	command.Stdout, command.Stderr = &out, &errs
	err := command.Run()
	// git finished and succeeded while something it started still held the pipes: its answer is complete.
	if errors.Is(err, exec.ErrWaitDelay) && command.ProcessState != nil && command.ProcessState.Success() {
		err = nil
	}
	if err != nil {
		message := explanation(errs.String())
		if message == "" {
			message = err.Error()
		}
		return strings.TrimRight(out.String(), "\n"), &gitError{args: args, message: message}
	}
	return strings.TrimRight(out.String(), "\n"), nil
}

// explanation is the line of git's error output that says what went wrong: the first that is an error, a fatal one, or a refusal
// ("! [rejected]"), before any line naming the remote or hinting; else the first line.
func explanation(stderr string) string {
	for _, line := range strings.Split(stderr, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "error:") || strings.HasPrefix(line, "fatal:") || strings.HasPrefix(line, "!") {
			return line
		}
	}
	return firstLine(stderr)
}

func firstLine(text string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(text), "\n")
	return strings.TrimSpace(line)
}

// lines splits git's output into its lines; no output is no lines.
func lines(output string) []string {
	if output == "" {
		return nil
	}
	return strings.Split(output, "\n")
}
