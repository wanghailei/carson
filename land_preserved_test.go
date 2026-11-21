package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

type preservedLandingFixture struct {
	*fixture
	base, snapshot, target string
	hooks                  []string
}

func newPreservedLandingFixture(t *testing.T) preservedLandingFixture {
	t.Helper()
	f := newFixture(t)
	f.commit(f.local, "README.md")
	for _, name := range []string{"adapter.mjs", "install", "test-all"} {
		f.write(f.local, name, "previously committed contents\n")
	}
	f.git(f.local, "add", ".")
	f.git(f.local, "commit", "-qm", "previously committed adapter files")
	f.git(f.local, "push", "-q", "github", "main")
	old := f.startTask("snapshot")
	f.write(old, "README.md", "old uncommitted instructions\n\n")
	hooks := []string{"hook-entry.mjs", "hook-loader.mjs", "hook-policy.json", "hook-test.mjs", "adapter.mjs", "install", "test-all"}
	for _, name := range hooks {
		f.write(old, name, name+"\n")
	}
	f.git(old, "add", ".")
	f.git(old, "commit", "-qm", "preserve the owner's local edits")
	snapshot := f.git(old, "rev-parse", "HEAD")

	f.commit(f.local, "diagram.md")
	f.git(f.local, "push", "-q", "github", "main")
	base := f.git(f.local, "rev-parse", "main")

	taskDir := f.startTask("approved-task")
	f.write(taskDir, "README.md", "approved instructions\n")
	f.write(taskDir, "deliverable.md", "new deliverable\n")
	for _, name := range hooks {
		f.write(taskDir, name, name+"\n")
	}
	f.git(taskDir, "add", ".")
	f.git(taskDir, "commit", "-qm", "approved instructions and hooks")
	target := f.git(taskDir, "rev-parse", "HEAD")

	f.write(f.local, "README.md", "old uncommitted instructions\n\n")
	for _, name := range hooks {
		f.write(f.local, name, name+"\n")
	}
	return preservedLandingFixture{fixture: f, base: base, snapshot: snapshot, target: target, hooks: hooks}
}

func (f preservedLandingFixture) mainFile(name string) os.FileInfo {
	f.t.Helper()
	info, err := os.Stat(filepath.Join(f.local, name))
	if err != nil {
		f.t.Fatal(err)
	}
	return info
}

func (f preservedLandingFixture) landPreserved(snapshot string) (string, int) {
	f.t.Helper()
	return f.runIn(inClaude, f.taskFolder("approved-task"), claudeRunning, "land", "approved-task", "--preserved", snapshot)
}

func TestWhenOverlapsArePreservedMainFastForwardsAndMatchingHooksStayInPlace(t *testing.T) {
	f := newPreservedLandingFixture(t)
	f.write(f.local, "first.txt", "unrelated local edit\n")
	f.git(f.local, "config", "diff.noprefix", "true")
	f.git(f.local, "config", "color.diff", "always")
	out, code := f.land(f.taskFolder("approved-task"))
	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: fast-forwarding main would overwrite")
	if !strings.Contains(out, "authorises replacing") || !strings.Contains(out, "carson land approved-task --preserved <commit>") {
		t.Errorf("the refusal did not explain the authorised preservation path: %s", out)
	}
	held := make(map[string]os.FileInfo)
	for _, name := range f.hooks {
		held[name] = f.mainFile(name)
	}

	out, code = f.landPreserved(f.snapshot)
	expectCode(t, code, 0)
	expectLine(t, out, "The original overlapping files are kept in commit "+f.snapshot+".")
	expectLine(t, out, "Landed approved-task on main by fast-forward at "+f.short(f.local, "main")+" (1 commit) and pushed; GitHub's main is "+f.short(f.local, "main")+".")
	for _, repository := range []string{f.local, f.github} {
		if main := f.git(repository, "rev-parse", "refs/heads/main"); main != f.target {
			t.Errorf("%s main = %s, want %s", repository, main, f.target)
		}
	}
	if status := f.git(f.local, "status", "--porcelain"); strings.TrimSpace(status) != "M first.txt" {
		t.Errorf("the remaining local change = %q, want the unrelated edit alone", status)
	}
	for _, name := range f.hooks {
		now := f.mainFile(name)
		if !os.SameFile(held[name], now) || !held[name].ModTime().Equal(now.ModTime()) {
			t.Errorf("the matching hook file %s was replaced or written", name)
		}
	}
	if got := f.git(f.local, "show", f.snapshot+":README.md"); got != "old uncommitted instructions" {
		t.Errorf("the preserved commit holds README %q", got)
	}
}

func TestWhenAnOverlapHasChangedSincePreservationLandingRefusesWithoutChanges(t *testing.T) {
	f := newPreservedLandingFixture(t)
	f.write(f.local, "README.md", "edited after the preservation commit\n")

	out, code := f.landPreserved(f.snapshot)
	expectCode(t, code, 2)
	if !strings.Contains(out, "README.md") {
		t.Fatalf("the refusal does not name README.md: %s", out)
	}
	f.checkRefusedWithoutChanges()
	got, err := os.ReadFile(filepath.Join(f.local, "README.md"))
	if err != nil || string(got) != "edited after the preservation commit\n" {
		t.Errorf("the later edit was changed, got %q (%v)", got, err)
	}
}

