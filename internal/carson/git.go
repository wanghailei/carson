package carson

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// gitError is a git command that failed, with git's own first line of explanation.
type gitError struct {
	args    []string
	message string
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
// lines with them.
func git(dir string, args ...string) (string, error) {
	return gitWithin(context.Background(), dir, args...)
}

// networkLimit is how long carson waits for GitHub before saying it gave no answer.
var networkLimit = 30 * time.Second

// gitNetwork runs a git command that reaches GitHub, stopped at networkLimit so a silent host is reported, not waited on.
func gitNetwork(dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), networkLimit)
	defer cancel()
	out, err := gitWithin(ctx, dir, args...)
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return out, &gitError{args: args, message: "no answer within " + networkLimit.String()}
	}
	return out, err
}

func gitWithin(ctx context.Context, dir string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	// git never asks for a password here: a remote that wants one fails at once instead of waiting for an answer no one will type.
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	// git runs in a process group of its own, so stopping it stops its remote helpers too; and a helper still holding the output
	// pipes cannot keep carson waiting past a second.
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error { return syscall.Kill(-command.Process.Pid, syscall.SIGKILL) }
	command.WaitDelay = time.Second
	var out, errs bytes.Buffer
	command.Stdout, command.Stderr = &out, &errs
	if err := command.Run(); err != nil {
		message := firstLine(errs.String())
		if message == "" {
			message = err.Error()
		}
		return strings.TrimRight(out.String(), "\n"), &gitError{args: args, message: message}
	}
	return strings.TrimRight(out.String(), "\n"), nil
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
