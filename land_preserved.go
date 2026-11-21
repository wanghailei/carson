package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// forwardPreserved runs under the landing lock, after the task has been brought
// up to main. The preservation commit describes the precise contents approved
// to leave the working tree. Ordinary land never takes this path.
func (r *repository) forwardPreserved(target, snapshot string) error {
	base, err := git(r.top, "rev-parse", "refs/heads/main")
	if err != nil {
		return err
	}
	if r.mainTreeBranch() != "main" {
		return refuse(refused, "the main working tree is no longer on main")
	}
	if _, err := git(r.top, "merge-base", "--is-ancestor", base, target); err != nil {
		return refuse(refused, "the approved commit no longer fast-forwards main")
	}
	index, err := r.indexChanges(base)
	if err != nil {
		return err
	}
	if len(index) != 0 {
		return refuse(refused, "the main index already has staged changes")
	}
	paths, err := r.preservedPaths(base, target, snapshot)
	if err != nil {
		return err
	}
	if err := r.checkPreservedFiles(snapshot, paths); err != nil {
		return err
	}
	patch, err := r.preservedPatch(snapshot, target, paths)
	if err != nil {
		return err
	}
	if err := r.checkPreservedTarget(target, paths); err != nil {
		return err
	}
	if now, err := git(r.top, "rev-parse", "HEAD"); err != nil || now != base {
		return refuse(refused, "main moved since the preservation commit was checked")
	}
	if _, err := git(r.top, append([]string{"--literal-pathspecs", "add", "--no-ignore-errors", "--"}, paths...)...); err != nil {
		return fmt.Errorf("could not stage the preserved files (%s); check the main index before retrying", reason(err))
	}
	if err := r.checkPreservedIndex(base, snapshot, paths); err != nil {
		return err
	}
	// A path identical in the two commits has no patch, so its live file
	// stays exactly where it is. Only Git's index records that it is ready.
	if patch != "" {
		if _, err := gitWithInput(r.top, patch+"\n", "apply", "--index", "--whitespace=nowarn"); err != nil {
			return r.undoPreservedForward(base, snapshot, target, patch, paths, false, err)
		}
	}
	if err := r.checkPreservedIndex(base, target, paths); err != nil {
		return err
	}
	if err := r.checkPreservedFiles(target, paths); err != nil {
		return fmt.Errorf("%w; check the main working tree and index before retrying", err)
	}
	if now, err := git(r.top, "rev-parse", "HEAD"); err != nil || now != base {
		return refuse(refused, "main moved while staging the approved changes; check its index before retrying")
	}
	if _, err := git(r.top, "merge", "--ff-only", "--no-overwrite-ignore", "-q", target); err != nil {
		return r.undoPreservedForward(base, snapshot, target, patch, paths, true, err)
	}
	return nil
}

// preservedPatch uses Git's ordinary patch format, irrespective of display
// preferences such as colour, mnemonic prefixes or a diff driver.
func (r *repository) preservedPatch(snapshot, target string, paths []string) (string, error) {
	args := []string{"--literal-pathspecs", "diff", "--binary", "--full-index", "--no-renames",
		"--no-ext-diff", "--no-textconv", "--no-relative", "--color=never", "--unified=3",
		"--src-prefix=a/", "--dst-prefix=b/", snapshot, target, "--"}
	return git(r.top, append(args, paths...)...)
}

// preservedPaths ties the supplied commit to this repository's history and
// requires its changed paths to be exactly the files in the way of landing.
func (r *repository) preservedPaths(base, target, snapshot string) ([]string, error) {
	line, err := git(r.top, "rev-list", "--parents", "-1", "--end-of-options", snapshot)
	fields := strings.Fields(line)
	if err != nil || len(fields) != 2 || fields[0] != snapshot {
		return nil, refuse(refused, "give the full object ID of a preservation commit with one parent")
	}
	if _, err := git(r.top, "merge-base", "--is-ancestor", fields[1], base); err != nil {
		return nil, refuse(refused, "the preservation commit was not made from this main's history")
	}
	preserved, err := r.landingChanges(fields[1], snapshot)
	if err != nil {
		return nil, err
	}
	if len(preserved) == 0 {
		return nil, refuse(refused, "no local changes need a preservation commit; land the task normally")
	}
	advanced, err := r.landingChanges(fields[1], base, preserved...)
	if err != nil {
		return nil, err
	}
	if len(advanced) != 0 {
		return nil, refuse(refused, "%q changed on main since the preservation commit's base", advanced[0])
	}
	incoming, err := r.landingChanges(base, target)
	if err != nil {
		return nil, err
	}
	overlap, err := r.preservedOverlaps(incoming)
	if err != nil {
		return nil, err
	}
	for _, path := range overlap {
		if !containsPath(preserved, path) {
			return nil, refuse(refused, "%q is in the way of landing and is outside the approved preservation commit", path)
		}
	}
	for _, path := range preserved {
		if !containsPath(overlap, path) {
			return nil, refuse(refused, "%q is in the preservation commit but is not in the way of landing", path)
		}
	}
	return preserved, nil
}

