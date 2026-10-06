package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// repository is what carson reads of a git repository. Every fact comes from the repository itself: its trunk is main, and its GitHub
// remote is the one main tracks, else its only remote, else the one named github. carson owns no setting.
type repository struct {
	top       string     // the main working tree
	common    string     // git's common folder, which holds each worktree's administrative folder
	remote    string     // GitHub's remote, or "" when there is none
	worktrees []worktree // git's worktree list; the main working tree first
}

var errNotARepository = errors.New("not inside a git repository")

func openRepository(dir string) (*repository, error) {
	common, err := git(dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if err != nil {
		return nil, errNotARepository
	}
	list, err := git(dir, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, err
	}
	worktrees := parseWorktrees(list)
	if len(worktrees) == 0 {
		return nil, errNotARepository
	}
	repo := &repository{top: worktrees[0].path, common: common, worktrees: worktrees}
	if repo.remote, err = repo.githubRemote(); err != nil {
		return nil, err
	}
	return repo, nil
}

func (r *repository) githubRemote() (string, error) {
	if tracked, err := git(r.top, "config", "--get", "branch.main.remote"); err == nil && tracked != "" && tracked != "." {
		return tracked, nil
	}
	remotes, err := git(r.top, "remote")
	if err != nil {
		return "", err
	}
	names := lines(remotes)
	if len(names) == 1 {
		return names[0], nil
	}
	for _, name := range names {
		if name == "github" {
			return name, nil
		}
	}
	return "", nil
}

// short names a commit as git abbreviates it, or by its first seven characters when this machine does not hold it.
func (r *repository) short(commit string) string {
	if abbreviated, err := git(r.top, "rev-parse", "--short", commit); err == nil {
		return abbreviated
	}
	return commit[:min(7, len(commit))]
}

// notOnMain counts the commits at tip that main lacks: every one of them while main has no commit yet.
func (r *repository) notOnMain(tip string) (int, error) {
	if r.noMainYet() {
		return r.count(tip)
	}
	return r.count("main.." + tip)
}

func (r *repository) count(revisions string) (int, error) {
	out, err := git(r.top, "rev-list", "--count", revisions)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

// hasBranch is whether a branch has exactly this name. On a folder that ignores case, git also finds refs/heads/MAIN as the file of
// refs/heads/main, so asking git for the name is not enough: the names it lists are compared.
func (r *repository) hasBranch(name string) bool {
	out, err := git(r.top, "for-each-ref", "--format=%(refname)", "refs/heads/"+name)
	return err == nil && slices.Contains(lines(out), "refs/heads/"+name)
}

// caseTwin is a branch whose name differs from name only in case, or "": on a folder that ignores case, git cannot keep the two apart.
func (r *repository) caseTwin(name string) string {
	out, _ := git(r.top, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
	for _, branch := range lines(out) {
		if branch != name && strings.EqualFold(branch, name) {
			return branch
		}
	}
	return ""
}

// mainMissing says why local main is not there — lost, when this machine knows GitHub's main, or never made — or "" when it is, or is
// still to be made by the first landing.
func (r *repository) mainMissing() string {
	if r.hasBranch("main") || r.noMainYet() {
		return ""
	}
	if r.remote != "" {
		if github, err := git(r.top, "rev-parse", "--verify", "-q", "refs/remotes/"+r.remote+"/main"); err == nil {
			return fmt.Sprintf("local main is missing, though GitHub's main is at %s here; bring it back with: git branch main %s/main", r.short(github), r.remote)
		}
	}
	branch := r.mainTreeBranch()
	if branch == "main" {
		// The main working tree is on main, which had commits, as HEAD's reflog shows; GitHub's main is not known here.
		last := r.short(r.headLastAt())
		return fmt.Sprintf("local main is missing; it was last at %s; bring it back with: git branch main %s", last, last)
	}
	// The main working tree is on the trunk under another name, or off any branch.
	const noMain = "this repository has no main, which carson starts every task from; the main working tree is on "
	if branch != "a detached HEAD" {
		return fmt.Sprintf(noMain+"%s. If %s is its trunk, rename it with: git branch -m %s main", branch, branch, branch)
	}
	return noMain + "a detached HEAD. If its commit is where main belongs, make main there with: git switch -c main"
}

// noMainYet is whether main is still to be made, as in a repository with no commit: the main working tree is on main, which has no
// commit and never had one — HEAD's reflog holds none, unlike a main deleted. The first task then starts empty, and landing it makes
// main; a main GitHub has meanwhile is brought in first.
func (r *repository) noMainYet() bool {
	return !r.hasBranch("main") && r.mainTreeBranch() == "main" && r.headLastAt() == ""
}

// headLastAt is the last commit HEAD's reflog shows the main working tree at, or "" when it shows none. A worktree keeps its own
// reflog, so a task's commits are not in it.
func (r *repository) headLastAt() string {
	path, err := git(r.top, "rev-parse", "--path-format=absolute", "--git-path", "logs/HEAD")
	if err != nil {
		return ""
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	entries := lines(strings.TrimSpace(string(content)))
	if len(entries) == 0 {
		return ""
	}
	// An entry is the old commit, the new one, and who moved it; a deletion moves HEAD to all zeros, from the commit it was last at.
	fields := strings.Fields(entries[len(entries)-1])
	if len(fields) < 2 {
		return ""
	}
	for _, commit := range []string{fields[1], fields[0]} {
		if strings.Trim(commit, "0") != "" {
			return commit
		}
	}
	return ""
}

// firstTask says what becomes of the first task of a repository with no commit yet.
func (r *repository) firstTask() string {
	if r.remote == "" {
		return "The repository has no commit yet, so the task starts empty; landing it makes main."
	}
	return "The repository has no commit yet, so the task starts empty; landing it makes main and pushes it to GitHub."
}

// mainAgainstGitHub says where local main is and how it stands against GitHub's main, asked with ls-remote, which changes nothing here.
func (r *repository) mainAgainstGitHub() string {
	if missing := r.mainMissing(); missing != "" {
		return "main: " + missing + "."
	}
	if r.noMainYet() {
		if r.remote == "" {
			return "main: no commit yet; landing the first task makes it."
		}
		if answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main"); err != nil {
			return fmt.Sprintf("main: no commit yet here. GitHub could not be reached (%s); whether it has a main is unknown.", reason(err))
		} else if fields := strings.Fields(answer); len(fields) == 0 {
			return "main: no commit yet, here or on GitHub; landing the first task makes it and pushes it."
		} else {
			return fmt.Sprintf("main: no commit yet here; GitHub's main is at %s, which the next carson start or carson land brings here.", r.short(fields[0]))
		}
	}
	local, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/main")
	if err != nil {
		return "main: where it is cannot be read (" + reason(err) + ")."
	}
	here := "main: at " + r.short(local)
	if r.remote == "" {
		return here + ". No GitHub remote: main is on this machine only."
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		return fmt.Sprintf("%s. GitHub could not be reached (%s). How main stands against it is unknown.", here, reason(err))
	}
	fields := strings.Fields(answer)
	if len(fields) == 0 {
		return here + ". GitHub has no main yet; carson start or carson land pushes it."
	}
	remote := fields[0]
	if remote == local {
		return here + ", the same as GitHub's."
	}
	if _, err := git(r.top, "cat-file", "-e", remote+"^{commit}"); err != nil {
		return fmt.Sprintf("%s. GitHub's main is at %s, which this machine has not fetched: how far behind, or whether diverged, is unknown. The next carson start or carson land fetches it.", here, r.short(remote))
	}
	ahead, err := r.count(remote + ".." + local)
	if err != nil {
		return fmt.Sprintf("%s. How it stands against GitHub's main, at %s, is unknown (%s).", here, r.short(remote), reason(err))
	}
	behind, err := r.count(local + ".." + remote)
	if err != nil {
		return fmt.Sprintf("%s. How it stands against GitHub's main, at %s, is unknown (%s).", here, r.short(remote), reason(err))
	}
	switch {
	case ahead > 0 && behind > 0:
		return fmt.Sprintf("%s, diverged from GitHub: %s here, %d there. The next carson land brings GitHub's commits in.", here, plural(ahead, "commit"), behind)
	case ahead > 0:
		return fmt.Sprintf("%s, %s ahead of GitHub (landed here, not pushed). The next carson start or carson land pushes it.", here, plural(ahead, "commit"))
	default:
		return fmt.Sprintf("%s, %s behind GitHub. The next carson start or carson land brings it forward.", here, plural(behind, "commit"))
	}
}

// mainTreeBranch is the branch the main working tree has checked out, or "a detached HEAD".
func (r *repository) mainTreeBranch() string {
	branch, err := git(r.top, "symbolic-ref", "--short", "-q", "HEAD")
	if err != nil || branch == "" {
		return "a detached HEAD"
	}
	return branch
}

// fetchMain fetches GitHub's main into its tracking reference, which it returns.
func (r *repository) fetchMain() (string, error) {
	tracking := "refs/remotes/" + r.remote + "/main"
	_, err := gitNetwork(r.top, "fetch", "-q", r.remote, "+refs/heads/main:"+tracking)
	return tracking, err
}

// aheadBehind counts the commits local main has that tracking lacks, and those tracking has that local main lacks.
func (r *repository) aheadBehind(tracking string) (ahead, behind int, err error) {
	// A local main with no commit yet has nothing GitHub lacks, and lacks all GitHub's main holds.
	if !r.hasBranch("main") {
		behind, err = r.count(tracking)
		return 0, behind, err
	}
	if ahead, err = r.count(tracking + "..main"); err != nil {
		return 0, 0, err
	}
	behind, err = r.count("main.." + tracking)
	return ahead, behind, err
}

// ownCommits counts the task's own commits at tip: those main lacks, less merges and less what came from GitHub's main.
func (r *repository) ownCommits(tip string) (int, error) {
	args := []string{"rev-list", "--count", "--no-merges", tip}
	if !r.noMainYet() {
		args = append(args, "^main")
	}
	if r.remote != "" {
		if _, err := git(r.top, "rev-parse", "--verify", "-q", "refs/remotes/"+r.remote+"/main"); err == nil {
			args = append(args, "^refs/remotes/"+r.remote+"/main")
		}
	}
	out, err := git(r.top, args...)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(out)
}

// forwardMain brings local main forward to target by fast-forward in the main working tree, never over what that tree holds: it
// returns the files that would be overwritten, touching nothing, or git's failure.
func (r *repository) forwardMain(target string) (inTheWay []string, err error) {
	if inTheWay, err = r.inTheWay(target); err != nil || len(inTheWay) > 0 {
		return inTheWay, err
	}
	_, err = git(r.top, "merge", "--ff-only", "-q", target)
	return nil, err
}

// changes lists what a working tree holds that its commit does not, each untracked file on its own. It takes no lock, so it never
// rewrites the index under an agent at work there.
func changes(dir string) ([]string, error) {
	out, err := git(dir, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	return lines(out), nil
}

// mainTree says what the main working tree holds: main and nothing else, as rule 11.6 wants, or what is there instead.
func (r *repository) mainTree() string {
	if branch, err := git(r.top, "symbolic-ref", "--short", "-q", "HEAD"); err != nil || branch == "" {
		head, err := git(r.top, "rev-parse", "--short", "HEAD")
		if err != nil {
			return "Main working tree: what it holds cannot be read (" + reason(err) + ")."
		}
		return fmt.Sprintf("Main working tree: on a detached HEAD at %s, not main.", head)
	} else if branch != "main" {
		return fmt.Sprintf("Main working tree: on %s, not main.", branch)
	} else if r.mainMissing() != "" {
		return "Main working tree: on main, which is missing."
	}
	found, err := changes(r.top)
	if err != nil {
		return "Main working tree: on main; its changes cannot be read (" + reason(err) + ")."
	}
	if len(found) == 0 {
		return "Main working tree: on main, clean."
	}
	for i, change := range found {
		found[i] = strings.TrimSpace(change)
	}
	return fmt.Sprintf("Main working tree: on main, with %s: %s.", plural(len(found), "change"), strings.Join(found, ", "))
}

// worktree is one entry of git's worktree list.
type worktree struct {
	path     string
	head     string
	branch   string // "" for a detached HEAD
	prunable string // git's reason when it cannot find the worktree's checkout; "" when it can
	locked   string // git's reason for a lock on the worktree, "no reason given" when it has none; "" when it is not locked
}

// noCommitYet is whether the worktree's branch has no commit yet, as the first task of a repository with no commit has until its work
// is committed: git lists its HEAD as all zeros.
func (w worktree) noCommitYet() bool {
	return w.head != "" && strings.Trim(w.head, "0") == ""
}

// aheadOfMain counts the commits a worktree holds that main lacks: none while its branch has no commit yet.
func (r *repository) aheadOfMain(w worktree) (int, error) {
	if w.noCommitYet() {
		return 0, nil
	}
	tip := w.branch
	if tip == "" {
		tip = w.head
	}
	return r.notOnMain(tip)
}

func parseWorktrees(list string) []worktree {
	var worktrees []worktree
	for _, entry := range strings.Split(list, "\n\n") {
		var w worktree
		for _, line := range lines(strings.TrimSpace(entry)) {
			key, value, _ := strings.Cut(line, " ")
			switch key {
			case "worktree":
				w.path = value
			case "HEAD":
				w.head = value
			case "branch":
				w.branch = strings.TrimPrefix(value, "refs/heads/")
			case "locked":
				w.locked = value
				if w.locked == "" {
					w.locked = "no reason given"
				}
			case "prunable":
				w.prunable = value
				if w.prunable == "" {
					w.prunable = "prunable"
				}
			}
		}
		if w.path != "" {
			worktrees = append(worktrees, w)
		}
	}
	return worktrees
}

// task is a worktree other than the main working tree, with git's administrative folder for it — "" if git keeps none that points
// back to it.
type task struct {
	worktree
	admin string
}

// tasks finds each worktree's administrative folder through the gitdir file git keeps there, since a worktree whose folder is gone
// cannot be asked; the file's path may be relative to that folder.
func (r *repository) tasks() []task {
	admins := map[string]string{}
	entries, _ := os.ReadDir(filepath.Join(r.common, "worktrees"))
	for _, entry := range entries {
		admin := filepath.Join(r.common, "worktrees", entry.Name())
		content, err := os.ReadFile(filepath.Join(admin, "gitdir"))
		if err != nil {
			continue
		}
		gitdir := strings.TrimSpace(string(content))
		if !filepath.IsAbs(gitdir) {
			gitdir = filepath.Join(admin, gitdir)
		}
		admins[filepath.Dir(filepath.Clean(gitdir))] = admin
	}
	var tasks []task
	for _, w := range r.worktrees[1:] {
		tasks = append(tasks, task{worktree: w, admin: admins[w.path]})
	}
	return tasks
}

// state says what a task's worktree holds against main, or that it cannot be told.
func (r *repository) state(t task) string {
	if _, err := os.Stat(t.path); errors.Is(err, fs.ErrNotExist) {
		if t.branch == "" {
			return "its folder is gone."
		}
		ahead, err := r.aheadOfMain(t.worktree)
		if err != nil {
			return fmt.Sprintf("its folder is gone; what branch %s holds against main is unknown (%s).", t.branch, reason(err))
		}
		return fmt.Sprintf("its folder is gone; branch %s holds %s not on main.", t.branch, plural(ahead, "commit"))
	}
	if t.prunable != "" {
		return fmt.Sprintf("git cannot find its checkout (%s); what the folder holds is unknown.", t.prunable)
	}
	ahead, err := r.aheadOfMain(t.worktree)
	if err != nil {
		return "state unknown (" + reason(err) + ")."
	}
	found, err := changes(t.path)
	if err != nil {
		return "state unknown (" + reason(err) + ")."
	}
	if ahead == 0 && len(found) == 0 {
		if record, owned, _ := readOwner(t.admin); t.admin != "" && owned && record.Landed != "" {
			return "landed and clean."
		}
		return "clean, nothing main lacks."
	}
	var parts []string
	if ahead > 0 {
		parts = append(parts, plural(ahead, "commit")+" not on main")
	}
	if len(found) > 0 {
		parts = append(parts, plural(len(found), "uncommitted file"))
	}
	return "working, " + strings.Join(parts, ", ") + "."
}

// isOrAre is the verb a count takes: 1 file is, 2 files are.
func isOrAre(n int) string {
	if n == 1 {
		return "is"
	}
	return "are"
}

// plural writes a count with its noun: 1 commit, 2 commits.
func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(n) + " " + noun + "s"
}
