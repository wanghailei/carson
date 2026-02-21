# Butler User Guide

## Brief

Butler helps you bootstrap and run repository governance with a predictable workflow.

It is an outsider tool: Butler runs from your workstation and does not install Butler-owned tooling inside client repositories.

Your target outcome as a new user is simple:

1. Install Butler once.
2. Configure a repository once.
3. Run a short daily command cadence.

## Who this guide is for

Use this guide if you are onboarding Butler in a client repository and want a clear path from zero setup to stable daily operation.

For Butler implementation details, use `docs/butler_tech_guide.md`.

## User journey at a glance

1. Install Butler.
2. Verify your runtime and shell path.
3. Configure one repository with `butler init`.
4. Add/pin Butler governance in CI.
5. Run daily commands (`sync`, `audit`, `prune`, `review gate`).
6. Use `offboard` when retiring Butler from a repository.

## 1) Install Butler

### Prerequisites

- Ruby `>= 4.0`
- `gem` in `PATH`
- `git` in `PATH`
- `gh` in `PATH` (recommended for full governance and review features)

### Option A (recommended): install from RubyGems

```bash
gem install --user-install butler-to-merge -v 0.5.0
```

If your shell cannot find `butler`, add your Ruby user bin directory:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

### Option B: install from a Butler source checkout

```bash
git clone https://github.com/wanghailei/butler.git
cd butler
./install.sh
```

### Verify installation

```bash
butler version
```

Expected result:

- version prints `0.5.0` (or newer)
- executable `butler` is available
- alias `butler-to-merge` is available

## 2) Configure your first repository

Assume your project lives at `/local/path/of/repo`.

### Step 1: ensure Butler remote naming expectation

```bash
cd /local/path/of/repo
git remote get-url github >/dev/null 2>&1 || git remote rename origin github
```

### Step 2: run one-command baseline setup

```bash
butler init /local/path/of/repo
```

`init` performs:

- hook installation under `~/.butler/hooks/<version>/`
- repository `core.hooksPath` alignment to Butler global hooks
- managed GitHub template sync under `.github/*`
- initial governance audit output

### Step 3: commit managed GitHub files

Commit generated `.github/*` files in the client repository as normal project files.

### Step 4: pin Butler governance in CI

Create `/local/path/of/repo/.github/workflows/butler_policy.yml`:

```yaml
name: Butler governance

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/butler/.github/workflows/butler_policy.yml@main
    with:
      butler_version: "0.5.0"
```

Then set required checks in repository branch protection to include Butler governance.

### Optional: one-command GitHub defaults bootstrap

From a local Butler checkout:

```bash
cd /local/path/of/butler
script/bootstrap_repo_defaults.sh <owner>/<repo> --checks "Syntax and smoke tests,Butler governance"
```

This script updates GitHub settings (for example branch protection), so confirm target repository carefully before running.

## 3) Configure boundaries correctly

Butler enforces outsider boundaries in client repositories.

Blocked Butler fingerprints in host repositories:

- `.butler.yml`
- `bin/butler`
- `.tools/butler/*`
- legacy Butler marker artefacts

Allowed managed persistence in host repositories:

- selected GitHub-native files under `.github/*`

## 4) Run Butler daily

Use this practical daily cadence:

### Start of work

```bash
butler sync
butler audit
```

### Before push or PR update

```bash
butler audit
butler template check
```

If template drift is detected:

```bash
butler template apply
```

### Keep local branches clean

```bash
butler prune
```

### Before merge recommendation

```bash
gh pr list --state open --limit 50
butler review gate
```

### Scheduled late-review monitoring

Run every 8 hours in CI:

```bash
butler review sweep
```

## 5) Understand outputs and exit codes

Butler uses a strict exit contract:

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

Treat exit `2` as a mandatory stop until the blocking condition is resolved.

Report output directory behaviour:

- default: `~/.cache/butler`
- fallback when `HOME` is invalid: `TMPDIR/butler` (absolute `TMPDIR` only), then `/tmp/butler`

## 6) Troubleshooting quick path

### `butler: command not found`

- confirm Ruby and gem installation
- ensure `$(ruby -e 'print Gem.user_dir')/bin` is in `PATH`

### review gate fails on actionable comments

- respond with a valid `Codex:` disposition comment
- include disposition token and target comment/review URL
- rerun `butler review gate`

### hooks check blocks

```bash
butler hook
butler check
```

### template drift blocks

```bash
butler template apply
butler template check
```

## 7) Offboard cleanly when needed

To retire Butler from a repository:

```bash
butler offboard /local/path/of/repo
```

This command removes Butler-managed host artefacts and unsets `core.hooksPath` when it points to Butler-managed global hooks.

## Command quick reference

- `butler init [repo_path]`
- `butler audit`
- `butler sync`
- `butler prune`
- `butler hook`
- `butler check`
- `butler template check`
- `butler template apply`
- `butler review gate`
- `butler review sweep`
- `butler offboard [repo_path]`
- `butler version`

## Related docs

- `README.md`
- `RELEASE.md`
- `docs/butler_tech_guide.md`
- `docs/butler_dev_guide.md`
