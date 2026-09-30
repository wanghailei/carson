package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

// A task's name is lowercase words joined by hyphens; it names the branch and the worktree.
var taskNamePattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// start starts a task: from the latest main, in a worktree of its own beside the repository, owned by the session running carson.
// Every refusal comes before any change, and it removes nothing, ever.
func start(m Machine, args []string) int {
	name, err := oneTask(args, "carson start")
	if err == nil {
		err = newTaskName(name)
	}
	if err != nil {
		fmt.Fprintln(m.Out, "Not started: "+err.Error())
		return codeOf(err)
	}
	folder, repo, err := m.prepare(name)
	if err != nil {
		fmt.Fprintln(m.Out, "Not started: "+err.Error())
		return codeOf(err)
	}
	notes, err := repo.latestMain(name)
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
		err = createOwner(admin, record)
	}
	if errors.Is(err, errOwned) {
		taken := repo.heldBy(m, name, task{worktree: worktree{path: folder, branch: name}, admin: admin}, "was taken meanwhile by")
		fmt.Fprintln(m.Out, "Not started: "+taken.Error())
		return codeOf(taken)
	}
	if err != nil {
		fmt.Fprintf(m.Out, "Started %s in %s, but its owner record could not be written (%s), so it shows as made outside carson; "+settled+".\n", name, folder, reason(err))
		return failed
	}
	head, err := git(folder, "rev-parse", "--short", "HEAD")
	if err != nil {
		head = "a commit git could not name (" + reason(err) + ")"
	}
	line := fmt.Sprintf("Started %s from local main at %s in %s, owned by %s", name, head, folder, ownerName(record))
	if added != nil {
		fmt.Fprintf(m.Out, "%s, but git reported a failure after making it (%s). The task is yours; look at its worktree before working there.\n", line, reason(added))
	} else {
		fmt.Fprintln(m.Out, line+".")
	}
	if unobserved != "" {
		fmt.Fprintln(m.Out, unobserved)
	}
	if repo.hasBranch("abandoned/" + name) {
		fmt.Fprintf(m.Out, "Earlier work on %s, declared abandoned, is kept as branch abandoned/%s; this task starts afresh from main.\n", name, name)
	}
	if added != nil {
		return failed
	}
	return done
}

