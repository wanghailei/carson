# Carson Release Notes

Release-note scope rule:

- `RELEASE.md` records only version deltas, breaking changes, and migration actions.
- Operational usage guides live in `MANUAL.md` and `API.md`.

## 0.9.0 (2026-02-25)

### User Overview

#### What changed

- Ruby lint policy path is now flat: source `CODING/rubocop.yml`, runtime `~/AI/CODING/rubocop.yml`.
- Ruby lint execution now runs through Carson-owned runtime code (`lib/carson/policy/ruby/lint.rb`).
- `carson audit` now hard-blocks outsider repositories that include repo-local `.rubocop.yml`.
- Default non-Ruby lint policy entries remain present but disabled, and use flat file names (`javascript.lint.js`, `css.lint.js`, `html.lint.js`, `erb.lint.rb`).
- Carson governance workflows now install a pinned RuboCop version before audit execution.

#### Why users should care

- Policy ownership is explicit: `~/AI/CODING` stores policy data, while Carson owns execution logic.
- A flat policy layout removes language-subdirectory drift and simplifies setup.
- Repo-local RuboCop policy overrides are now blocked to keep governance deterministic.

#### What users must do now

1. Upgrade Carson to `0.9.0`.
2. Ensure your policy source provides `CODING/rubocop.yml` and rerun `carson lint setup --source <path-or-git-url> --force`.
3. Remove repo-local `.rubocop.yml` files from governed repositories.
4. If you use Carson reusable workflow pins, set `carson_ref: v0.9.0`, `carson_version: 0.9.0`, and `rubocop_version`.

#### Breaking or removed behaviour

- Carson no longer uses `CODING/ruby/rubocop.yml` as the default Ruby policy source path.
- Carson no longer defaults non-Ruby policy paths to language subdirectories under `CODING/`.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.9.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
carson lint setup --source /path/to/ai-policy-repo --force
```

### Engineering Appendix

#### Public interface and config changes

- Default Ruby lint `config_files` path changed to `~/AI/CODING/rubocop.yml`.
- Default Ruby lint `command` now invokes Carson-owned runner code.
- Default non-Ruby lint policy paths now use flat file names under `~/AI/CODING/`.
- `carson audit` now blocks repo-local `.rubocop.yml` in outsider mode.
- Exit status contract remains unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- Ruby unit suite passed on Ruby `4.0.1` (`41 runs, 126 assertions, 0 failures`).
- Carson smoke suite passed on Ruby `4.0.1` (`Carson smoke tests passed.`).

## 0.8.0 (2026-02-25)

### User Overview

#### What changed

- Added config-driven multi-language lint governance via `lint.languages` in `~/.carson/config.json`.
- Added `carson lint setup --source <path-or-git-url> [--ref <git-ref>] [--force]` to seed `~/AI/CODING`.
- `carson audit` now enforces custom lint policy deterministically for staged/local and CI target files.
- Updated CI workflows to bootstrap lint policy from `wanghailei/ai` using `CARSON_READ_TOKEN`.
- Added CI naming guard to block legacy pre-rename token reintroduction outside historical release notes.

#### Why users should care

- Your own lint policy source (`~/AI/CODING`) is now enforced in both local hooks and GitHub checks.
- Drift between developer environments and CI lint behaviour is reduced by explicit setup and policy checks.
- Missing lint tools, missing policy files, or lint violations now stop merge-readiness with deterministic exits.

#### What users must do now

1. Upgrade Carson to `0.8.0`.
2. Run `carson lint setup --source <path-or-git-url>` on each machine that runs Carson locally.
3. Add `CARSON_READ_TOKEN` repository secret where CI calls Carson reusable workflow.
4. Update CI pins to `carson_ref: v0.8.0` and `carson_version: 0.8.0`.

#### Breaking or removed behaviour

- `carson audit` now hard-blocks when configured language lint command/tool is unavailable for targeted files.
- `carson audit` now hard-blocks when configured lint policy files are missing for targeted files.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.8.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
carson lint setup --source /path/to/ai-policy-repo
```

### Engineering Appendix

#### Public interface and config changes

