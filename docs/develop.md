# Carson Development Guide

## Audience
This document is for Carson contributors and internal maintainers who need architecture, runtime contract, and development workflow guidance.

## Housemove handoff snapshot (2026-02-25)
1. Product identity:
Product name is Carson.
Canonical repository is `wanghailei/carson` (local checkout directory may still use an older folder name).

2. Locked operating model:
Carson is outsider-only: no Carson-owned artefacts should live in client repositories.
Allowed persistence in client repositories is GitHub-native managed files only.
Runtime is `rbenv` Ruby `>= 4.0`.
Exit contract is fixed:
- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

3. Governance and review policy:
Merge readiness is blocked by unresolved actionable review items (`review gate`).
Scheduled late-comment detection exists (`review sweep`).
Disposition replies must reference target URLs and use the configured prefix.
Branch hygiene and prune policy is enforced.

4. Major delivered versions:
`v0.7.0` release/tag published.
`v0.8.0` release/tag published.
`0.8.0` adds custom multi-language lint governance:
- `carson lint setup --source ...`
- `~/.carson/config.json` `lint.languages`
- deterministic blocking on missing config, missing tooling, and lint failures
- local plus GitHub CI enforcement

5. Latest integration outcome:
PR `#49` merged to `main` at commit `19b0713`.
Required checks passed before merge (`Carson governance`, `Syntax and smoke tests`).
Review threads were resolved and disposition acknowledgements completed.
Local repository is clean on `main`; no open PRs.

6. Fresh install status:
Carson `0.8.0` is installed locally.
Executable is on `PATH`: `~/.rbenv/shims/carson`.
`carson version` returns `0.8.0`.
Fresh isolated smoke verification (lint setup, hook, and check) passed.

7. Lessons promoted:
Never put markdown/backticks directly into shell CLI body strings.
Always use temp files plus `--body-file` or `--notes-file` for PR/release text.
Temp artefacts should go to `~/.cache` by default, with `/tmp` only as fallback.

## Architectural overview
Primary runtime structure:
- `exe/carson`: executable entrypoint.
- `lib/carson/cli.rb`: command parsing and dispatch.
- `lib/carson/runtime.rb`: runtime wiring, shared helpers, and concern loading.
- `lib/carson/runtime/local.rb`: local governance commands and hook/template operations.
- `lib/carson/runtime/audit.rb`: governance audit and reporting.
- `lib/carson/runtime/review.rb` plus `lib/carson/runtime/review/*.rb`: review gate/sweep flow, data access, query text, and support helpers.
- `lib/carson/config.rb`: defaults, config loading, environment overrides, and validation.
- `lib/carson/adapters/git.rb`, `lib/carson/adapters/github.rb`: process adapters for `git` and `gh`.

## Runtime contracts
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

## Core command flow
1. `init` sets baseline (`hook`, `template apply`, `audit`) for a target repository.
2. `audit` evaluates governance state and policy compliance.
3. `sync` fast-forwards local `main` from configured remote.
4. `prune` removes stale local branches tracking deleted upstream refs.
5. `review gate` enforces actionable-review discipline.
6. `review sweep` updates rolling tracking for late actionable review activity.
7. `offboard` removes Carson-managed host artefacts and Carson hook linkage.

## Development workflow
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

## Release and compatibility notes
- Keep CLI behaviour backwards-compatible where possible.
- Document user-visible deltas and migration steps in `RELEASE.md`.
- Keep example version pins in root docs aligned with `VERSION`.

## Internal guardrails
- Maintain outsider runtime boundary; do not introduce Carson-owned host artefacts.
- Prefer deterministic outputs suitable for CI parsing and operational triage.
- Keep command responsibilities grouped by behaviour ownership rather than arbitrary line count targets.

## References
- `README.md`
- `MANUAL.md`
- `API.md`
- `RELEASE.md`
- `VERSION`
- `lib/carson/cli.rb`
- `lib/carson/runtime.rb`
- `lib/carson/runtime/local.rb`
- `lib/carson/runtime/audit.rb`
- `lib/carson/runtime/review.rb`
- `lib/carson/config.rb`
