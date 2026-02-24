# Butler Release Notes

Release-note scope rule:

- `RELEASE.md` records only version deltas, breaking changes, and migration actions.
- Operational usage guides live in `docs/butler_user_guide.md`.

## 0.6.1 (2026-02-24)

### User Overview

#### What changed

- Removed branch-name scope enforcement from commit-time governance and kept scope integrity path-group based.
- Improved hook-upgrade diagnostics and installer guidance when repositories are still pinned to an older Butler hooks path.
- Fixed scope guard conflict reporting so `violating_files` only lists true cross-core conflicts.
- Updated user-facing install/pin examples to `0.6.1`.

#### Why users should care

- Branch names are now informational only for scope checks, so commits are governed by actual feature/module path boundaries.
- Hook upgrade failure modes are easier to diagnose and fix locally.
- Scope integrity output is less noisy and more actionable.

#### What users must do now

1. Upgrade to `0.6.1` where Butler is pinned.
2. Re-run `butler hook` in governed repositories after upgrade.
3. Update CI `butler_version` pins to `0.6.1`.

#### Breaking or removed behaviour

- `BUTLER_SCOPE_BRANCH_PATTERN` override support has been removed.
- `scope.branch_pattern` and `scope.lane_group_map` config keys are no longer consumed.

#### Upgrade steps

```bash
gem install --user-install butler-to-merge -v 0.6.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- Scope policy is now strictly changed-path based; branch-pattern controls are removed.
- Review acknowledgement and style overrides remain:
  `BUTLER_REVIEW_DISPOSITION_PREFIX`, `BUTLER_RUBY_INDENTATION`.

#### Verification evidence

- PR #40 merged with green required checks (`Butler governance`, `Syntax and smoke tests`).
- PR #41 merged with green required checks (`Butler governance`, `Syntax and smoke tests`).

## 0.6.0 (2026-02-23)

### User Overview

#### What changed

- Refactored runtime concerns from `*Ops` naming to neutral modules (`Local`, `Audit`, `Review`), and split review governance internals into dedicated support files.
- Added global user configuration loading from `~/.butler/config.json` with deterministic precedence:
  built-in defaults, then global config file, then environment overrides.
- Removed branch-name scope policy coupling; scope integrity now evaluates changed paths only (via `scope.path_groups`).
- Changed default review acknowledgement prefix from `Codex:` to `Disposition:`.
- Added Ruby stdlib unit tests for deterministic helper logic and integrated them in CI.
- Replaced static indentation regex checks with policy-based guard script (`script/ruby_indentation_guard.rb`).
- Optimised legacy marker detection and hardened untracked/quoted-path handling.
- Added internal developer documentation for `~/.butler/config.json`.

#### Why users should care

- Butler is now more neutral and less coupled to a single agent naming workflow.
- User-space configuration is now explicit and predictable without adding repo-local Butler files.
- Review governance and helper logic are easier to maintain and reason about.
- CI catches deterministic logic regressions earlier through added unit tests.

#### What users must do now

1. Upgrade to `0.6.0` where you pin Butler explicitly.
2. If you relied on `Codex:` acknowledgement comments, set `BUTLER_REVIEW_DISPOSITION_PREFIX=Codex:` (or `review.required_disposition_prefix` in `~/.butler/config.json`).

#### Breaking or removed behaviour

- Branch-name policy matching has been removed; branch names are informational only.
- Default review acknowledgement prefix no longer assumes `Codex:`.
- `docs/butler_evo_plan.md` has been removed from the repository.

#### Upgrade steps

```bash
gem install --user-install butler-to-merge -v 0.6.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- New canonical global config path: `~/.butler/config.json`.
- New path override env var: `BUTLER_CONFIG_FILE`.
- Added policy env overrides:
  `BUTLER_REVIEW_DISPOSITION_PREFIX`, `BUTLER_RUBY_INDENTATION`.
- Style policy supports `tabs`, `spaces`, or `either` through configuration.

#### Verification evidence

- PR #37 merged with both CI jobs green (`Butler governance`, `Syntax and smoke tests`).
- Unit tests run in CI via `ruby -Itest -e 'Dir.glob( "test/**/*_test.rb" ).sort.each { |path| require File.expand_path( path ) }'`.

## 0.5.1 (2026-02-22)

### User Overview

#### What changed

- Fixed source installer behaviour so running `./install.sh` no longer leaves `butler-to-merge-<version>.gem` in the Butler repository root.
- Updated user-facing install and pin examples to `0.5.1`.