func TestWhenAnOverlapIsNotInThePreservedCommitLandingRefusesWithoutChanges(t *testing.T) {
	f := newPreservedLandingFixture(t)
	f.write(f.local, "deliverable.md", "unrelated owner's untracked file\n")

	out, code := f.landPreserved(f.snapshot)
	expectCode(t, code, 2)
	if !strings.Contains(out, "deliverable.md") {
		t.Fatalf("the refusal does not name deliverable.md: %s", out)
	}
	f.checkRefusedWithoutChanges()
}

func TestWhenTheIndexContainsAnUnrelatedChangeLandingRefusesWithoutUnstagingIt(t *testing.T) {
	f := newPreservedLandingFixture(t)
	f.write(f.local, "first.txt", "unrelated staged change\n")
	f.git(f.local, "add", "first.txt")
	before := f.git(f.local, "write-tree")

	out, code := f.landPreserved(f.snapshot)
	expectCode(t, code, 2)
	if !strings.Contains(out, "index") {
		t.Fatalf("the refusal does not name index: %s", out)
	}
	if main := f.git(f.local, "rev-parse", "main"); main != f.base {
		t.Errorf("main moved to %s despite the refusal", main)
	}
	if after := f.git(f.local, "write-tree"); before != after {
		t.Error("the staged change was altered despite the refusal")
	}
}

func TestWhenTheSuppliedCommitDoesNotPreserveEveryOverlapLandingRefuses(t *testing.T) {
	f := newPreservedLandingFixture(t)

	out, code := f.landPreserved(f.target)

	expectCode(t, code, 2)
	if !strings.Contains(out, "deliverable.md") || !strings.Contains(out, "is not in the way of landing") {
		t.Errorf("the refusal did not explain the unrelated path in the supplied commit: %s", out)
	}
	f.checkRefusedWithoutChanges()
}

func TestWhenThePreservedFlagHasNoCommitLandingShowsItsSyntax(t *testing.T) {
	f := newPreservedLandingFixture(t)

	out, code := f.runIn(inClaude, f.taskFolder("approved-task"), claudeRunning, "land", "approved-task", "--preserved")

	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: give the full preservation commit ID as in carson land <task> --preserved <commit>.")
	f.checkRefusedWithoutChanges()
}

func TestWhenUpdatingTheTaskChangesItsTipThePreservedLandingStopsForReview(t *testing.T) {
	f := newPreservedLandingFixture(t)
	f.otherMachine()
	upstream := f.git(f.github, "rev-parse", "refs/heads/main")

	out, code := f.landPreserved(f.snapshot)

	expectCode(t, code, 2)
	expectLine(t, out, "Not landed: the task's tip changed from")
	for _, repository := range []string{f.local, f.github} {
		if main := f.git(repository, "rev-parse", "refs/heads/main"); main != upstream {
			t.Errorf("%s main = %s, want only the upstream update %s", repository, main, upstream)
		}
	}
	if got := f.git(f.local, "diff", "--cached", "--name-only"); got != "" {
		t.Errorf("files were staged despite the refusal: %s", got)
	}
	contents, err := os.ReadFile(filepath.Join(f.local, "README.md"))
	if err != nil || string(contents) != "old uncommitted instructions\n\n" {
		t.Errorf("the uncommitted README was changed, got %q (%v)", contents, err)
	}
}

func (f preservedLandingFixture) checkRefusedWithoutChanges() {
	f.t.Helper()
	for _, repository := range []string{f.local, f.github} {
		if main := f.git(repository, "rev-parse", "refs/heads/main"); main != f.base {
			f.t.Errorf("%s main moved to %s despite the refusal", repository, main)
		}
	}
	if staged := f.git(f.local, "diff", "--cached", "--name-only"); staged != "" {
		f.t.Errorf("files were staged despite the refusal: %s", staged)
	}
}

func TestWhenFastForwardFailsAfterPreparingPreservedFilesOriginalEditsRemain(t *testing.T) {
	f := newPreservedLandingFixture(t)
	realGit, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	gitShim := t.TempDir()
	command := "#!/bin/sh\nif [ \"$3\" = merge ]; then\n printf 'error: simulated fast-forward refusal\\n' >&2\n exit 1\nfi\nexec \"$CARSON_TEST_REAL_GIT\" \"$@\"\n"
	if err := os.WriteFile(filepath.Join(gitShim, "git"), []byte(command), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CARSON_TEST_REAL_GIT", realGit)
	t.Setenv("PATH", gitShim+string(os.PathListSeparator)+os.Getenv("PATH"))

	out, code := f.landPreserved(f.snapshot)
	expectCode(t, code, 1)
	if !strings.Contains(out, "simulated fast-forward refusal") {
		t.Fatalf("the refusal does not mention the Git failure: %s", out)
	}
	f.checkRefusedWithoutChanges()
	got, err := os.ReadFile(filepath.Join(f.local, "README.md"))
	if err != nil || string(got) != "old uncommitted instructions\n\n" {
		t.Errorf("the original README was not put back, got %q (%v)", got, err)
	}
}
