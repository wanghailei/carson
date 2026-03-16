# Carson Development Note

## Audience

This document is a development note only. It is for WHL and coding agents who need architecture, runtime contract, and implementation guidance. It is not a public manual or a feature specification.

## Architectural Overview

Primary runtime structure:
- `exe/carson`: executable entrypoint.
- `lib/carson/cli.rb`: command parsing and dispatch.
- `lib/carson/runtime.rb`: runtime wiring, shared helpers, and concern loading.
- `lib/carson/runtime/local.rb`: local governance commands and hook/template operations.
- `lib/carson/runtime/audit.rb`: governance audit and reporting.
- `lib/carson/runtime/review.rb` plus `lib/carson/runtime/review/*.rb`: review gate/sweep flow, data access, query text, and support helpers.
- `lib/carson/config.rb`: defaults, config loading, environment overrides, and validation.
- `lib/carson/runtime/govern.rb`: portfolio-level delivery oversight, revision dispatch, and integration loop.
- `lib/carson/adapters/git.rb`, `lib/carson/adapters/github.rb`: process adapters for `git` and `gh`.
- `lib/carson/adapters/agent.rb`, `lib/carson/adapters/prompt.rb`: agent work order definitions and shared prompt builder.
- `lib/carson/adapters/codex.rb`, `lib/carson/adapters/claude.rb`: coding agent dispatch adapters.
- `lib/carson/repository.rb`, `lib/carson/branch.rb`, `lib/carson/delivery.rb`, `lib/carson/revision.rb`: passive domain objects for repository, branch, delivery, and revision state.
- `lib/carson/ledger.rb`: JSON file-backed ledger for active deliveries and revisions, with automatic import for legacy SQLite state.

## Architecture rationale

The layering is a direct consequence of the outsider boundary rule. Carson must never accumulate repository-specific state — it must be safe to invoke against any repository without side effects from a previous invocation. This constraint shapes every layer boundary.

**CLI is stateless.** `cli.rb` only parses arguments and dispatches. It holds no repository state between calls. This makes it trivially testable with a `FakeRuntime` double — the CLI layer can be tested without any filesystem, git, or network interaction.

**Runtime is wired once per invocation.** `Runtime` is constructed with `repo_root`, `tool_root`, output streams, and adapters at startup. Everything downstream receives the wired instance. There is no global state. This means tests can construct isolated runtimes pointing at `tmpdir` paths without any coordination between tests.

**Adapters absorb process calls.** `git.rb` and `github.rb` wrap every `git` and `gh` shell invocation in the core command layer. The boundary between pure Ruby logic and external process calls is explicit and auditable. `govern.rb` is a known exception: it predates strict adapter discipline and calls `Open3.capture3` directly in six places. New commands should use the adapter layer; govern's direct calls are tolerated but not encouraged.

**`govern.rb` is deliberately isolated.** Govern runs a long, stateful loop that reads from GitHub and potentially mutates PRs. Isolating it prevents its complexity from contaminating the synchronous local commands. Local commands (`audit`, `review gate`, `sync`) are fast, deterministic, and offline-capable. Govern is explicitly asynchronous, network-dependent, and advisory.

## Product architecture

**Carson is for coding agents, not for humans.** The primary user of Carson's commands and lifecycle management is the coding agent working on behalf of the developer. Carson is confident because it is professional and knows things deeply well. It does not hedge, guess, or ask unnecessary questions. It acts with the certainty of a butler who has managed the household for decades. The human owner benefits indirectly: when Carson keeps the agent's environment disciplined and predictable, the agent produces better work, and the human never has to intervene in housekeeping.

**Single-repo depth is the core.** Working on one repository thoroughly well is the essence and the foundation. Multi-repo governance is the same discipline repeated across the estate. Get the single-repo story perfect first; multi-repo follows naturally with `--all`.

**`--all` is the elegant extension.** Every command that works on a single repository gains cross-repo reach through a single `--all` flag. No separate commands, no different mental model — same operation, wider scope.

**Branch delivery is first-class.** The branch is the delivery unit. Worktree is only the isolation container. Carson owns the full branch/worktree lifecycle: create, track, deliver, and clean up.

## Iron Rule — no Python rewrite scripts for Ruby source

Carson's runtime is Ruby. Coding agents must not use Python or other blind text-rewrite scripts to edit Carson Ruby files.

This is forbidden because the failure mode is structural corruption: a generic rewrite can delete or misplace closing `end` statements while leaving the file superficially plausible.

