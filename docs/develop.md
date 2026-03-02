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
- `lib/carson/runtime/govern.rb`: autonomous portfolio-level triage, dispatch, and merge loop.
- `lib/carson/adapters/git.rb`, `lib/carson/adapters/github.rb`: process adapters for `git` and `gh`.
- `lib/carson/adapters/agent.rb`, `lib/carson/adapters/prompt.rb`: agent work order definitions and shared prompt builder.
- `lib/carson/adapters/codex.rb`, `lib/carson/adapters/claude.rb`: coding agent dispatch adapters.

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

## Autonomous Governance Loop

`carson govern` runs a triage-dispatch-verify cycle across a portfolio of repositories. It classifies each open PR, dispatches coding agents to fix issues, and merges PRs that pass all gates. With `--loop SECONDS`, Carson runs this cycle continuously — sleeping between cycles, isolating errors per cycle, and exiting cleanly on `Ctrl-C`.

```
                 ┌─────────────────────────────────────────┐
                 │           carson govern cycle            │
                 └────────────────┬────────────────────────┘
                                  │
                                  ▼
                        ┌─────────────────┐
                        │  list open PRs  │◄──── gh pr list
                        └────────┬────────┘
                                 │
                    ┌────────────▼────────────┐
                    │   classify each PR      │
                    │  (CI, review, audit)     │
                    └──┬─────┬─────┬─────┬────┘
                       │     │     │     │
              ┌────────┘     │     │     └────────┐
              ▼              ▼     ▼              ▼
          ┌───────┐   ┌──────────┐ ┌──────────┐ ┌─────────┐
          │ ready │   │ci_failing│ │ review   │ │ pending │
          │       │   │          │ │ _blocked │ │         │
          └───┬───┘   └────┬─────┘ └────┬─────┘ └────┬────┘
              │            │            │             │
              ▼            ▼            ▼             ▼
          ┌───────┐   ┌──────────┐ ┌──────────┐   skip
          │ merge │   │ gather   │ │ gather   │  (wait for
          │  PR   │   │ CI logs  │ │ review   │   checks)
          └───┬───┘   │ evidence │ │ evidence │
              │       └────┬─────┘ └────┬─────┘
              │            │            │
              │            ▼            ▼
              │       ┌──────────────────────┐
              │       │  dispatch agent      │
              │       │  (Codex or Claude)   │
              │       │  with work order     │
              │       └──────────┬───────────┘
              │                  │
              │                  ▼
              │            ┌───────────┐
              │            │  agent    │
              │            │  pushes   │──── push to PR branch
              │            │  fix      │
              │            └─────┬─────┘
              │                  │
              ▼                  ▼
        ┌───────────┐     ┌───────────────┐
        │housekeep  │     │ GitHub CI     │
        │(sync +    │     │ runs checks   │
        │ prune)    │     └───────┬───────┘
        └───────────┘             │
                                  ▼
                         next govern cycle
                         picks up results
```

**Participants:**

- **Carson govern** — the orchestrator. Runs on a schedule or manually. Reads PR state from GitHub, classifies, decides action, gathers evidence, dispatches agents, and merges when ready.
- **Coding agent (Codex/Claude)** — receives a structured work order containing the PR context, CI failure logs or review comments, and any prior failed attempt details. Operates autonomously on the repository to push a fix.
- **GitHub** — source of truth for PR state, CI status, and review decisions. Carson reads from GitHub via `gh` CLI and writes back only through merges and agent pushes.

**Work order flow:**

Before dispatching an agent, Carson gathers evidence specific to the objective:

- `fix_ci`: fetches the failed CI run via `gh run list --status failure`, then retrieves the failure logs via `gh run view --log-failed`. The tail of the log (up to 8,000 chars) is included in the work order.
- `address_review`: fetches full PR review data via GraphQL — unresolved threads and actionable top-level findings. Each finding's body text is included (up to 2,000 chars each).
- If a prior dispatch for the same PR failed, the previous attempt summary is included so the agent can avoid repeating the same approach.

**Check wait:**

When checks are pending and the PR was recently updated (within `govern.check_wait` seconds, default 30), Carson classifies the PR as `pending` and skips it. This prevents premature dispatch while GitHub bots and CI are still posting results.

## User Journey — Full Lifecycle

```
┌─────────────────────────────────────────────────────────────────┐
│  1. INSTALL & ONBOARD                                           │
│                                                                 │
│  gem install carson                                             │
│  carson lint setup --source <policy-repo>                       │
│  carson onboard /path/to/repo                                   │
│    ├── prepare  (copy hooks, write workflow_style flag)          │
│    ├── template apply  (sync .github/* files)                   │
│    ├── audit  (first governance check)                          │
│    └── guidance  (print workflow style, config hints)            │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  2. LOCAL WORK                                                  │
│                                                                 │
│  code → git add → git commit                                    │
│    ├── pre-commit hook  → carson audit (lint, scope, boundary)  │
│    └── prepare-commit-msg hook                                  │
│         ├── trunk mode  → allow (exit 0)                        │
│         └── branch mode → block commits on main/master          │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  3. PUSH & PR                                                   │
│                                                                 │
│  git push                                                       │
│    └── pre-push hook                                            │
│         ├── trunk mode  → allow (exit 0)                        │
│         └── branch mode → block direct push to main/master      │
│  → GitHub CI runs carson audit (same checks as local)           │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  4. REVIEW GATE                                                 │
│                                                                 │
│  carson review gate                                             │
│    ├── quick-check  → if all resolved, skip warmup              │
│    ├── warmup       → wait (default 10s) for bot posts          │
│    ├── poll loop    → snapshot, compare, converge               │
│    │    └── bot-aware: skip comments from configured bots       │
│    └── verdict      → OK (merge-ready) or BLOCK (reasons)       │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  5. GOVERN CYCLE                                                │
│                                                                 │
│  carson govern                                                  │
│    ├── list open PRs across portfolio (gh pr list)              │
│    ├── classify each PR (CI / review / audit status)            │
│    │    ├── ready        → merge + housekeep                    │
│    │    ├── ci_failing   → gather CI logs → dispatch agent      │
│    │    ├── review_blocked → gather findings → dispatch agent   │
│    │    └── pending      → skip (wait for checks)               │
│    ├── housekeep (sync main + prune stale branches)             │
│    └── next cycle picks up agent push results                   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  6. MAINTENANCE                                                 │
│                                                                 │
│  carson refresh     (re-apply hooks + templates after upgrade)  │
│  carson review sweep (scan recent PRs for late feedback)        │
│  carson offboard    (remove Carson from a repository)           │
└─────────────────────────────────────────────────────────────────┘
```

## Core Command Flow

1. `onboard` sets baseline (`prepare`, `template apply`, `audit`) for a target repository.
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
- `lib/carson/runtime/govern.rb`
- `lib/carson/config.rb`
- `lib/carson/adapters/prompt.rb`