- Added CLI command: `carson lint setup`.
- Added config schema section: `lint.languages`.
- Audit target selection precedence added for local, PR CI, and non-PR CI.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- Added unit coverage for lint config parsing, lint audit policy states, and lint setup source modes.
- Extended smoke coverage for lint setup (`--source` required, local source, git URL source).
- Extended smoke coverage for audit blocks on missing lint policy files and missing lint commands.

## 0.7.0 (2026-02-24)

### User Overview

#### What changed

- Removed marker-token content scanning from outsider boundary checks.
- Outsider boundary checks now target only explicit Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson`).
- Cleaned historical wording from documentation, smoke labels, and test fixtures.
- Clarified `github` as the canonical git remote name in onboarding guidance.
- Updated user-facing install and CI pin examples to `0.7.0`.

#### Why users should care

- Boundary enforcement is simpler and easier to reason about.
- Operational guidance now reflects configurable remote naming via `git.remote`.
- Install/pin examples now match the current Carson baseline.

#### What users must do now

1. Upgrade to `0.7.0` where Carson is pinned.
2. If you use a custom remote name, align Carson `git.remote` with that remote.
3. Update CI `carson_version` and `carson_ref` pins to `0.7.0` / `v0.7.0`.

#### Breaking or removed behaviour

- Marker-token content no longer contributes to outsider boundary policy blocks.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.7.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- Outsider boundary scan now checks explicit artefact paths only.

#### Verification evidence

- PR #44 merged with green required checks (`Carson governance`, `Syntax and smoke tests`).

## 0.6.1 (2026-02-24)

### User Overview

#### What changed

- Removed branch-name scope enforcement from commit-time governance and kept scope integrity path-group based.
- Improved hook-upgrade diagnostics and installer guidance when repositories are still pinned to an older Carson hooks path.
- Fixed scope guard conflict reporting so `violating_files` only lists true cross-core conflicts.
- Updated user-facing install/pin examples to `0.6.1`.

#### Why users should care

- Branch names are now informational only for scope checks, so commits are governed by actual feature/module path boundaries.
- Hook upgrade failure modes are easier to diagnose and fix locally.
- Scope integrity output is less noisy and more actionable.

#### What users must do now

1. Upgrade to `0.6.1` where Carson is pinned.
2. Re-run `carson hook` in governed repositories after upgrade.
3. Update CI `carson_version` pins to `0.6.1`.

#### Breaking or removed behaviour

- `CARSON_SCOPE_BRANCH_PATTERN` override support has been removed.
- `scope.branch_pattern` and `scope.lane_group_map` config keys are no longer consumed.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.6.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- Scope policy is now strictly changed-path based; branch-pattern controls are removed.
- Review acknowledgement and style overrides remain:
  `CARSON_REVIEW_DISPOSITION_PREFIX`, `CARSON_RUBY_INDENTATION`.

#### Verification evidence

- PR #40 merged with green required checks (`Carson policy`, `Syntax and smoke tests`).
- PR #41 merged with green required checks (`Carson policy`, `Syntax and smoke tests`).

## 0.6.0 (2026-02-23)

### User Overview

#### What changed

- Refactored runtime concerns from `*Ops` naming to neutral modules (`Local`, `Audit`, `Review`), and split review governance internals into dedicated support files.
- Added global user configuration loading from `~/.carson/config.json` with deterministic precedence:
  built-in defaults, then global config file, then environment overrides.
- Removed branch-name scope policy coupling; scope integrity now evaluates changed paths only (via `scope.path_groups`).
- Changed default review acknowledgement prefix from `Codex:` to `Disposition:`.
- Added Ruby stdlib unit tests for deterministic helper logic and integrated them in CI.
- Replaced static indentation regex checks with policy-based guard script (`script/ruby_indentation_guard.rb`).
- Hardened untracked/quoted-path handling.
- Added internal developer documentation for `~/.carson/config.json`.

#### Why users should care

- Carson is now more neutral and less coupled to a single agent naming workflow.
- User-space configuration is now explicit and predictable without adding repo-local Carson files.
- Review governance and helper logic are easier to maintain and reason about.
- CI catches deterministic logic regressions earlier through added unit tests.

#### What users must do now

1. Upgrade to `0.6.0` where you pin Carson explicitly.
2. If you relied on `Codex:` acknowledgement comments, set `CARSON_REVIEW_DISPOSITION_PREFIX=Codex:` (or `review.required_disposition_prefix` in `~/.carson/config.json`).

#### Breaking or removed behaviour

- Branch-name policy matching has been removed; branch names are informational only.
- Default review acknowledgement prefix no longer assumes `Codex:`.
- Internal planning document removed from the repository.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.6.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- New canonical global config path: `~/.carson/config.json`.
- New path override env var: `CARSON_CONFIG_FILE`.
- Added policy env overrides:
  `CARSON_REVIEW_DISPOSITION_PREFIX`, `CARSON_RUBY_INDENTATION`.
- Style policy supports `tabs`, `spaces`, or `either` through configuration.

#### Verification evidence

- PR #37 merged with both CI jobs green (`Carson governance`, `Syntax and smoke tests`).
- Unit tests run in CI via `ruby -Itest -e 'Dir.glob( "test/**/*_test.rb" ).sort.each { |path| require File.expand_path( path ) }'`.

## 0.5.1 (2026-02-22)

### User Overview

#### What changed

- Fixed source installer behaviour so running `./install.sh` no longer leaves `carson-<version>.gem` in the Carson repository root.
- Updated user-facing install and pin examples to `0.5.1`.

#### Why users should care

- Source installation now leaves Carson checkouts clean after install.
- Version guidance in onboarding docs now matches the latest published patch release.

#### What users must do now

1. Upgrade to `0.5.1` where you pin Carson explicitly.
2. No migration is required for existing `0.5.0` runtime/governance behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.5.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
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
- Added internal planning document for Carson rollout.
- Stabilised review sweep smoke fixtures with relative timestamps to remove date drift failures.

#### Why users should care

- Source-based onboarding is now a single command.
- Installation paths are clearer for end users versus contributors.
- Governance smoke coverage is more stable over time.

#### What users must do now

1. For source-based onboarding, run `./install.sh`.
2. For gem-based onboarding, pin and install `carson` at `0.5.0`.
3. No migration is required for existing `0.4.0` policy/runtime behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.5.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
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

- Added repository retirement command: `carson offboard [repo_path]`.
- `offboard` now removes Carson-managed host artefacts and Carson-specific files from client repositories.
- `offboard` unsets repo `core.hooksPath` only when it points to Carson-managed global hook paths.

#### Why users should care

- Retiring Carson from a repository is now one command.
- Re-onboarding with a newer Carson release is cleaner after explicit offboarding.

#### What users must do now

1. Use `carson offboard /local/path/of/repo` when removing Carson from a repository.
2. Re-run `carson init /local/path/of/repo` when re-onboarding later.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- Added command `offboard [repo_path]` to CLI surface.
- Added runtime methods `offboard!`, `disable_carson_hooks_path!`, `offboard_cleanup_targets`, and `remove_empty_offboard_directories!`.

#### Verification evidence

- CI smoke coverage includes `offboard` cleanup and idempotency checks.

## 0.3.2 (2026-02-18)

### User Overview

#### What changed

- Version baseline bumped to `0.3.2` ahead of offboard command implementation.

## 0.3.1 (2026-02-18)

### User Overview

#### What changed

- Renamed Carson gem package from `carson-governance` to `carson` (CLI command remains `carson`).
- Removed an extra CLI alias command.
- Renamed reusable workflow to `.github/workflows/carson_policy.yml`.
- Removed report output environment override `CARSON_REPORT_DIR`.
- Report output is standardised to `~/.cache/carson` when `HOME` is valid.
- Added safe fallback to `/tmp/carson` when `HOME` is missing, empty, non-absolute, or otherwise invalid.
- Reduced duplication in CI smoke helper wiring (`run_carson_with_mock_gh` now delegates to `run_carson`).

#### Why users should care

- Report path behaviour is now deterministic without extra per-run configuration.
- Misconfigured CI/container `HOME` values no longer break report generation.

#### What users must do now

1. Install using gem package name `carson` (not `carson-governance`).
2. Use reusable workflow path `.github/workflows/carson_policy.yml` in client repository CI.
3. Stop setting `CARSON_REPORT_DIR` in local scripts and CI jobs.
4. Read reports from `~/.cache/carson` in normal environments.
5. If running with unusual environment setup, ensure `HOME` is writable and absolute.

#### Breaking or removed behaviour

- `CARSON_REPORT_DIR` is no longer recognised.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.3.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If `HOME` is invalid for cache path resolution, Carson falls back to `/tmp/carson`.

### Engineering Appendix

#### Public interface and config changes

- Removed `CARSON_REPORT_DIR` handling from runtime configuration.
- `report_dir_path` now resolves to `~/.cache/carson` and falls back to `/tmp/carson` for invalid `HOME`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Replace any `CARSON_REPORT_DIR=...` usage with `HOME=...` test isolation where needed.

#### Verification evidence

- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).

## 0.3.0 (2026-02-17)

### User Overview

#### What changed

- Added one-command initialisation: `carson init [repo_path]` (`hook` + `template apply` + `audit`).
- Default report output moved to `~/.cache/carson`.
- Outsider boundary now hard-blocks Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson/*`).
- Installation/setup guidance now targets standard-user package-consumer flow.

