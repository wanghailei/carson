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
// Every refusal comes before any change, and it removes nothing, ever.
func start(m Machine, args []string) int {
	name, err := taskArgument(args)
	if err != nil {
		fmt.Fprintln(m.Out, err)
		return codeOf(err)
	}
	folder, repo, err := m.prepare(name)
	if err != nil {
		fmt.Fprintln(m.Out, "Not started: "+err.Error())
		return codeOf(err)
	}
	notes, err := repo.latestMain()
	for _, note := range notes {
		fmt.Fprintln(m.Out, note)
	}
	if err != nil {
		fmt.Fprintln(m.Out, "Not started: "+err.Error())
		return codeOf(err)
	}
	_, added := git(repo.top, "worktree", "add", "-q", "-b", name, folder, "main")
	if added != nil {
		// git failed; what it made, if anything, is looked at rather than guessed.
		if err := repo.afterFailedAdd(m, name, folder, added); err != nil {
			fmt.Fprintln(m.Out, "Not started: "+err.Error())
			return codeOf(err)
		}
	}
	record, unobserved := m.ownerRecord(name)
	admin, err := git(folder, "rev-parse", "--absolute-git-dir")
	if err == nil {
		err = writeOwner(admin, record)
	}
	if err != nil {
		fmt.Fprintf(m.Out, "Started %s in %s, but its owner record could not be written (%s): it shows as made outside carson until that is put right.\n", name, folder, reason(err))
		return failed
	}
	head, err := git(folder, "rev-parse", "--short", "HEAD")
	if err != nil {
		head = "a commit git could not name (" + reason(err) + ")"
	}
	line := fmt.Sprintf("Started %s from local main at %s in %s, owned by %s", name, head, folder, ownerName(record))
	if added != nil {
		fmt.Fprintf(m.Out, "%s, but git reported a failure after making it (%s).\n", line, reason(added))
	} else {
		fmt.Fprintln(m.Out, line+".")
	}
	if unobserved != "" {
		fmt.Fprintln(m.Out, unobserved)
	}
	if added != nil {
		return failed
	}
	return done
}

// taskArgument reads carson start's arguments: one task name, lowercase words joined by hyphens, and not a trunk's.
func taskArgument(args []string) (string, error) {
	var name string
	for _, arg := range args {
		switch {
		case arg == "--existing":
			return "", refuse(failed, "carson start --existing: not built yet. Nothing was changed.")
		case strings.HasPrefix(arg, "-"):
			return "", refuse(refused, "Not started: carson start has no option %q.", arg)
		case name != "":
			return "", refuse(refused, "Not started: one task at a time; %q and %q were given.", name, arg)
		default:
			name = arg
		}
	}
	switch {
	case name == "":
		return "", refuse(refused, "Not started: name the task, as in carson start fix-login.")
	case name == "main" || name == "master":
		return "", refuse(refused, "Not started: %s is a trunk's name, not a task's.", name)
	case !taskNamePattern.MatchString(name):
		return "", refuse(refused, "Not started: %q is not a task name: use lowercase words joined by hyphens, like fix-login.", name)
	}
	return name, nil
}

// prepare finds the repository and checks the task can start there: a home for its worktree, a main to start from, a free name, and
// no folder in the way. It changes nothing.
func (m Machine) prepare(name string) (string, *repository, error) {
	home := m.Env("HOME")
	if home == "" {
		return "", nil, refuse(failed, "HOME is not set, so there is no ~/.worktrees to start the task in.")
	}
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		return "", nil, refuse(failed, "%s is not inside a git repository.", m.Dir)
	}
	if err != nil {
		return "", nil, refuse(failed, "the repository could not be read (%s).", reason(err))
	}
	if _, err := git(repo.top, "rev-parse", "--verify", "-q", "refs/heads/main"); err != nil {
		return "", nil, refuse(failed, "this repository has no main yet; starting its first task is not built yet. Nothing was changed.")
	}
	if err := repo.nameTaken(m, name); err != nil {
		return "", nil, err
	}
	folder := repo.taskFolder(filepath.Clean(home), name)
	if _, err := os.Lstat(folder); err == nil {
		return "", nil, refuse(refused, "%s already exists, and is not a worktree of this task. Nothing was changed.", folder)
	}
	return folder, repo, nil
}