// prepare finds the repository and checks the task can start there: a home for its worktree, a main to start from, a free name, and
// no folder in the way. It changes nothing.
func (m Machine) prepare(name string) (string, *repository, error) {
	home := m.Env("HOME")
	if home == "" {
		return "", nil, refuse(failed, "HOME is not set, so there is no ~/.worktrees to start the task in. Nothing was changed; set HOME to your home folder, then run carson start %s again.", name)
	}
	repo, err := openRepository(m.Dir)
	if errors.Is(err, errNotARepository) {
		return "", nil, refuse(failed, notARepository, m.Dir)
	}
	if err != nil {
		return "", nil, refuse(failed, unreadableRepository, reason(err))
	}
	if missing := repo.mainMissing(); missing != "" {
		return "", nil, refuse(failed, "%s. Nothing was changed.", missing)
	}
	if remotes, err := git(repo.top, "remote"); err == nil && slices.Contains(lines(remotes), name) {
		return "", nil, refuse(refused, "%s is a remote's name, not a task's: git could not tell the two apart. Choose another name.", name)
	}
	if err := repo.nameTaken(m, name); err != nil {
		return "", nil, err
	}
	folder := repo.taskFolder(filepath.Clean(home), name)
	if _, err := os.Lstat(folder); err == nil {
		return "", nil, refuse(refused, "%s already exists, and is not a worktree of this task. Nothing was changed; move that folder out of the way, or choose another name.", folder)
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
	if twin := r.caseTwin(name); twin != "" {
		return refuse(refused, "branch %s exists, and differs from %s only in case, which git cannot always tell apart; choose another name.", twin, name)
	}
	if !r.hasBranch(name) {
		return nil
	}
	ahead, err := r.count("main.." + name)
	switch {
	case err != nil:
		return refuse(refused, "branch %s already exists; what it holds against main is unknown (%s). Run carson start %s again once that is cleared, or choose another name.", name, reason(err), name)
	case ahead == 0:
		return refuse(refused, "branch %s already exists, and its work is on main. Remove it with: carson remove %s", name, name)
	default:
		return refuse(refused, "branch %s already exists, with %s not on main. Adopt it with: carson adopt %s", name, plural(ahead, "commit"), name)
	}
}

// heldBy says who holds the task's worktree, and whether that owner is live.
func (r *repository) heldBy(m Machine, name string, t task, held string) error {
	record, found, err := readOwner(t.admin)
	if t.admin == "" || err != nil || !found {
		return refuse(refused, "%s %s a worktree made outside carson, at %s, whose owner cannot be told. Choose another name.", name, held, t.path)
	}
	state, why := m.livenessOf(record)
	switch state {
	case live:
		if held == "is held by" {
			held = "is taken by"
		}
		if me, _ := m.ownerRecord(name); sameOwner(record, me) {
			return r.yours(name, t.path, record)
		}
		return refuse(refused, "%s %s %s, which is live; its worktree is at %s. Choose another name.", name, held, ownerName(record), t.path)
	case ended:
		return refuse(refused, "%s %s %s, which has ended. Adopt it with: carson adopt %s", name, held, ownerName(record), name)
	default:
		return refuse(refused, "%s %s %s, whose state is unknown (%s). Choose another name; if that session is gone, a person must settle it.", name, held, ownerName(record), why)
	}
}

// afterFailedAdd looks at what git worktree add left when it failed. nil means the worktree carson asked for is there — git failed
// after making it — and carson owns it; otherwise the error says what is there instead.
func (r *repository) afterFailedAdd(m Machine, name, folder string, cause error) error {
	now, err := openRepository(r.top)
	if err != nil {
		return refuse(failed, "the worktree could not be made (%s), and what git left cannot be read (%s). Run carson status to see what is there before trying again.", reason(cause), reason(err))
	}
	for _, t := range now.tasks() {
		if t.branch != name {
			continue
		}
		// The folder is where carson asked git to make the worktree; if it holds a record, another session made it first.
		if t.path == folder {
			if _, found, _ := readOwner(t.admin); found {
				return now.heldBy(m, name, t, "was taken meanwhile by")
			}
			// git refused the branch because it already existed: git made nothing for this session, so the worktree is another's.
			if cause := reason(cause); strings.Contains(cause, "already exists") || strings.Contains(cause, "cannot lock ref") {
				return refuse(refused, "%s was taken meanwhile by a session that has not recorded itself yet, at %s. Choose another name.", name, folder)
			}
			return nil
		}
		return now.heldBy(m, name, t, "was taken meanwhile by")
	}
	if r.hasBranch(name) {
		return refuse(failed, "the worktree could not be made (%s). Branch %s exists now, with no worktree; adopt it with carson adopt %s once that is cleared.", reason(cause), name, name)
	}
	return refuse(failed, "the worktree could not be made (%s). No branch or worktree was made; run carson start %s again once that is cleared.", reason(cause), name)
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

// latestMain brings local main to the latest main before a task starts from it. Landed work GitHub lacks is pushed; GitHub's commits
// come into local main by fast-forward in the main working tree, never over what that tree holds; a divergence is reported, for the
// task's merge to bring in. It returns what it did, and the refusal when the task cannot start; name is the task's, for the way on.
func (r *repository) latestMain(name string) ([]string, error) {
	if r.remote == "" {
		return []string{"No GitHub remote: the task starts from local main."}, nil
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return nil, refuse(failed, "GitHub could not be reached (%s): the latest main cannot be known. Nothing was changed; run carson start %s again when GitHub answers.", reason(err), name)
	}
	if answer == "" {
		now, err := r.pushMain()
		var unchecked pushedUnchecked
		if errors.As(err, &unchecked) {
			return nil, refuse(failed, "GitHub had no main; local main was pushed, but %s. Nothing else was changed; run carson start %s again to check it.", unchecked.why, name)
		}
		if err != nil {
			return nil, refuse(failed, "GitHub has no main, and pushing local main there failed (%s). Nothing else was changed; run carson start %s again once that is cleared.", reason(err), name)
		}
		return []string{"GitHub had no main; local main is pushed there, and GitHub's main is now " + now + "."}, nil
	}
	tracking, err := r.fetchMain()
	if err != nil {
		return nil, refuse(failed, "GitHub's main could not be fetched (%s): the latest main cannot be known. Nothing was changed; run carson start %s again when GitHub answers.", reason(err), name)
	}
	const fetched = "GitHub's main was fetched; nothing else was changed."
	ahead, behind, err := r.aheadBehind(tracking)
	if err != nil {
		return nil, refuse(failed, "how local main stands against GitHub's is unknown (%s). %s Run carson start %s again once that is cleared.", reason(err), fetched, name)
	}
	return r.bringUpToDate(tracking, ahead, behind, fetched, name)
}

func (r *repository) bringUpToDate(tracking string, ahead, behind int, fetched, name string) ([]string, error) {
	switch {
	case ahead > 0 && behind > 0:
		return []string{fmt.Sprintf("Local main and GitHub's have diverged: %s here, %d there. Landing this task will bring GitHub's commits in.", plural(ahead, "commit"), behind)}, nil
	case ahead > 0:
		now, err := r.pushMain()
		var unchecked pushedUnchecked
		if errors.As(err, &unchecked) {
			return nil, refuse(failed, "local main was pushed, but %s. GitHub's main had been fetched first; nothing else was changed. Run carson start %s again to check it.", unchecked.why, name)
		}
		if wasCut(err) {
			return nil, refuse(failed, "local main holds %s GitHub lacked, and whether the push reached GitHub is unknown (%s). GitHub's main had been fetched first; nothing else was changed. Run carson start %s again to push or confirm them.", plural(ahead, "commit"), reason(err), name)
		}
		if err != nil {
			return nil, refuse(failed, "local main holds %s GitHub lacks, and pushing them failed (%s). %s Run carson start %s again to push them.", plural(ahead, "commit"), reason(err), fetched, name)
		}
		return []string{fmt.Sprintf("Pushed %s of local main that GitHub lacked; GitHub's main is now %s.", plural(ahead, "commit"), now)}, nil
	case behind > 0:
		if branch := r.mainTreeBranch(); branch != "main" {
			return nil, refuse(refused, "GitHub's main is %s ahead, and the main working tree is on %s, not main, so local main cannot be brought forward there. %s Switch the main working tree back to main, then run carson start %s again.", plural(behind, "commit"), branch, fetched, name)
		}
		inTheWay, err := r.forwardMain(tracking)
		if len(inTheWay) > 0 {
			return nil, refuse(refused, "bringing local main forward would overwrite what the main working tree holds in %s. carson did not touch them and cannot tell whose they are. %s Ask a person whose they are; once they are out of the main working tree, run carson start %s again.", strings.Join(inTheWay, ", "), fetched, name)
		}
		if err != nil {
			return nil, refuse(failed, "local main could not be brought forward to GitHub's in the main working tree (%s). %s Run carson start %s again once that is cleared.", reason(err), fetched, name)
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
		// A rename or copy is followed by the path it came from, which the working tree no longer holds as main does either.
		if (code[0] == 'R' || code[0] == 'C') && i+1 < len(entries) {
			i++
			kinds[entries[i]] = "modified"
		}
	}
	var found []string
	for _, path := range strings.Split(changed, "\x00") {
		if path == "" {
			continue
		}
		kind := kinds[path]
		for held, heldKind := range kinds {
			// An ignored or untracked folder is listed once, as the folder; and a file may arrive where a folder of files is held.
			if kind == "" && (strings.HasSuffix(held, "/") && strings.HasPrefix(path, held) || strings.HasPrefix(held, path+"/")) {
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

// pushedUnchecked is a push that went through, whose result on GitHub could not be confirmed afterwards.
type pushedUnchecked struct{ why string }

func (e pushedUnchecked) Error() string { return e.why }

// pushMain pushes local main to GitHub and then looks: it returns GitHub's main as observed afterwards, which must be local main.
func (r *repository) pushMain() (string, error) {
	if _, err := gitNetwork(r.top, "push", "-q", r.remote, "main"); err != nil {
		return "", err
	}
	local, _ := git(r.top, "rev-parse", "main")
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return "", pushedUnchecked{"GitHub's main could not be checked afterwards (" + reason(err) + ")"}
	}
	if fields := strings.Fields(answer); len(fields) == 0 || fields[0] != local {
		return "", pushedUnchecked{"GitHub's main is not local main's " + r.short(local) + " afterwards"}
	}
	return r.short(local), nil
}

// ownerRecord is who is running carson, as the harness says: a Claude Code session with its process; a Pi session, whose process is
// the pi above carson; or a terminal, whose process is the shell carson runs in. When that process cannot be observed, the second
// value says so, for the start message.
func (m Machine) ownerRecord(task string) (Record, string) {
	record := Record{Task: task, Machine: m.Host, MachineID: m.ID, Created: time.Now().UTC()}
	claudePID, _ := strconv.Atoi(m.Env("CLAUDE_PID"))
	piPID := 0
	if m.Env("PI_SESSION_ID") != "" {
		piPID = m.ancestor("pi")
	}
	// A harness started inside another inherits the outer one's variables: the harness nearer carson is the one running it.
	inClaude := m.Env("CLAUDE_CODE_SESSION_ID") != ""
	if claude := m.above(claudePID); inClaude && piPID > 0 && (claude == 0 || m.above(piPID) < claude) {
		inClaude = false
	}
	switch {
	case inClaude:
		record.Harness, record.Session = "claude", m.Env("CLAUDE_CODE_SESSION_ID")
		record.PID = claudePID
	case m.Env("PI_SESSION_ID") != "":
		record.Harness, record.Session = "pi", m.Env("PI_SESSION_ID")
		record.PID = piPID
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

// above is how many steps above carson the process pid is, 1 being its parent, or 0 when it is not above carson within reach.
func (m Machine) above(pid int) int {
	current := m.PID
	for step := 1; step <= 16 && pid > 1; step++ {
		parent, _, err := m.Processes.Process(current)
		if err != nil || parent <= 1 {
			return 0
		}
		if parent == pid {
			return step
		}
		current = parent
	}
	return 0
}

// ownerName names a record's owner: "Claude session 4e7a91d2 on this-mac", or "a terminal, process 800, on this-mac".
func ownerName(record Record) string {
	if record.Harness == "terminal" {
		return fmt.Sprintf("a terminal, process %d, on %s", record.PID, record.Machine)
	}
	return fmt.Sprintf("%s session %s on %s", capitalised(record.Harness), shortSession(record.Session), record.Machine)
}

// shortSession is a session identity's first two groups: "9cb74d03-a065". Pi's identities begin with the time, so their first group
// alone is shared by sessions started within a minute of each other.
func shortSession(session string) string {
	if first, rest, found := strings.Cut(session, "-"); found {
		second, _, _ := strings.Cut(rest, "-")
		return first + "-" + second
	}
	return session
}
