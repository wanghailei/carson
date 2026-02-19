# Butler User Guide

## Purpose

This guide explains how client project teams use Butler from `0.4.0` onwards.

The focus is operational: what to run, when to run it, and what to expect.

Version-by-version change history is tracked in `RELEASE.md`.

## Scope and boundaries

In scope:

- local usage in client repositories
- CI governance integration
- review-gate and sweep workflow

Out of scope:

- Butler internals and implementation detail
- replacing GitHub as merge authority

Boundary rules:

- Butler runs outside client repositories.
- Butler-owned artefacts must not exist in host repositories (`.butler.yml`, `bin/butler`, `.tools/butler/*`).
- Butler may manage selected GitHub-native files in host repositories under `.github/*`.

## Module relationships

- Developer workstation: runs `butler` commands locally.
- Client repository: receives GitHub-native managed files and normal project changes.
- GitHub: remains the merge authority and required-check gate.

## Core flow

1. Install Butler once on the workstation.
2. Initialise each repository with `butler init [repo_path]`.
3. Use Butler continuously during local development (`audit`, `sync`, `prune`).
4. Enforce merge readiness with `review gate`.
5. Run scheduled late-review monitoring with `review sweep`.
6. Retire Butler from a repository when needed with `offboard`.

## Feature: Quick start in one command (`0.4.0+`)

For a repository at a local demo path:

```bash
butler init /local/path/of/repo
```

This command performs baseline setup in sequence:

- align remote naming for Butler (`origin` -> `github` when needed)
- install and enforce Butler hooks
- apply managed `.github/*` templates
- run an initial audit report

## Feature: First-time setup for a new repository (`0.4.0+`)

Example repository path:

- `/local/path/of/repo`

### 1) Install Butler globally once

Start with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/wanghailei/butler/main/install.sh | bash
```

This installer builds Butler from source and installs it locally for your user account, so it works even before package publishing.

Prerequisites:

- Ruby `>= 4.0`
- `git`
- `curl`

Verify:

```bash
butler version
```

If `butler` is not found in your shell, add `~/.local/bin` to `PATH`.

Alternative (if you already cloned Butler locally):

```bash
cd /local/path/of/butler
./install.sh
```

Expected result:

- `butler version` prints the installed Butler version (for example `0.4.0`).
- `butler` is the primary command, and `butler-to-merge` is an equivalent alias.

### 2) Prepare the repository

```bash
cd /local/path/of/repo
git remote get-url github >/dev/null 2>&1 || git remote rename origin github
```

### 3) Apply local Butler baseline

```bash
butler init /local/path/of/repo
```

Expected result:

- global hooks installed under `~/.butler/hooks/<version>/`
- repository `core.hooksPath` set to Butler hooks path
- Butler reports written under `~/.cache/butler` by default
- when `HOME` is invalid, Butler falls back to `TMPDIR/butler` (absolute `TMPDIR` only), then `/tmp/butler`
- managed files written:
  - `.github/copilot-instructions.md`
  - `.github/pull_request_template.md`

### 4) Commit managed GitHub files in the repository

Commit and push the generated `.github/*` files as normal repository content.

### 5) Add Butler governance workflow in repository CI

Create `.github/workflows/butler_policy.yml` in the repository:

```yaml
name: Butler governance

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/butler/.github/workflows/butler_policy.yml@main
    with:
      butler_version: "0.4.0"
```

Then ensure this workflow is required in branch protection.

### 6) Set repository defaults (optional helper)

Use the helper script directly (no local Butler checkout required):

```bash
curl -fsSL https://raw.githubusercontent.com/wanghailei/butler/main/script/bootstrap_repo_defaults.sh | bash -s -- <owner>/<repo> --checks "Syntax and smoke tests,Butler policy"
```

## Feature: When to use `init`

Use `butler init /local/path/of/repo` when:

- onboarding Butler to a repository for the first time
- setting up a fresh local clone that has not had Butler hook/template baseline applied
- reapplying baseline after deliberate local Butler hook reset

Do not use `init` as a daily command. For day-to-day work, use:

- `butler audit`
- `butler sync`
- `butler prune`

## Feature: When to use `offboard`

Use `butler offboard /local/path/of/repo` when:

- removing Butler from a repository
- cleaning legacy Butler artefacts from earlier versions
- resetting a repository before re-onboarding with a newer Butler release

What `offboard` removes:

- Butler-managed `.github/*` template files
- Butler governance workflow files (`.github/workflows/butler-governance.yml`, `.github/workflows/butler_policy.yml`)
- legacy Butler artefacts (`.butler.yml`, `bin/butler`, `.tools/butler`)

What `offboard` changes:

- unsets repo `core.hooksPath` when it points to Butler-managed global hooks

## Feature: Daily usage pattern

Use this normal local cadence in client repositories:

1. Start work: `butler audit`.
2. Keep local main current: `butler sync`.
3. Before commit and before push: `butler audit`.
4. Clean stale local branches: `butler prune`.
5. Before merge recommendation: `gh pr list --state open --limit 50`, then `butler review gate`.

## Feature: Exit status contract

Butler command exits:

- `0`: OK
- `1`: runtime or configuration error
- `2`: policy blocked (hard stop)

Treat exit `2` as a mandatory stop until resolved.

## Feature: Managed GitHub templates

Butler manages:

- `.github/copilot-instructions.md`
- `.github/pull_request_template.md`

Commands:

- `butler template check`: detect drift
- `butler template apply`: apply canonical content

## Feature: Review gate and review sweep

- `butler review gate`: merge-readiness check on unresolved threads and actionable review findings.
- `butler review sweep`: scheduled scan for late actionable review activity on recent pull requests.

Recommended sweep schedule:

- every 8 hours in GitHub Actions.

## References

- `README.md`
- `RELEASE.md`
- `docs/butler_tech_guide.md`
- `.github/workflows/butler_policy.yml`
- `script/bootstrap_repo_defaults.sh`
