# Butler Release Notes

Release-note scope rule:

- `RELEASE.md` records only version deltas, breaking changes, and migration actions.
- Operational usage guides live in `docs/butler_user_guide.md`.

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
- Reusable governance workflow (`.github/workflows/governance-reusable.yml`) with exact version input.
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
