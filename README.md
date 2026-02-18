# Butler

Butler is an outsider governance runtime.

It runs against a repository without placing Butler-owned artefacts into that repository.

## Runtime

- Ruby managed by `rbenv`
- Supported Ruby versions: `>= 4.0`
- Primary CLI executable: `butler`
- CLI alias: `butler-to-merge`
- Default report output directory: `~/.cache/butler`

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
- `butler init [repo_path]`
- `butler offboard [repo_path]`
- `butler template check`
- `butler template apply`
- `butler review gate`
- `butler review sweep`
- `butler version`

## Documentation Map

To minimise overlap across documents:

- `README.md`: product overview, runtime prerequisites, command index.
- `docs/butler_user_guide.md`: common-user onboarding and daily usage workflows.
- `docs/butler_technical_guide.md`: technical behaviour guide for contributors/advanced operators.
- `RELEASE.md`: version-by-version deltas, breaking changes, and migration notes only.

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

## Offboard Model

- `butler offboard [repo_path]` retires Butler from a repository
- It unsets `core.hooksPath` when it points to Butler-managed global hooks
- It removes Butler-managed host artefacts and known legacy Butler files

## CI

- Butler repository CI workflow: `.github/workflows/ci.yml`
- Review sweep workflow: `.github/workflows/review-sweep.yml`
- Reusable host-repository policy workflow: `.github/workflows/butler_policy.yml`

## Bootstrap Defaults

Use:

- `script/bootstrap_repo_defaults.sh <owner/repo>`
- Optional checks override: `--checks "check_one,check_two"`
- Optional token setup: `--set-butler-read-token`

Bootstrap script now configures GitHub branch protection and secrets only.