// nameTaken says why a task name is not free — a worktree holds its branch, or the branch exists — or nil when it is free.
func (r *repository) nameTaken(m Machine, name string) error {
	for _, t := range r.tasks() {
		if t.branch == name {
			return r.heldBy(m, name, t, "is held by")
		}
	}
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err != nil {
		return nil
	}
	ahead, err := r.count("main.." + name)
	switch {
	case err != nil:
		return refuse(refused, "branch %s already exists; what it holds against main is unknown (%s).", name, reason(err))
	case ahead == 0:
		return refuse(refused, "branch %s already exists, and its work is on main. Remove it with: carson remove %s", name, name)
	default:
		return refuse(refused, "branch %s already exists, with %s not on main. Taking it up again (carson start %s --existing) is not built yet.", name, plural(ahead, "commit"), name)
	}
}

// heldBy says who holds the task's worktree, and whether that owner is live.
func (r *repository) heldBy(m Machine, name string, t task, held string) error {
	record, found, err := readOwner(t.admin)
	if t.admin == "" || err != nil || !found {
		return refuse(refused, "%s %s a worktree made outside carson, at %s; whose it is is the master's to settle.", name, held, t.path)
	}
	state, why := m.livenessOf(record)
	switch state {
	case live:
		if held == "is held by" {
			held = "is taken by"
		}
		return refuse(refused, "%s %s %s, which is live.", name, held, ownerName(record))
	case ended:
		return refuse(refused, "%s %s %s, which has ended. Taking it over (carson start %s --existing) is not built yet.", name, held, ownerName(record), name)
	default:
		return refuse(refused, "%s %s %s, whose state is unknown (%s).", name, held, ownerName(record), why)
	}
}

// afterFailedAdd looks at what git worktree add left when it failed. nil means the worktree carson asked for is there — git failed
// after making it — and carson owns it; otherwise the error says what is there instead.
func (r *repository) afterFailedAdd(m Machine, name, folder string, cause error) error {
	now, err := openRepository(r.top)
	if err != nil {
		return refuse(failed, "the worktree could not be made (%s), and what git left cannot be read (%s).", reason(cause), reason(err))
	}
	for _, t := range now.tasks() {
		if t.branch != name {
			continue
		}
		if t.path == folder {
			return nil
		}
		return now.heldBy(m, name, t, "was taken meanwhile by")
	}
	if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/"+name); err == nil {
		return refuse(failed, "the worktree could not be made (%s). Branch %s exists now, with no worktree.", reason(cause), name)
	}
	return refuse(failed, "the worktree could not be made (%s). No branch or worktree was made.", reason(cause))
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
// come into local main by fast-forward in the main working tree, never over what that tree holds; a divergence is reported, for the
// task's merge to bring in. It returns what it did, and the refusal when the task cannot start.
func (r *repository) latestMain() ([]string, error) {
	if r.remote == "" {
		return []string{"No GitHub remote: the task starts from local main."}, nil
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return nil, refuse(failed, "GitHub could not be reached (%s): the latest main cannot be known. Nothing was changed.", reason(err))
	}
	if answer == "" {
		now, err := r.pushMain()
		if err != nil {
			return nil, refuse(failed, "GitHub has no main, and pushing local main there failed (%s). Nothing else was changed.", reason(err))
		}
		return []string{"GitHub had no main; local main is pushed there, and GitHub's main is now " + now + "."}, nil
	}
	tracking := "refs/remotes/" + r.remote + "/main"
	if _, err := gitNetwork(r.top, "fetch", "-q", r.remote, "+refs/heads/main:"+tracking); err != nil {
		return nil, refuse(failed, "GitHub's main could not be fetched (%s): the latest main cannot be known. Nothing was changed.", reason(err))
	}
	const fetched = "GitHub's main was fetched; nothing else was changed."
	ahead, err := r.count(tracking + "..main")
	if err == nil {
		var behind int
		if behind, err = r.count("main.." + tracking); err == nil {
			return r.bringUpToDate(tracking, ahead, behind, fetched)
		}
	}
	return nil, refuse(failed, "how local main stands against GitHub's is unknown (%s). %s", reason(err), fetched)
}