#### Why users should care

- Faster setup for new repositories.
- Clearer outsider boundary between Carson runtime and client repositories.
- More predictable report output location for automation and CI.

#### What users must do now

1. Install Carson as a normal user executable (`carson` in `PATH`).
2. Initialise each repository with `carson init /local/path/of/repo`.
3. Remove forbidden Carson-owned artefacts from host repositories if reported.
4. Read reports from `~/.cache/carson`.

#### Breaking or removed behaviour

- Host `.carson.yml` is no longer accepted.
- Host `bin/carson` and `.tools/carson/*` are no longer accepted.
- Carson repository no longer relies on local `bin/carson` shim for normal usage.
- Command `run [repo_path]` has been removed; use `init [repo_path]`.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.3.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version

carson init /local/path/of/repo
carson audit
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If the default cache path is restricted, run Carson with a writable `HOME`.

### Engineering Appendix

#### Architecture changes

- CLI now dispatches directly to runtime behaviour methods; thin `lib/carson/commands/*` wrappers are removed.
- Runtime split into behaviour-owned concern files:
  - `lib/carson/runtime/local_ops.rb`
  - `lib/carson/runtime/audit_ops.rb`
  - `lib/carson/runtime/review_ops.rb`
- `lib/carson/runtime.rb` now focuses on wiring and shared helpers.

