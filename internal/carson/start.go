package carson

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// A task's name is lowercase words joined by hyphens; it names the branch and the worktree.
var taskNamePattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// start starts a task: from the latest main, in a worktree of its own beside the repository, owned by the session running carson.
// It removes nothing, ever.
func start(m Machine, args []string) int {
	var name string
	for _, arg := range args {
		switch {
		case arg == "--existing":
			fmt.Fprintln(m.Out, "carson start --existing: not built yet. Nothing was changed.")
			return failed
		case strings.HasPrefix(arg, "-"):
			fmt.Fprintf(m.Out, "Not started: carson start has no option %q.\n", arg)
			return refused
		case name != "":
			fmt.Fprintf(m.Out, "Not started: one task at a time; %q and %q were given.\n", name, arg)
			return refused
		default:
			name = arg
		}
	}
	if name == "" {
		fmt.Fprintln(m.Out, "Not started: name the task, as in carson start fix-login.")
		return refused
	}
	if !taskNamePattern.MatchString(name) {
		fmt.Fprintf(m.Out, "Not started: %q is not a task name: use lowercase words joined by hyphens, like fix-login.\n", name)
		return refused
	}
	home := m.Env("HOME")
	if home == "" {
		fmt.Fprintln(m.Out, "Not started: HOME is not set, so there is no ~/.worktrees to start the task in.")
		return failed
	}
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		fmt.Fprintf(m.Out, "Not started: %s is not inside a git repository.\n", m.Dir)
		return failed
	}
	if err != nil {
		fmt.Fprintf(m.Out, "Not started: the repository could not be read (%s).\n", reason(err))
		return failed
	}
	if _, err := git(repo.top, "rev-parse", "--verify", "-q", "refs/heads/main"); err != nil {
		fmt.Fprintln(m.Out, "Not started: this repository has no main yet; starting its first task is not built yet. Nothing was changed.")
		return failed
	}
	if refusal := repo.nameTaken(m, name); refusal != "" {
		fmt.Fprintln(m.Out, "Not started: "+refusal)
		return refused
	}
	folder := repo.taskFolder(home, name)
	if _, err := os.Lstat(folder); err == nil {
		fmt.Fprintf(m.Out, "Not started: %s already exists, and is not a worktree of this task. Nothing was changed.\n", folder)
		return refused
	}
	notes, refusal, code := repo.latestMain()
	if refusal != "" {
		fmt.Fprintln(m.Out, "Not started: "+refusal)
		return code
	}
	for _, note := range notes {
		fmt.Fprintln(m.Out, note)
	}
	if err := os.MkdirAll(filepath.Dir(folder), 0o755); err != nil {
		fmt.Fprintf(m.Out, "Not started: the folder for its worktree could not be made (%v). Nothing else was changed.\n", err)
		return failed
	}
	if _, err := git(repo.top, "worktree", "add", "-q", "-b", name, folder, "main"); err != nil {
		made := ""
		if _, err := git(repo.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err == nil {
			made = fmt.Sprintf(" Branch %s was made; its worktree was not.", name)
		}
		fmt.Fprintf(m.Out, "Not started: the worktree could not be made (%s).%s\n", reason(err), made)
		return failed
	}
	record := m.ownerRecord(name)
	admin, err := git(folder, "rev-parse", "--absolute-git-dir")
	if err == nil {
		err = writeOwner(admin, record)
	}
	if err != nil {
		fmt.Fprintf(m.Out, "Started %s in %s, but its owner record could not be written (%s): it shows as made outside carson until that is put right.\n", name, folder, reason(err))
		return failed
	}
	head, _ := git(folder, "rev-parse", "--short", "HEAD")
	fmt.Fprintf(m.Out, "Started %s from main at %s in %s, owned by %s.\n", name, head, folder, ownerName(record))
	return done
}

// nameTaken says why a task name is not free — a worktree holds its branch, or the branch exists — or "" when it is free.
func (r *repository) nameTaken(m Machine, name string) string {
	for _, t := range r.tasks() {
		if t.branch != name {
			continue
		}
		record, found, err := readOwner(t.admin)
		switch {
		case t.admin == "" || err != nil || !found:
			return fmt.Sprintf("%s is held by a worktree made outside carson, at %s; whose it is is the master's to settle.", name, t.path)
		}
		state, why := m.livenessOf(record)
		switch state {
		case live:
			return fmt.Sprintf("%s is taken by %s, which is live.", name, ownerName(record))
		case ended:
			return fmt.Sprintf("%s is held by %s, which has ended. Taking it over (carson start %s --existing) is not built yet.", name, ownerName(record), name)
		default:
			return fmt.Sprintf("%s is held by %s, whose state is unknown (%s).", name, ownerName(record), why)
		}
	}
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err != nil {
		return ""
	}
	ahead, err := r.count("main.." + name)
	switch {
	case err != nil:
		return fmt.Sprintf("branch %s already exists; what it holds against main is unknown (%s).", name, reason(err))
	case ahead == 0:
		return fmt.Sprintf("branch %s already exists, and its work is on main. Remove it with: carson remove %s", name, name)
	default:
		return fmt.Sprintf("branch %s already exists, with %s not on main. Taking it up again (carson start %s --existing) is not built yet.", name, plural(ahead, "commit"), name)
	}
}

