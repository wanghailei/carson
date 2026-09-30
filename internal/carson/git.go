package carson

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
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

// git runs git in dir and returns its output without the final newline. Leading spaces are kept: `status --porcelain` starts its
// lines with them.
func git(dir string, args ...string) (string, error) {
	return gitWithin(context.Background(), dir, args...)
}

// gitNetwork runs a git command that reaches GitHub, stopped after a time limit so an unreachable host is reported, not waited on.
func gitNetwork(dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return gitWithin(ctx, dir, args...)
}

func gitWithin(ctx context.Context, dir string, args ...string) (string, error) {
	command := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
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