For Carson Ruby source:
- use scoped patches or Ruby-aware edits
- keep the change boundary narrow enough to inspect directly
- prove the file still parses immediately after structural edits with `ruby -c` or the targeted test that loads the file

### Three-layer command model

| Layer | Scope | Trigger | Examples |
|-------|-------|---------|----------|
| **1. Granular** | Single repo | Explicit command | `refresh`, `housekeep`, `template check`, `deliver`, `prune`, `audit`, `sync`, `status` |
| **2. Batch** | All governed repos | `--all` flag | `refresh --all`, `housekeep --all`, `prune --all`, `audit --all`, `sync --all`, `status --all`, `template check --all` |
| **3. Automation** | All governed repos | Event-driven | Canonical config change triggers propagation, post-upgrade refresh, scheduled hygiene |

Layer 1 is the foundation — every command works perfectly on one repo. Layer 2 extends the same operation across the portfolio with `--all`. Layer 3 (future) removes the need for even the `--all` flag by triggering operations automatically on events.

### Scope

**In-scope capabilities:**
- Layer 1 commands (`onboard`, `audit`, `sync`, `prune`, `template`, `review`, `offboard`, `refresh`, `status`, `deliver`, `housekeep`, `worktree`).
- Layer 2 batch commands (`refresh --all`, `audit --all`, `sync --all`, `prune --all`, `status --all`, `template check --all`, `housekeep --all`).
- Portfolio governance commands (`govern`).
- Review governance via `review gate` and `review sweep`.
- Whole-file management of selected GitHub-native policy files under `.github/*`.
- Strict exit status contract suitable for automation.

**Out-of-scope capabilities:**
- Supporting governed non-squash integration policies. Carson's governed delivery contract is squash-only.
- Deciding business-domain policy for host repositories.
- Executing force merges or bypassing required checks.
- Persisting Carson-specific configuration inside host repositories.

## Carson 3.0 — Theme

**Carson is for coding agents.** The primary consumer of Carson's commands, lifecycle management, and governance is the coding agent — not the human developer directly. What makes working with agents best, therefore makes the human owners most happy with no burden, Carson should handle.

**Overseer model.** Carson's current model is per-repo: `carson onboard` sets up each repository individually. The 3.0 model is central oversight: repositories are *registered* under Carson's protection, and Carson oversees all of them by default. This makes cross-repo operations natural — you never need to know which repo you're standing in to manage the estate. The vocabulary shifts from "onboard" to "register."

**Licensing.** Commercial use may require a paid licence in 3.0. Open-source and personal use remain free.

## Adding a new command

Each command follows the same four-step pattern. Using a hypothetical `carson status` command as an example:

**Step 1 — Parse the argument in `cli.rb`.**

Add a `when` branch in `parse_command` to recognise the token:

```ruby
when "status"
  { command: "status" }
```

Add a dispatch case in `dispatch`:

```ruby
when "status"
  runtime.status!
```

**Step 2 — Add the method to `FakeRuntime` in `cli_test.rb`.**

```ruby
def status!
  @calls << :status
  Carson::Runtime::EXIT_OK
end
```

**Step 3 — Write the CLI dispatch test.**

```ruby
def test_status_dispatches
  fake = FakeRuntime.new
  out = StringIO.new
  result = Carson::CLI.dispatch( parsed: { command: "status" }, runtime: fake )
  assert_includes fake.calls, :status
  assert_equal Carson::Runtime::EXIT_OK, result
end
```

**Step 4 — Implement `status!` in the appropriate runtime file.**

Choose the file by behaviour ownership: local governance → `local.rb`, audit-related → `audit.rb`, review-related → `review.rb`. If the command is genuinely new domain, create a new `runtime/<name>.rb` and include it in `runtime.rb`.

The method must:
- Write all output to `@out` or `@err` (never `$stdout`).
- Return `EXIT_OK`, `EXIT_ERROR`, or `EXIT_BLOCK` — nothing else.
- Prefix all output lines with `BADGE`.

**Step 5 — Write the runtime test.**

Use `build_runtime` from `test_helper.rb` to get an isolated tmpdir-backed runtime:

```ruby
runtime, repo_root = build_runtime
result = runtime.status!
assert_equal Carson::Runtime::EXIT_OK, result
destroy_runtime_repo( repo_root: repo_root )
```

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