// taskFolder is where a task's worktree goes: under ~/.worktrees, mirroring the repository's place, so never inside the main working
// tree, which holds main and nothing else (rule 11.6).
func (r *repository) taskFolder(home, task string) string {
	place := strings.TrimPrefix(r.top, "/")
	if strings.HasPrefix(r.top, home+"/") {
		place = strings.TrimPrefix(r.top, home+"/")
	}
	return filepath.Join(home, ".worktrees", place, task)
}

// latestMain brings local main to the latest main before a task starts from it. Merged work GitHub lacks is pushed; GitHub's commits
// come into local main by fast-forward in the main working tree; a divergence is reported, for the task's merge to bring in. It
// returns what it did, or why the task cannot start, with the exit code for that.
func (r *repository) latestMain() (notes []string, refusal string, code int) {
	if r.remote == "" {
		return []string{"No GitHub remote: the task starts from local main."}, "", done
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return nil, fmt.Sprintf("GitHub could not be reached (%s): the latest main cannot be known. Nothing was changed.", reason(err)), failed
	}
	if answer == "" {
		if _, err := gitNetwork(r.top, "push", "-q", r.remote, "main"); err != nil {
			return nil, fmt.Sprintf("GitHub has no main, and pushing local main there failed (%s). Nothing else was changed.", reason(err)), failed
		}
		return []string{"GitHub had no main; local main is pushed there."}, "", done
	}
	tracking := "refs/remotes/" + r.remote + "/main"
	if _, err := gitNetwork(r.top, "fetch", "-q", r.remote, "+refs/heads/main:"+tracking); err != nil {
		return nil, fmt.Sprintf("GitHub's main could not be fetched (%s): the latest main cannot be known. Nothing was changed.", reason(err)), failed
	}
	ahead, err := r.count(tracking + "..main")
	if err != nil {
		return nil, fmt.Sprintf("how local main stands against GitHub's is unknown (%s). Nothing was changed.", reason(err)), failed
	}
	behind, err := r.count("main.." + tracking)
	if err != nil {
		return nil, fmt.Sprintf("how local main stands against GitHub's is unknown (%s). Nothing was changed.", reason(err)), failed
	}
	switch {
	case ahead > 0 && behind > 0:
		return []string{fmt.Sprintf("Local main and GitHub's have diverged: %s here, %d there. Merging this task will bring GitHub's commits in.", plural(ahead, "commit"), behind)}, "", done
	case ahead > 0:
		if _, err := gitNetwork(r.top, "push", "-q", r.remote, "main"); err != nil {
			return nil, fmt.Sprintf("local main holds %s GitHub lacks, and pushing them failed (%s). Nothing else was changed.", plural(ahead, "commit"), reason(err)), failed
		}
		return []string{fmt.Sprintf("Pushed %s of local main that GitHub lacked.", plural(ahead, "commit"))}, "", done
	case behind > 0:
		branch, _ := git(r.top, "symbolic-ref", "--short", "-q", "HEAD")
		if branch != "main" {
			if branch == "" {
				branch = "a detached HEAD"
			}
			return nil, fmt.Sprintf("GitHub's main is %s ahead, and the main working tree is on %s, not main, so local main cannot be brought forward there. Nothing was changed.", plural(behind, "commit"), branch), refused
		}
		if _, err := git(r.top, "merge", "--ff-only", "-q", tracking); err != nil {
			return nil, fmt.Sprintf("local main could not be brought forward to GitHub's in the main working tree (%s). Nothing was changed.", reason(err)), refused
		}
		return []string{fmt.Sprintf("Local main was %s behind GitHub's and is brought forward to it.", plural(behind, "commit"))}, "", done
	}
	return nil, "", done
}

// ownerRecord is who is running carson, as the harness says: a Claude Code session with its process; a Pi session, whose process is
// the pi above carson; or a terminal, whose process is the shell carson runs in.
func (m Machine) ownerRecord(task string) Record {
	record := Record{Task: task, Machine: m.Host, MachineID: m.ID, Created: time.Now().UTC()}
	switch {
	case m.Env("CLAUDE_CODE_SESSION_ID") != "":
		record.Harness, record.Session = "claude", m.Env("CLAUDE_CODE_SESSION_ID")
		record.PID, _ = strconv.Atoi(m.Env("CLAUDE_PID"))
	case m.Env("PI_SESSION_ID") != "":
		record.Harness, record.Session = "pi", m.Env("PI_SESSION_ID")
		record.PID = m.ancestor("pi")
	default:
		record.Harness = "terminal"
		record.PID, _, _ = m.Processes.Process(m.PID)
	}
	if record.PID > 0 {
		record.Started, _ = m.Processes.Started(record.PID)
	}
	return record
}

// ancestor is the nearest process above carson running the command named, or 0 when there is none within reach.
func (m Machine) ancestor(command string) int {
	pid := m.PID
	for step := 0; step < 16; step++ {
		parent, _, err := m.Processes.Process(pid)
		if err != nil || parent <= 1 {
			return 0
		}
		if _, name, err := m.Processes.Process(parent); err == nil && name == command {
			return parent
		}
		pid = parent
	}
	return 0
}

// ownerName names a record's owner: "Claude session 4e7a91d2 on this-mac", or "a terminal, process 800, on this-mac".
func ownerName(record Record) string {
	if record.Harness == "terminal" {
		return fmt.Sprintf("a terminal, process %d, on %s", record.PID, record.Machine)
	}
	session, _, _ := strings.Cut(record.Session, "-")
	return fmt.Sprintf("%s session %s on %s", capitalised(record.Harness), session, record.Machine)
}