#### Public interface and config changes

- Command surface is `audit`, `sync`, `prune`, `hook`, `check`, `init`, `template`, `review`, `version`.
- Initialisation command: `init [repo_path]` (no `run` alias).
- Default report output: `~/.cache/carson`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Update automation expecting repo-local `tmp/carson` to `~/.cache/carson`.
- Remove any Carson-owned host artefacts from client repositories.

#### Verification evidence

- Ruby syntax checks pass across Carson Ruby source files.
- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).
- Installed-tool dogfooding path verified on local Carson repository clone.

#### Residual risk and follow-up

- `lib/carson/runtime/review_ops.rb` remains large because it contains both orchestration and GitHub response normalisation; further split by helper clusters is possible in later releases.

## 0.2.0 (2026-02-17)

### Added

- Ruby gem scaffolding (`carson.gemspec`, `lib/`, `exe/carson`) for outsider runtime delivery.
- Modular command and adapter structure under `lib/carson/commands/*` and `lib/carson/adapters/*`.
- Reusable policy workflow (current path: `.github/workflows/carson_policy.yml`) with exact version input.
- Outsider boundary enforcement that blocks Carson-owned artefacts in host repositories.

### Changed

- Runtime now uses built-in configuration only; host `.carson.yml` is no longer accepted.
- Hook runtime moved to global path `~/.carson/hooks/<version>/` with repo `core.hooksPath` pointing there.
- Template synchronisation now uses whole-file comparison and full-file apply for managed `.github/*`.
- Canonical template source moved to `templates/.github/*`.
- Hook source assets moved to `assets/hooks/*`.
- `bin/carson` is now a thin developer shim delegating to `exe/carson`.

### Removed

- Alias command family previously mapped to template operations.
- Repository-local Carson wrapper bootstrap path in `script/bootstrap_repo_defaults.sh`.
- Marker-based template model.

## 0.1.0 (2026-02-16)

### Added

- Formal project versioning with canonical root `VERSION` file.
- CLI version command support: `bin/carson version` and `bin/carson --version`.
- Smoke-test coverage that validates CLI version output against `VERSION`.
- Initial release record for Carson `0.1.0`.
