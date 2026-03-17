# Carson Development Guide

> **Purpose:** How to work on Carson — architecture, patterns, testing, workflow.
> **Audience:** Coding agents maintaining Carson.

See `define.md` for what Carson is. See `spec.md` for how each feature works.

---

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

## Architecture Rationale

The layering is a direct consequence of the outsider boundary rule. Carson must never accumulate repository-specific state — it must be safe to invoke against any repository without side effects from a previous invocation. This constraint shapes every layer boundary.

**CLI is stateless.** `cli.rb` only parses arguments and dispatches. It holds no repository state between calls. This makes it trivially testable with a `FakeRuntime` double — the CLI layer can be tested without any filesystem, git, or network interaction.

**Runtime is wired once per invocation.** `Runtime` is constructed with `repo_root`, `tool_root`, output streams, and adapters at startup. Everything downstream receives the wired instance. There is no global state. This means tests can construct isolated runtimes pointing at `tmpdir` paths without any coordination between tests.

**Adapters absorb process calls.** `git.rb` and `github.rb` wrap every `git` and `gh` shell invocation in the core command layer. The boundary between pure Ruby logic and external process calls is explicit and auditable. `govern.rb` is a known exception: it predates strict adapter discipline and calls `Open3.capture3` directly in six places. New commands should use the adapter layer; govern's direct calls are tolerated but not encouraged.

**`govern.rb` is deliberately isolated.** Govern runs a long, stateful loop that reads from GitHub and potentially mutates PRs. Isolating it prevents its complexity from contaminating the synchronous local commands. Local commands (`audit`, `review gate`, `sync`) are fast, deterministic, and offline-capable. Govern is explicitly asynchronous, network-dependent, and advisory.

## Iron Rule — No Python Rewrite Scripts for Ruby Source

Carson's runtime is Ruby. Coding agents must not use Python or other blind text-rewrite scripts to edit Carson Ruby files.

The failure mode is structural corruption: a generic rewrite can delete or misplace closing `end` statements while leaving the file superficially plausible.

For Carson Ruby source:
- Use scoped patches or Ruby-aware edits.
- Keep the change boundary narrow enough to inspect directly.
- Prove the file still parses immediately after structural edits with `ruby -c` or the targeted test that loads the file.

## Adding a New Command

Each command follows the same pattern:

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

**Step 4 — Implement in the appropriate runtime file.**

Choose by behaviour ownership: local governance → `local.rb`, audit → `audit.rb`, review → `review.rb`. New domain → new `runtime/<name>.rb`, include in `runtime.rb`.

The method must:
- Write all output to `@out` or `@err` (never `$stdout`).
- Return `EXIT_OK`, `EXIT_ERROR`, or `EXIT_BLOCK` — nothing else.
- Prefix all output lines with `BADGE`.

**Step 5 — Write the runtime test.**

Use `build_runtime` from `test_helper.rb`:

```ruby
runtime, repo_root = build_runtime
result = runtime.status!
assert_equal Carson::Runtime::EXIT_OK, result
destroy_runtime_repo( repo_root: repo_root )
```

## Runtime Contracts

Exit status:
- `0`: success
- `1`: runtime/configuration error
- `2`: policy blocked (hard stop)

Outsider boundary:
- Host repositories must not contain `.carson.yml`, `bin/carson`, or `.tools/carson/*`.
- Host repositories may contain managed GitHub-native files under `.github/*`.

Configuration:
- Default config path: `~/.carson/config.json`.
- Override via `CARSON_CONFIG_FILE`.
- Precedence: built-in defaults → global config file → environment overrides.

## Testing

Carson uses Minitest with no external test framework dependencies. Tests are fast, isolated, and filesystem-safe.

**Three categories:**

1. **CLI dispatch tests** (`cli_test.rb`) — argument strings reach the correct runtime method. Uses `FakeRuntime`. No filesystem, no network.

2. **Runtime unit tests** (`runtime_*_test.rb`) — runtime methods against a real `Runtime` backed by `tmpdir`. Each test builds and tears down its own directory.

3. **Smoke tests** (`script/ci_smoke.sh`, `script/review_smoke.sh`) — end-to-end binary invocations. Run in CI as the last gate.

**Isolation conventions:**
- Never use `$stdout`/`$stderr` directly. Capture via `StringIO`.
- Never write to the real `~/.carson/config.json`. `test_helper.rb` sets `CARSON_CONFIG_FILE` to a nonexistent tmpdir path.
- Use `with_env` from `CarsonTestSupport` for temporary environment variables.
- Scope assertions to the command under test.

**Running tests:**

```bash
# Single file
ruby -Itest test/runtime_audit_baseline_test.rb

# Full suite
ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |path| require File.expand_path(path) }'
```

## Development Workflow

```bash
# Check Ruby version
ruby -v

# Build package (without repo-root artefact)
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/carson-build-XXXXXX")"
gem build carson.gemspec --output "$package_dir/carson-$(cat VERSION).gem"

# Smoke verification
script/ci_smoke.sh
script/review_smoke.sh

# Source installation for dogfooding
./install.sh
carson version
```

## Release and Compatibility

- Keep CLI behaviour backwards-compatible where possible.
- Document user-visible deltas in `RELEASE.md`.
- Keep example version pins in root docs aligned with `VERSION`.

## Internal Guardrails

- Maintain outsider runtime boundary.
- Prefer deterministic outputs suitable for CI parsing.
- Keep command responsibilities grouped by behaviour ownership.

## References

- `README.md` — mental model, command overview, quickstart.
- `MANUAL.md` — installation, daily operations, troubleshooting.
- `API.md` — formal interface contract.
- `RELEASE.md` — version history.
- `docs/define.md` — what Carson is.
- `docs/spec.md` — how each feature works.