#### Why users should care

- Source installation now leaves Butler checkouts clean after install.
- Version guidance in onboarding docs now matches the latest published patch release.

#### What users must do now

1. Upgrade to `0.5.1` where you pin Butler explicitly.
2. No migration is required for existing `0.5.0` runtime/governance behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install butler-to-merge -v 0.5.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version
```

### Engineering Appendix

#### Public interface and config changes

- No CLI, config schema, or exit-contract changes.

#### Verification evidence

- Installer behaviour corrected by PR #32 (`install.sh` temporary gem handling).

## 0.5.0 (2026-02-21)

### User Overview

#### What changed

- Added one-command source installer: `./install.sh`.
- Split installation guidance into public user and internal developer tracks.
- Added Butler evolution planning document: `docs/butler_evo_plan.md`.
- Stabilised review sweep smoke fixtures with relative timestamps to remove date drift failures.

#### Why users should care

- Source-based onboarding is now a single command.
- Installation paths are clearer for end users versus contributors.
- Governance smoke coverage is more stable over time.

#### What users must do now

1. For source-based onboarding, run `./install.sh`.
2. For gem-based onboarding, pin and install `butler-to-merge` at `0.5.0`.
3. No migration is required for existing `0.4.0` policy/runtime behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install butler-to-merge -v 0.5.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version
```

### Engineering Appendix

#### Public interface and config changes

- Added `install.sh` as a source-install entrypoint.
- No CLI command-surface changes.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- `script/review_smoke.sh` now uses relative fixture timestamps for sweep-window stability.

## 0.4.0 (2026-02-18)

### User Overview

#### What changed

- Added repository retirement command: `butler offboard [repo_path]`.
- `offboard` now removes Butler-managed host artefacts and legacy Butler files from client repositories.
- `offboard` unsets repo `core.hooksPath` only when it points to Butler-managed global hook paths.

#### Why users should care

- Retiring Butler from a repository is now one command.
- Re-onboarding with a newer Butler release is cleaner after explicit offboarding.

#### What users must do now

1. Use `butler offboard /local/path/of/repo` when removing Butler from a repository.
2. Re-run `butler init /local/path/of/repo` when re-onboarding later.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install butler-governance
butler version
```

### Engineering Appendix

#### Public interface and config changes

- Added command `offboard [repo_path]` to CLI surface.
- Added runtime methods `offboard!`, `disable_butler_hooks_path!`, `offboard_cleanup_targets`, and `remove_empty_offboard_directories!`.

#### Verification evidence

- CI smoke coverage includes `offboard` cleanup and idempotency checks.

## 0.3.2 (2026-02-18)

### User Overview

#### What changed

- Version baseline bumped to `0.3.2` ahead of offboard command implementation.

## 0.3.1 (2026-02-18)

### User Overview

#### What changed

- Renamed Butler gem package from `butler-governance` to `butler-to-merge` (CLI command remains `butler`).
- Added CLI alias command `butler-to-merge` (primary command remains `butler`).
- Renamed reusable workflow to `.github/workflows/butler_policy.yml`.
- Removed report output environment override `BUTLER_REPORT_DIR`.
- Report output is standardised to `~/.cache/butler` when `HOME` is valid.
- Added safe fallback to `/tmp/butler` when `HOME` is missing, empty, non-absolute, or otherwise invalid.
- Reduced duplication in CI smoke helper wiring (`run_butler_with_mock_gh` now delegates to `run_butler`).

#### Why users should care

- Report path behaviour is now deterministic without extra per-run configuration.
- Misconfigured CI/container `HOME` values no longer break report generation.

#### What users must do now

1. Install using gem package name `butler-to-merge` (not `butler-governance`).
2. Use reusable workflow path `.github/workflows/butler_policy.yml` in client repository CI.
3. Stop setting `BUTLER_REPORT_DIR` in local scripts and CI jobs.
4. Read reports from `~/.cache/butler` in normal environments.
5. If running with unusual environment setup, ensure `HOME` is writable and absolute.

#### Breaking or removed behaviour

- `BUTLER_REPORT_DIR` is no longer recognised.

#### Upgrade steps

```bash
gem install --user-install butler-to-merge -v 0.3.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If `HOME` is invalid for cache path resolution, Butler falls back to `/tmp/butler`.

### Engineering Appendix

