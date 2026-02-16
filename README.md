# Butler

Butler is a shared local governance tool for repository hygiene and merge readiness support.

## Runtime

- Ruby managed by `rbenv`
- Supported Ruby versions: `>= 4.0`

## Version

- Current version: `0.1.0`
- Canonical source: `VERSION`
- CLI version output: `bin/butler version` or `bin/butler --version`
- Release history: `RELEASE.md`

## CI

- Workflow: `.github/workflows/ci.yml`
- Trigger: pull requests (and manual dispatch)
- Job step: `ruby -c bin/butler`
- Job step: `bash script/ci_smoke.sh`
- Smoke logs always print both numeric and text status, for example `0 - OK`.

## New Project Defaults

Use the bootstrap helper so new repositories start with the same integration workflow defaults:

- `script/bootstrap_repo_defaults.sh <owner/repo>`
- Optional checks: `--checks "check_one,check_two"`
- Optional local setup: `--local-path ~/Studio/<repo>`
- Optional Butler read secret setup: `--set-butler-read-token`

What it applies:

- branch protection with approvals `0`, required conversation resolution, required linear history, and no force-push or delete
- required status checks (if provided)
- optional local `bin/butler` wrapper install plus `bin/butler hook` and `bin/butler template apply`

## Commands

- `bin/butler audit`
- `bin/butler sync`
- `bin/butler prune`
- `bin/butler hook`
- `bin/butler check`
- `bin/butler version`
- `bin/butler template check`
- `bin/butler template apply`

Compatibility aliases:

- `bin/butler common check`
- `bin/butler common apply`

## Exit Statuses

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Configuration

`/.butler.yml` is optional.

- If absent, Butler uses shared built-in defaults.
- If present, Butler deep-merges your overrides onto those defaults.

## Common Templates

Butler can manage shared `.github` sections with explicit markers:

```md
<!-- butler:common:start <section-id> -->
...common managed content...
<!-- butler:common:end <section-id> -->
```

Template sync behaviour:

- `template check` reads managed files and reports drift only; it does not write files.
- `template apply` writes only the managed marker block content.
- Repo-specific content outside marker blocks is preserved.
- If markers are missing, Butler prepends the managed block and keeps existing content below it.