func (r *repository) bringUpToDate(tracking string, ahead, behind int, fetched string) ([]string, error) {
	switch {
	case ahead > 0 && behind > 0:
		return []string{fmt.Sprintf("Local main and GitHub's have diverged: %s here, %d there. Merging this task will bring GitHub's commits in.", plural(ahead, "commit"), behind)}, nil
	case ahead > 0:
		now, err := r.pushMain()
		if err != nil {
			return nil, refuse(failed, "local main holds %s GitHub lacks, and pushing them failed (%s). %s", plural(ahead, "commit"), reason(err), fetched)
		}
		return []string{fmt.Sprintf("Pushed %s of local main that GitHub lacked; GitHub's main is now %s.", plural(ahead, "commit"), now)}, nil
	case behind > 0:
		if branch, _ := git(r.top, "symbolic-ref", "--short", "-q", "HEAD"); branch != "main" {
			if branch == "" {
				branch = "a detached HEAD"
			}
			return nil, refuse(refused, "GitHub's main is %s ahead, and the main working tree is on %s, not main, so local main cannot be brought forward there. %s", plural(behind, "commit"), branch, fetched)
		}
		inTheWay, err := r.inTheWay(tracking)
		if err != nil {
			return nil, refuse(failed, "what the main working tree holds could not be read (%s), so local main is not brought forward over it. %s", reason(err), fetched)
		}
		if len(inTheWay) > 0 {
			return nil, refuse(refused, "bringing local main forward would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s", strings.Join(inTheWay, ", "), fetched)
		}
		if _, err := git(r.top, "merge", "--ff-only", "-q", tracking); err != nil {
			return nil, refuse(refused, "local main could not be brought forward to GitHub's in the main working tree (%s). %s", reason(err), fetched)
		}
		return []string{fmt.Sprintf("Local main was %s behind GitHub's and is brought forward to it.", plural(behind, "commit"))}, nil
	}
	return nil, nil
}

// inTheWay lists what the main working tree holds that bringing main forward to target would overwrite: a file the move changes that
// is modified there, untracked, or ignored — each with its kind and when it last changed.
func (r *repository) inTheWay(target string) ([]string, error) {
	changed, err := git(r.top, "diff", "--name-only", "-z", "main", target)
	if err != nil {
		return nil, err
	}
	held, err := git(r.top, "--no-optional-locks", "status", "--porcelain", "-z", "--ignored=matching", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	kinds := map[string]string{}
	entries := strings.Split(held, "\x00")
	for i := 0; i < len(entries); i++ {
		entry := entries[i]
		if len(entry) < 4 {
			continue
		}
		code, path := entry[:2], entry[3:]
		switch {
		case code == "??":
			kinds[path] = "untracked"
		case code == "!!":
			kinds[path] = "ignored"
		default:
			kinds[path] = "modified"
		}
		if code[0] == 'R' || code[0] == 'C' {
			i++ // a rename or copy is followed by the path it came from
		}
	}
	var found []string
	for _, path := range strings.Split(changed, "\x00") {
		if path == "" {
			continue
		}
		kind := kinds[path]
		for held, heldKind := range kinds {
			// An ignored or untracked folder is listed once, as the folder.
			if kind == "" && strings.HasSuffix(held, "/") && strings.HasPrefix(path, held) {
				kind = heldKind
			}
		}
		if kind == "" {
			continue
		}
		item := path + " (" + kind
		if info, err := os.Stat(filepath.Join(r.top, path)); err == nil {
			item += ", changed " + info.ModTime().Format("15:04")
		}
		found = append(found, item+")")
	}
	return found, nil
}

// pushMain pushes local main to GitHub and then looks: it returns GitHub's main as observed afterwards, which must be local main.
func (r *repository) pushMain() (string, error) {
	if _, err := gitNetwork(r.top, "push", "-q", r.remote, "main"); err != nil {
		return "", err
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return "", fmt.Errorf("pushed, but GitHub could not be asked afterwards: %s", reason(err))
	}
	local, _ := git(r.top, "rev-parse", "main")
	if fields := strings.Fields(answer); len(fields) == 0 || fields[0] != local {
		return "", fmt.Errorf("pushed, but GitHub's main is not local main's %s afterwards", r.short(local))
	}
	return r.short(local), nil
}

// ownerRecord is who is running carson, as the harness says: a Claude Code session with its process; a Pi session, whose process is
// the pi above carson; or a terminal, whose process is the shell carson runs in. When that process cannot be observed, the second
// value says so, for the start message.
func (m Machine) ownerRecord(task string) (Record, string) {
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
	if record.PID <= 0 {
		return record, "No process of its session could be found, so status will show this task's owner as unknown."
	}
	started, err := m.Processes.Started(record.PID)
	if err != nil {
		return record, fmt.Sprintf("Its process, %d, could not be observed (%s), so status will show this task's owner as unknown.", record.PID, err)
	}
	record.Started = started
	return record, ""
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