#### Public interface and config changes

- Removed `BUTLER_REPORT_DIR` handling from runtime configuration.
- `report_dir_path` now resolves to `~/.cache/butler` and falls back to `/tmp/butler` for invalid `HOME`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Replace any `BUTLER_REPORT_DIR=...` usage with `HOME=...` test isolation where needed.

#### Verification evidence

- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).

## 0.3.0 (2026-02-17)

### User Overview

#### What changed

- Added one-command initialisation: `butler init [repo_path]` (`hook` + `template apply` + `audit`).
- Default report output moved to `~/.cache/butler`.
- Outsider boundary now hard-blocks Butler-owned host artefacts (`.butler.yml`, `bin/butler`, `.tools/butler/*`).
- Installation/setup guidance now targets standard-user package-consumer flow.

#### Why users should care

- Faster setup for new repositories.
- Clearer outsider boundary between Butler runtime and client repositories.
- More predictable report output location for automation and CI.

#### What users must do now

1. Install Butler as a normal user executable (`butler` in `PATH`).
2. Initialise each repository with `butler init /local/path/of/repo`.
3. Remove forbidden Butler-owned artefacts from host repositories if reported.
4. Read reports from `~/.cache/butler`.

#### Breaking or removed behaviour

- Host `.butler.yml` is no longer accepted.
- Host `bin/butler` and `.tools/butler/*` are no longer accepted.
- Butler repository no longer relies on local `bin/butler` shim for normal usage.
- Command `run [repo_path]` has been removed; use `init [repo_path]`.

#### Upgrade steps

```bash
gem install --user-install butler-governance -v 0.3.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/butler" ~/.local/bin/butler
butler version

butler init /local/path/of/repo
butler audit
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If the default cache path is restricted, run Butler with a writable `HOME`.

### Engineering Appendix

#### Architecture changes

- CLI now dispatches directly to runtime behaviour methods; thin `lib/butler/commands/*` wrappers are removed.
- Runtime split into behaviour-owned concern files:
  - `lib/butler/runtime/local_ops.rb`
  - `lib/butler/runtime/audit_ops.rb`
  - `lib/butler/runtime/review_ops.rb`
- `lib/butler/runtime.rb` now focuses on wiring and shared helpers.

#### Public interface and config changes

- Command surface is `audit`, `sync`, `prune`, `hook`, `check`, `init`, `template`, `review`, `version`.
- Initialisation command: `init [repo_path]` (no `run` alias).
- Default report output: `~/.cache/butler`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Update automation expecting repo-local `tmp/butler` to `~/.cache/butler`.
- Remove any Butler-owned host artefacts from client repositories.

#### Verification evidence

- Ruby syntax checks pass across Butler Ruby source files.
- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).
- Installed-tool dogfooding path verified on local Butler repository clone.

#### Residual risk and follow-up

- `lib/butler/runtime/review_ops.rb` remains large because it contains both orchestration and GitHub response normalisation; further split by helper clusters is possible in later releases.

## 0.2.0 (2026-02-17)

### Added

- Ruby gem scaffolding (`butler.gemspec`, `lib/`, `exe/butler`) for outsider runtime delivery.
- Modular command and adapter structure under `lib/butler/commands/*` and `lib/butler/adapters/*`.
- Reusable policy workflow (current path: `.github/workflows/butler_policy.yml`) with exact version input.
- Outsider boundary enforcement that blocks Butler-owned artefacts in host repositories.

### Changed

- Runtime now uses built-in configuration only; host `.butler.yml` is no longer accepted.
- Hook runtime moved to global path `~/.butler/hooks/<version>/` with repo `core.hooksPath` pointing there.
- Template synchronisation now uses whole-file comparison and full-file apply for managed `.github/*`.
- Canonical template source moved to `templates/.github/*`.
- Hook source assets moved to `assets/hooks/*`.
- `bin/butler` is now a thin developer shim delegating to `exe/butler`.

### Removed

- Legacy alias command family previously mapped to template operations.
- Repository-local Butler wrapper bootstrap path in `script/bootstrap_repo_defaults.sh`.
- Legacy marker-based template model.

## 0.1.0 (2026-02-16)

### Added

- Formal project versioning with canonical root `VERSION` file.
- CLI version command support: `bin/butler version` and `bin/butler --version`.
- Smoke-test coverage that validates CLI version output against `VERSION`.
- Initial release record for Butler `0.1.0`.
