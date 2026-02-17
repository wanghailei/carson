# Butler Release Notes

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