1. **`carson audit` passes (exit 0)** — governance is clean. This covers outsider boundary enforcement (no Carson artefacts in the host repo) and template drift detection. Carson owns this entirely.
2. **`carson review gate` passes (exit 0)** — all actionable review comments are resolved. Every risk keyword and change request from reviewers has a disposition comment from the PR author. Carson owns this entirely.
3. **All GitHub required status checks green** — the repository's own CI: test suite, build steps, type checking, and any other checks the repository defines. Carson does not own these; it queries their status via `gh`.

The first two are Carson-governed. The third is repository-governed. All three must pass before Carson can safely merge. Without the third condition, Carson could merge a PR that passes governance but has failing tests.

## Autonomous Governance Loop

`carson govern` runs a triage-dispatch-verify cycle across a portfolio of repositories. It classifies each open PR, dispatches coding agents to fix issues, and merges PRs that pass all gates. With `--loop SECONDS`, Carson runs this cycle continuously — sleeping between cycles, isolating errors per cycle, and exiting cleanly on `Ctrl-C` or `SIGTERM`.

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
        │ sync +    │     │ GitHub CI     │
        │ prune     │     │ runs checks   │
        │           │     └───────┬───────┘
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
│  carson onboard /path/to/repo                                   │
│    ├── refresh  (install hooks, write workflow_style flag)       │
│    ├── template apply  (sync .github/* files)                   │
│    ├── audit  (first governance check)                          │
│    └── guidance  (print workflow style, config hints)            │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  2. LOCAL WORK                                                  │
│                                                                 │
│  code → git add → git commit                                    │
│    ├── pre-commit hook  → carson audit (boundary)  │
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
│    │    ├── ready        → merge + sync + prune                 │
│    │    ├── ci_failing   → gather CI logs → dispatch agent      │
│    │    ├── review_blocked → gather findings → dispatch agent   │
│    │    └── pending      → skip (wait for checks)               │
│    ├── sync + prune (fast-forward main, remove stale branches)  │
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

1. `onboard` sets baseline (`refresh`, `template apply`, `audit`) for a target repository.
2. `audit` evaluates governance state and policy compliance.
3. `sync` fast-forwards local `main` from configured remote.
4. `prune` removes stale local branches tracking deleted upstream refs.
5. `review gate` enforces actionable-review discipline.
6. `review sweep` updates rolling tracking for late actionable review activity.
7. `offboard` removes Carson-managed host artefacts and Carson hook linkage.

## Testing approach

Carson's test suite uses Minitest with no external test framework dependencies. Tests are fast, isolated, and filesystem-safe by convention.

**Three test categories:**

1. **CLI dispatch tests** (`cli_test.rb`) — verify that argument strings reach the correct runtime method with the correct parameters. Use `FakeRuntime` exclusively. No filesystem, no network.

2. **Runtime unit tests** (`runtime_*_test.rb`) — verify runtime method behaviour against a real `Runtime` instance backed by a `tmpdir`. Each test constructs its own directory via `build_runtime` and tears it down after. Tests are independent and safe to run in any order.

3. **Smoke tests** (`script/ci_smoke.sh`, `script/review_smoke.sh`) — end-to-end invocations of the `carson` binary against real filesystem structures. These run in CI and are the last gate before release.

**Test isolation conventions:**

- Never use `$stdout` or `$stderr` directly. Always capture via `StringIO` (`out`, `err` from `build_runtime`).
- Never write to the real `~/.carson/config.json` in tests. `test_helper.rb` sets `CARSON_CONFIG_FILE` to a nonexistent tmpdir path at load time, making all tests use a blank config.
- Use `with_env` from `CarsonTestSupport` to temporarily set environment variables. It restores the previous state after the block even if the test raises.
- Scope assertions to the command under test. Do not assert on incidental output from unrelated methods.

**Running a single test file:**

```bash
ruby -Itest test/runtime_audit_baseline_test.rb
```

**Running the full suite:**

```bash
ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |path| require File.expand_path(path) }'
```

## Development Workflow

Local setup:

```bash
ruby -v
```

Package build check without leaving a repo-root artefact:

```bash
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/carson-build-XXXXXX")"
gem build carson.gemspec --output "$package_dir/carson-$(cat VERSION).gem"
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

Run smoke commands from a shell where `ruby -v` resolves to the repo-selected Ruby runtime (for example via `.ruby-version` and your version manager). The smoke scripts intentionally stop when `ruby` resolves below Carson's supported floor.

Source installation for dogfooding:

```bash
./install.sh
carson version
```

`./install.sh` already builds into an ephemeral work directory. A leftover `carson-<version>.gem` in the repo root comes from a manual `gem build carson.gemspec` run, not from the installer.

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
