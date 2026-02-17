# Butler

Butler is an outsider governance runtime.

It runs against a repository without placing Butler-owned artefacts into that repository.

## Runtime

- Ruby managed by `rbenv`
- Supported Ruby versions: `>= 4.0`
- Gem executable: `butler`
- Developer shim in this repository: `bin/butler` -> `exe/butler`

## Version

- Canonical source: `VERSION`
- CLI version output: `butler version` or `butler --version`
- Release notes: `RELEASE.md`

## Commands

- `butler audit`
- `butler sync`
- `butler prune`
- `butler hook`
- `butler check`
- `butler template check`
- `butler template apply`
- `butler review gate`
- `butler review sweep`
- `butler version`

## Outsider Boundary

In host repositories, Butler blocks on:

- `.butler.yml`
- `bin/butler`
- `.tools/butler/*`
- legacy marker artefacts from earlier template model

Allowed persistence in host repositories:

- GitHub-native files that Butler manages, currently under `.github/*`

## Hook Model

- Hook assets are carried by Butler in `assets/hooks/*`
- `butler hook` installs hooks under `~/.butler/hooks/<version>/`
- Repo `core.hooksPath` points to that global hook path

## Template Model

- Template sources are carried by Butler in `templates/.github/*`
- `butler template check` performs whole-file drift checks
- `butler template apply` writes full managed file content

## CI

- Butler repository CI workflow: `.github/workflows/ci.yml`
- Review sweep workflow: `.github/workflows/review-sweep.yml`
- Reusable host-repository governance workflow: `.github/workflows/governance-reusable.yml`

## Bootstrap Defaults

Use:

- `script/bootstrap_repo_defaults.sh <owner/repo>`
- Optional checks override: `--checks "check_one,check_two"`
- Optional token setup: `--set-butler-read-token`

Bootstrap script now configures GitHub branch protection and secrets only.
