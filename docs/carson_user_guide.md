# Carson User Guide

## Brief

Carson helps you bootstrap and run repository governance with a predictable workflow.

It is an outsider tool: Carson runs from your workstation and does not install Carson-owned tooling inside client repositories.

Your target outcome as a new user is simple:

1. Install Carson once.
2. Configure a repository once.
3. Run a short daily command cadence.

## Who this guide is for

Use this guide if you are onboarding Carson in a client repository and want a clear path from zero setup to stable daily operation.

For Carson implementation details, use `docs/carson_tech_guide.md`.

## User journey at a glance

1. Install Carson.
2. Verify your runtime and shell path.
3. Configure one repository with `carson init`.
4. Add/pin Carson governance in CI.
5. Run daily commands (`sync`, `audit`, `prune`, `review gate`).
6. Use `offboard` when retiring Carson from a repository.

## 1) Install Carson

### Prerequisites

- Ruby `>= 4.0`
- `gem` in `PATH`
- `git` in `PATH`
- `gh` in `PATH` (recommended for full governance and review features)

### Option A (recommended): install from RubyGems

```bash
gem install --user-install carson -v 0.7.0
```

If your shell cannot find `carson`, add your Ruby user bin directory:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

### Option B: install from a Carson source checkout

```bash
git clone https://github.com/wanghailei/carson.git
cd carson
./install.sh
```

### Verify installation

```bash
carson version
```

Expected result:

- version prints `0.7.0` (or newer)
- executable `carson` is available

## 2) Configure your first repository

Assume your project lives at `/local/path/of/repo`.

### Step 1: run one-command baseline setup

```bash
carson init /local/path/of/repo
```

`init` performs:

- remote alignment using configured `git.remote` (default `github`)
- hook installation under `~/.carson/hooks/<version>/`
- repository `core.hooksPath` alignment to Carson global hooks
- commit-time governance gate via managed `pre-commit` hook (`carson audit`)
- managed GitHub template sync under `.github/*`
- initial governance audit output

### Step 2: commit managed GitHub files

Commit generated `.github/*` files in the client repository as normal project files.

### Step 3: pin Carson policy workflow in CI

Create `/local/path/of/repo/.github/workflows/carson_policy.yml`:

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v0.7.0
    with:
      carson_ref: "v0.7.0"
      carson_version: "0.7.0"
```

Then set required checks in repository branch protection to include `Carson policy`.
When adopting newer Carson releases, update both the workflow commit SHA and `carson_version` together.

### Optional: one-command GitHub defaults bootstrap

From a local Carson checkout:

```bash
cd /local/path/of/carson
script/bootstrap_repo_defaults.sh <owner>/<repo> --checks "Syntax and smoke tests,Carson policy"
```

This script updates GitHub settings (for example branch protection), so confirm target repository carefully before running.

## 3) Configure boundaries correctly

Carson enforces outsider boundaries in client repositories.

Blocked Carson fingerprints in host repositories:

- `.carson.yml`
- `bin/carson`
- `.tools/carson/*`

Allowed managed persistence in host repositories:

- selected GitHub-native files under `.github/*`

## 4) Optional global configuration

Carson remains outsider-only. Configuration lives in your user space, not in host repositories.

Default global config path:

- `~/.carson/config.json`

Override path:

- `CARSON_CONFIG_FILE=/absolute/path/to/config.json`

Minimal example:

```json
{
	"scope": {
		"path_groups": {
			"domain": [ "app/**", "db/**", "config/**" ]
		}
	},
	"review": {
		"required_disposition_prefix": "Disposition:"
	},
	"style": {
		"ruby_indentation": "tabs"
	}
}
```

Policy env overrides:

- `CARSON_REVIEW_DISPOSITION_PREFIX`
- `CARSON_RUBY_INDENTATION` (`tabs`, `spaces`, `either`)

## 5) Run Carson daily

Use this practical daily cadence:

### Start of work

```bash
carson sync
carson audit
```

### Before push or PR update

```bash
carson audit
carson template check
```

If template drift is detected:

```bash
carson template apply
```

### Keep local branches clean

```bash
carson prune
```

### Before merge recommendation

```bash
gh pr list --state open --limit 50
carson review gate
```

### Scheduled late-review monitoring

Run every 8 hours in CI:

```bash
carson review sweep
```

## 6) Understand outputs and exit codes

Carson uses a strict exit contract:

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

Treat exit `2` as a mandatory stop until the blocking condition is resolved.

Report output directory behaviour:

- default: `~/.cache/carson`
- fallback when `HOME` is invalid: `TMPDIR/carson` (absolute `TMPDIR` only), then `/tmp/carson`

## 7) Troubleshooting quick path

### `carson: command not found`

- confirm Ruby and gem installation
- ensure `$(ruby -e 'print Gem.user_dir')/bin` or `~/.local/bin` is in `PATH`

### review gate fails on actionable comments

- respond with a valid `Disposition:` disposition comment
- include disposition token and target comment/review URL
- rerun `carson review gate`

### hooks check blocks

```bash
carson hook
carson check
```

### template drift blocks

```bash
carson template apply
carson template check
```

## 8) Offboard cleanly when needed

To retire Carson from a repository:

```bash
carson offboard /local/path/of/repo
```

This command removes Carson-managed host artefacts and unsets `core.hooksPath` when it points to Carson-managed global hooks.

## Command quick reference

- `carson init [repo_path]`
- `carson audit`
- `carson sync`
- `carson prune`
- `carson hook`
- `carson check`
- `carson template check`
- `carson template apply`
- `carson review gate`
- `carson review sweep`
- `carson offboard [repo_path]`
- `carson version`

## Related docs

- `README.md`
- `RELEASE.md`
- `docs/carson_tech_guide.md`
- `docs/carson_dev_guide.md`
