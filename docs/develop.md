# Carson Development Guide

## Audience

This document is for Carson contributors and internal maintainers who need architecture, runtime contract, and development workflow guidance.

## Architectural Overview

Primary runtime structure:
- `exe/carson`: executable entrypoint.
- `lib/carson/cli.rb`: command parsing and dispatch.
- `lib/carson/runtime.rb`: runtime wiring, shared helpers, and concern loading.
- `lib/carson/runtime/local.rb`: local governance commands and hook/template operations.
- `lib/carson/runtime/audit.rb`: governance audit and reporting.
- `lib/carson/runtime/review.rb` plus `lib/carson/runtime/review/*.rb`: review gate/sweep flow, data access, query text, and support helpers.
- `lib/carson/config.rb`: defaults, config loading, environment overrides, and validation.
- `lib/carson/adapters/git.rb`, `lib/carson/adapters/github.rb`: process adapters for `git` and `gh`.

## Runtime Contracts

Exit status contract:
- `0`: success
- `1`: runtime/configuration error
- `2`: policy blocked (hard stop)

Outsider boundary contract:
- host repositories must not contain `.carson.yml`, `bin/carson`, or `.tools/carson/*`
- host repositories may contain managed GitHub-native files under `.github/*`

Configuration contract:
- default config path: `~/.carson/config.json`
- override path via `CARSON_CONFIG_FILE`
- precedence: built-in defaults, then global config file, then environment overrides

## Merge-Readiness Model

A PR is merge-ready when three independent conditions are satisfied:

1. **`carson audit` passes (exit 0)** — governance is clean. This covers lint policy compliance, scope integrity (staged changes stay within expected path boundaries), and outsider boundary enforcement (no Carson artefacts in the host repo). Carson owns this entirely.
2. **`carson review gate` passes (exit 0)** — all actionable review comments are resolved. Every risk keyword and change request from reviewers has a disposition comment from the PR author. Carson owns this entirely.
3. **All GitHub required status checks green** — the repository's own CI: test suite, build steps, type checking, and any other checks the repository defines. Carson does not own these; it queries their status via `gh`.

The first two are Carson-governed. The third is repository-governed. All three must pass before Carson can safely merge. Without the third condition, Carson could merge a PR that passes governance but has failing tests.

## Core Command Flow

1. `init` sets baseline (`hook`, `template apply`, `audit`) for a target repository.
2. `audit` evaluates governance state and policy compliance.
3. `sync` fast-forwards local `main` from configured remote.
4. `prune` removes stale local branches tracking deleted upstream refs.
5. `review gate` enforces actionable-review discipline.
6. `review sweep` updates rolling tracking for late actionable review activity.
7. `offboard` removes Carson-managed host artefacts and Carson hook linkage.

## Development Workflow

Local setup:

```bash
ruby -v
gem build carson.gemspec
```

Run test suite:

```bash
ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |path| require File.expand_path(path) }'
```

Run smoke verification:

```bash
script/ci_smoke.sh
script/review_smoke.sh
```

Source installation for dogfooding:

```bash
./install.sh
carson version
```

## Release and Compatibility Notes

- Keep CLI behaviour backwards-compatible where possible.
- Document user-visible deltas and migration steps in `RELEASE.md`.
- Keep example version pins in root docs aligned with `VERSION`.

## Internal Guardrails

- Maintain outsider runtime boundary; do not introduce Carson-owned host artefacts.
- Prefer deterministic outputs suitable for CI parsing and operational triage.
- Keep command responsibilities grouped by behaviour ownership rather than arbitrary line count targets.

## References

- `README.md` — mental model, command overview, quickstart.
- `MANUAL.md` — installation, daily operations, troubleshooting.
- `API.md` — formal interface contract.
- `RELEASE.md` — version history.
- `docs/define.md` — product definition and scope.
- `docs/design.md` — experience and brand design.
- `VERSION`
- `lib/carson/cli.rb`
- `lib/carson/runtime.rb`
- `lib/carson/runtime/local.rb`
- `lib/carson/runtime/audit.rb`
- `lib/carson/runtime/review.rb`
- `lib/carson/config.rb`