// preservedOverlaps uses Git's porcelain paths, including ignored paths and
// both ends of structural file/directory collisions. Renames are separate
// old and new paths so there is exactly one path per porcelain record.
func (r *repository) preservedOverlaps(incoming []string) ([]string, error) {
	status, err := git(r.top, "--no-optional-locks", "status", "--porcelain", "-z", "--no-renames", "--ignored=matching", "--untracked-files=all")
	if err != nil {
		return nil, err
	}
	var overlap []string
	for _, entry := range nulPaths(status) {
		if len(entry) < 4 {
			return nil, fmt.Errorf("could not read the main working tree's status")
		}
		held := strings.TrimSuffix(entry[3:], "/")
		for _, path := range incoming {
			if held == path || strings.HasPrefix(held, path+"/") || strings.HasPrefix(path, held+"/") {
				overlap = append(overlap, held)
				break
			}
		}
	}
	return overlap, nil
}

// preservedEntry names a regular blob with an ordinary executable or
// non-executable Git mode. A deletion or a non-file cannot be prepared here.
func (r *repository) preservedEntry(revision, path string) (string, os.FileMode, error) {
	entry, err := git(r.top, "--literal-pathspecs", "ls-tree", "-z", revision, "--", path)
	if err != nil {
		return "", 0, err
	}
	metadata, name, found := strings.Cut(entry, "\t")
	fields := strings.Fields(metadata)
	if !found || strings.TrimSuffix(name, "\x00") != path || len(fields) != 3 || fields[1] != "blob" {
		return "", 0, refuse(refused, "%q is not a regular file in commit %s", path, r.short(revision))
	}
	switch fields[0] {
	case "100644":
		return fields[2], 0o644, nil
	case "100755":
		return fields[2], 0o755, nil
	default:
		return "", 0, refuse(refused, "%q is not a regular file in commit %s", path, r.short(revision))
	}
}

// checkPreservedFiles compares raw worktree bytes and mode, including changes
// such as line endings that a clean filter could hide from git status.
func (r *repository) checkPreservedFiles(revision string, paths []string) error {
	for _, path := range paths {
		if !filepath.IsLocal(path) {
			return refuse(refused, "%q is not a local repository path", path)
		}
		object, mode, err := r.preservedEntry(revision, path)
		if err != nil {
			return err
		}
		full := filepath.Join(r.top, path)
		real, err := filepath.EvalSymlinks(full)
		if err != nil || real != full {
			return refuse(refused, "%q is missing or crosses a symbolic link", path)
		}
		info, err := os.Lstat(full)
		if err != nil || info.Mode() != mode {
			return refuse(refused, "%q no longer has its preserved file type or permissions", path)
		}
		disk, err := git(r.top, "hash-object", "--no-filters", "--", path)
		if err != nil || disk != object {
			return refuse(refused, "%q no longer has the contents in commit %s", path, r.short(revision))
		}
	}
	return nil
}

func (r *repository) checkPreservedTarget(target string, paths []string) error {
	for _, path := range paths {
		if _, _, err := r.preservedEntry(target, path); err != nil {
			return err
		}
	}
	return nil
}

func (r *repository) landingChanges(from, to string, paths ...string) ([]string, error) {
	args := []string{"--literal-pathspecs", "diff", "--name-only", "--no-renames", "-z", from, to, "--"}
	out, err := git(r.top, append(args, paths...)...)
	return nulPaths(out), err
}

func (r *repository) indexChanges(from string, paths ...string) ([]string, error) {
	args := []string{"--literal-pathspecs", "diff", "--cached", "--name-only", "--no-renames", "-z", from, "--"}
	out, err := git(r.top, append(args, paths...)...)
	return nulPaths(out), err
}

func (r *repository) checkPreservedIndex(base, prepared string, paths []string) error {
	other, err := r.indexChanges(base)
	if err != nil {
		return err
	}
	for _, path := range other {
		if !containsPath(paths, path) {
			return refuse(refused, "an unrelated change to %q appeared in the main index; check it before retrying", path)
		}
	}
	mismatch, err := r.indexChanges(prepared, paths...)
	if err != nil {
		return err
	}
	if len(mismatch) != 0 {
		return refuse(refused, "the main index has unexpected contents at %q; check it before retrying", mismatch[0])
	}
	return nil
}

// undoPreservedForward only rolls back when main and both the worktree and
// index still hold our known state. It never reverses a successful move of main
// or replaces newer edits that became visible after the check.
func (r *repository) undoPreservedForward(base, snapshot, target, patch string, paths []string, applied bool, cause error) error {
	left := fmt.Errorf("%s; the preservation commit is intact, but check the main working tree and index before retrying", reason(cause))
	if now, err := git(r.top, "rev-parse", "HEAD"); err != nil || now != base {
		return left
	}
	prepared := snapshot
	if applied {
		prepared = target
	}
	if r.checkPreservedIndex(base, prepared, paths) != nil || r.checkPreservedFiles(prepared, paths) != nil {
		return left
	}
	if applied && patch != "" {
		if _, err := gitWithInput(r.top, patch+"\n", "apply", "--reverse", "--index", "--whitespace=nowarn"); err != nil {
			return left
		}
	}
	if r.checkPreservedIndex(base, snapshot, paths) != nil {
		return left
	}
	if _, err := git(r.top, append([]string{"--literal-pathspecs", "reset", "-q", base, "--"}, paths...)...); err != nil {
		return left
	}
	return fmt.Errorf("%s; main did not move and the original files remain in place", reason(cause))
}

func nulPaths(output string) []string {
	if output == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(output, "\x00"), "\x00")
}

func containsPath(paths []string, want string) bool {
	for _, path := range paths {
		if path == want {
			return true
		}
	}
	return false
}
