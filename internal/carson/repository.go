package carson

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// repository is what carson reads of a git repository. Every fact comes from the repository itself: its trunk is main, and its GitHub
// remote is the one main tracks, else its only remote, else the one named github. carson owns no setting.
type repository struct {
	top    string // the main working tree
	common string // git's common folder, which holds each worktree's administrative folder
	remote string // GitHub's remote, or "" when there is none
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
	repo := &repository{top: worktrees[0].path, common: common}
	repo.remote = repo.githubRemote()
	return repo, nil
}

func (r *repository) githubRemote() string {
	if tracked, err := git(r.top, "config", "--get", "branch.main.remote"); err == nil && tracked != "" && tracked != "." {
		return tracked
	}
	remotes, _ := git(r.top, "remote")
	names := lines(remotes)
	if len(names) == 1 {
		return names[0]
	}
	for _, name := range names {
		if name == "github" {
			return name
		}
	}
	return ""
}

// short names a commit as git abbreviates it, or by its first seven characters when this machine does not hold it.
func (r *repository) short(commit string) string {
	if abbreviated, err := git(r.top, "rev-parse", "--short", commit); err == nil {
		return abbreviated
	}
	return commit[:min(7, len(commit))]
}

func (r *repository) count(revisions string) int {
	out, err := git(r.top, "rev-list", "--count", revisions)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(out)
	return n
}

// mainAgainstGitHub says where local main is and how it stands against GitHub's main, asked with ls-remote, which changes nothing here.
func (r *repository) mainAgainstGitHub() string {
	local, err := git(r.top, "rev-parse", "--verify", "-q", "refs/heads/main")
	if err != nil {
		return "main: this repository has no main yet."
	}
	here := "main: at " + r.short(local)
	if r.remote == "" {
		return here + ". No GitHub remote: main is on this machine only."
	}
	answer, err := gitNetwork(r.top, "ls-remote", r.remote, "refs/heads/main")
	if err != nil {
		var failure *gitError
		reason := err.Error()
		if errors.As(err, &failure) {
			reason = failure.message
		}
		return fmt.Sprintf("%s. GitHub could not be reached (%s). How main stands against it is unknown.", here, reason)
	}
	fields := strings.Fields(answer)
	if len(fields) == 0 {
		return here + ". GitHub has no main yet; the next carson merge pushes it."
	}
	remote := fields[0]
	if remote == local {
		return here + ", the same as GitHub's."
	}
	if _, err := git(r.top, "cat-file", "-e", remote+"^{commit}"); err != nil {
		return fmt.Sprintf("%s. GitHub's main is at %s, which this machine has not fetched: how far behind, or whether diverged, is unknown.", here, r.short(remote))
	}
	ahead, behind := r.count(remote+".."+local), r.count(local+".."+remote)
	switch {
	case ahead > 0 && behind > 0:
		return fmt.Sprintf("%s, diverged from GitHub: %s here, %d there. The next carson merge brings GitHub's commits in.", here, plural(ahead, "commit"), behind)
	case ahead > 0:
		return fmt.Sprintf("%s, %s ahead of GitHub (merged here, not pushed).", here, plural(ahead, "commit"))
	default:
		return fmt.Sprintf("%s, %s behind GitHub.", here, plural(behind, "commit"))
	}
}

// mainTree says what the main working tree holds: main and nothing else, as rule 11.6 wants, or what is there instead.
func (r *repository) mainTree() string {
	branch, _ := git(r.top, "symbolic-ref", "--short", "-q", "HEAD")
	if branch == "" {
		head, _ := git(r.top, "rev-parse", "--short", "HEAD")
		return fmt.Sprintf("Main working tree: on a detached HEAD at %s, not main.", head)
	}
	if branch != "main" {
		return fmt.Sprintf("Main working tree: on %s, not main.", branch)
	}
	out, _ := git(r.top, "status", "--porcelain")
	changes := lines(out)
	if len(changes) == 0 {
		return "Main working tree: on main, clean."
	}
	for i, change := range changes {
		changes[i] = strings.TrimSpace(change)
	}
	return fmt.Sprintf("Main working tree: on main, with %s: %s.", plural(len(changes), "change"), strings.Join(changes, ", "))
}

// worktree is one entry of git's worktree list.
type worktree struct {
	path     string
	head     string
	branch   string // "" for a detached HEAD
	prunable bool   // git knows its folder is gone
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
			case "prunable":
				w.prunable = true
			}
		}
		if w.path != "" {
			worktrees = append(worktrees, w)
		}
	}
	return worktrees
}

// tasks are the worktrees other than the main working tree, each with its administrative folder, found through the gitdir file git
// keeps there, since a worktree whose folder is gone cannot be asked.
func (r *repository) tasks() ([]worktree, map[string]string, error) {
	list, err := git(r.top, "worktree", "list", "--porcelain")
	if err != nil {
		return nil, nil, err
	}
	all := parseWorktrees(list)
	admins := map[string]string{}
	entries, _ := os.ReadDir(filepath.Join(r.common, "worktrees"))
	for _, entry := range entries {
		admin := filepath.Join(r.common, "worktrees", entry.Name())
		gitdir, err := os.ReadFile(filepath.Join(admin, "gitdir"))
		if err == nil {
			admins[filepath.Dir(strings.TrimSpace(string(gitdir)))] = admin
		}
	}
	return all[1:], admins, nil
}

// taskState says what a task's worktree holds against main.
func (r *repository) taskState(w worktree) string {
	tip := w.branch
	if tip == "" {
		tip = w.head
	}
	ahead := r.count("main.." + tip)
	if _, err := os.Stat(w.path); w.prunable || err != nil {
		if w.branch == "" {
			return "its folder is gone."
		}
		return fmt.Sprintf("its folder is gone; branch %s holds %s not on main.", w.branch, plural(ahead, "commit"))
	}
	out, _ := git(w.path, "status", "--porcelain")
	uncommitted := len(lines(out))
	if ahead == 0 && uncommitted == 0 {
		return "merged and clean."
	}
	var parts []string
	if ahead > 0 {
		parts = append(parts, plural(ahead, "commit")+" not on main")
	}
	if uncommitted > 0 {
		parts = append(parts, plural(uncommitted, "uncommitted file"))
	}
	return "working, " + strings.Join(parts, ", ") + "."
}

// plural writes a count with its noun: 1 commit, 2 commits.
func plural(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(n) + " " + noun + "s"
}
