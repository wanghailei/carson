# Carson API

This document defines Carson's user-facing interface contract for CLI commands, configuration inputs, and exit behaviour.
For operational usage and daily workflows, see `MANUAL.md`.

## Command interface

Command form:

```bash
carson <command> [subcommand] [arguments]
```

### Setup commands

| Command | Purpose |
|---|---|
| `carson setup` | Interactive quiz to configure remote, main branch, workflow, and canonical lint-policy path. Writes `~/.carson/config.json`. |
| `carson onboard [repo_path]` | Apply one-command baseline setup for a target git repository. Auto-triggers `setup` on first run. Installs or refreshes Carson-managed global hooks. |
| `carson refresh [repo_path]` | Re-apply hooks, templates, and audit after upgrading Carson. Auto-propagates template updates to the remote via worktree (branch workflow: PR on `carson/template-sync`; trunk workflow: push to main). |
| `carson offboard [repo_path]` | Remove Carson-managed host artefacts, detach Carson hooks path, and deregister from `govern.repos`. |

### Daily commands

| Command | Purpose |
|---|---|
| `carson audit` | Evaluate governance status and generate report output. |
| `carson deliver [--commit MESSAGE]` | Run Carson-owned branch delivery for the current checkout. Plain `deliver` transports existing commits only; `--commit` creates one all-dirty delivery commit first. Before push, Carson verifies the branch is fresh against the configured remote `main`; behind or unknown freshness blocks delivery without creating or refreshing a PR. If freshness is good, Carson pushes, creates or refreshes the PR, watches the delivery for a bounded settle window, merges when clear, and syncs local `main`. Non-integrated exits report `Merge deferred` or `Merge blocked` with explicit handoff commands. |
| `carson recover --check NAME [--json]` | Run the exceptional governed recovery path when one governance-owned required check is already red on the default branch. Carson proves the named baseline failure, keeps every other gate intact, merges through the recovery path, and records a machine-readable audit event. |
| `carson sync` | Fast-forward local `main` from configured remote when tree is clean. |
| `carson prune` | Remove stale local branches whose upstream refs no longer exist. |
| `carson housekeep [--json] [--dry-run]` | Attempt to sync the current repo, then reap worktrees with strong abandonment evidence, reconcile integrated delivery worktree records from the ledger, and prune stale branches. Safe cleanup still runs when sync is blocked. |
| `carson template check` | Detect drift between managed templates and host `.github/*` files. |
| `carson template apply` | Write canonical managed template content into host `.github/*` files. |
| `carson status [--json]` | Show repository delivery state, including the next queued delivery and blocked-delivery summaries. Default output is Markdown/text; `--json` is the explicit machine contract. |
| `carson abandon <pr_number\|pr_url\|branch> [--json]` | Close abandoned delivery work and clean up its PR, worktree, and branch when safe. |
| `carson worktree create <name>` | Create an isolated worktree and branch for a new stream of work. |
| `carson worktree list [--json]` | Show every registered worktree with PR state and Carson's cleanup recommendation. |
| `carson worktree remove <path_or_name>` | Remove a worktree safely and clean up its branch when allowed. |

### Batch commands (Layer 2)

All batch commands operate across every governed repository registered in `govern.repos`.

| Command | Purpose |
|---|---|
| `carson refresh --all` | Re-apply hooks, templates, and audit across all governed repos. Skips repos with active worktrees or uncommitted changes. |
| `carson audit --all` | Run governance audit across all governed repos. Reports pass/block/fail per repo. |
| `carson sync --all` | Sync main branch across all governed repos. |
| `carson prune --all` | Remove stale branches across all governed repos. |
| `carson status --all [--json]` | Portfolio-wide delivery overview per governed repository. |
| `carson template check --all` | Read-only template drift detection across all governed repos. |
| `carson housekeep --all [--loop SECONDS]` | Attempt sync, then reap worktrees with strong abandonment evidence, reconcile integrated delivery worktree records from the ledger, and prune across all governed repos. Safe cleanup still runs when sync is blocked. |

`--loop SECONDS` runs the housekeep cycle continuously, sleeping SECONDS between cycles. It requires `--all`, accepts only positive integers, and exits cleanly on `Ctrl-C` with a cycle count summary.

### Govern commands

| Command | Purpose |
|---|---|
| `carson govern [--dry-run] [--json] [--loop SECONDS]` | Portfolio-level delivery oversight: assess active deliveries, integrate ready branches, dispatch revisions, and escalate blocked work. |

`--loop SECONDS` runs the govern cycle continuously, sleeping SECONDS between cycles. The loop isolates errors per cycle — a single failing cycle does not stop the daemon. `Ctrl-C` cleanly exits with a cycle count summary. SECONDS must be a positive integer.

Governed integration is fixed to `squash`. Non-squash `govern.merge.method` values are rejected by config validation.

After a live integration attempt, govern reports the actual outcome. Failed merges stay held at gate instead of being reported as integrated.

After CI and review pass, Carson still checks GitHub mergeability. Conflicting PRs exit as `Merge blocked` with an explicit merge-conflict summary. `BEHIND` is treated as freshness failure: Carson blocks and requires a branch refresh before it will continue.

In `--json` mode, `deliver` still suppresses human output. Every JSON result now includes `watch_window_seconds`, `waited_seconds`, and `merge_attempted`; deferred and blocked exits also include a `handoff` object with `reason`, `expectation`, and ordered `next_steps`.

After a successful govern merge, Carson runs the same cleanup path as `housekeep`: sync, reap safe worktrees, then prune.

### Review commands

| Command | Purpose |
|---|---|
| `carson review gate` | Block until actionable review findings are resolved or convergence timeout is reached. |
| `carson review sweep` | Scan recent PR activity and update a rolling tracking issue for late actionable feedback. |

### Info commands

| Command | Purpose |
|---|---|
| `carson version` | Print installed Carson version. |

## Exit status contract

- `0`: success
- `1`: runtime/configuration/command error
- `2`: policy blocked (hard stop)

Automation and CI integrations should treat exit `2` as an expected policy failure signal.

## Governance guard contract

In a Carson-governed repository:
- Raw `git worktree add` and `git worktree remove` are blocked. Use `carson worktree create` and `carson worktree remove`.
- Raw `git pull --rebase` is blocked. Use `carson sync`.
- Raw `gh pr create` and `gh pr merge` are blocked. Use `carson deliver`.
- Bootstrap repair for a baseline-red governance check uses `carson recover --check NAME`, not raw `gh api`.
- On the governed main working tree, raw `git add` and `git commit` are blocked until a Carson worktree exists for the task.

## Repository boundary contract

Blocked Carson artefacts in host repositories:
- `.carson.yml`
- `bin/carson`
- `.tools/carson/*`

Allowed Carson-managed persistence in host repositories:
- Any file discovered from `lint.canonical` — user's canonical GitHub and lint-policy files

## Configuration interface

Default global configuration path:
- `~/.carson/config.json`

Override path:
- `CARSON_CONFIG_FILE=/absolute/path/to/config.json`

Environment overrides:
- `CARSON_HOOKS_PATH`
- `CARSON_REVIEW_WAIT_SECONDS`
- `CARSON_REVIEW_POLL_SECONDS`
- `CARSON_REVIEW_MAX_POLLS`
- `CARSON_REVIEW_DISPOSITION`
- `CARSON_REVIEW_SWEEP_WINDOW_DAYS`
- `CARSON_REVIEW_SWEEP_STATES`
- `CARSON_WORKFLOW_STYLE`
- `CARSON_GOVERN_REPOS`
- `CARSON_GOVERN_AGENT_PROVIDER`
- `CARSON_GOVERN_CHECK_WAIT`

`govern` schema:

```json
{
  "govern": {
    "repos": ["~/Dev/project-a", "~/Dev/project-b"],
    "agent": {
      "provider": "auto",
      "codex": {},
      "claude": {}
    },
    "check_wait": 30,
    "merge": {
      "method": "squash"
    },
    "state_path": "~/.carson/state.json"
  }
}
```

`govern` semantics:
- `repos`: list of local repo paths to govern (empty = current repo only).
- `agent.provider`: `"auto"`, `"codex"`, or `"claude"`.
- `agent.codex` / `agent.claude`: provider-specific options (reserved).
- `check_wait`: seconds to wait for CI checks before classifying (default: `30`).
- `merge.method`: `"squash"` only in governed mode.
- `state_path`: JSON ledger path for active deliveries and revisions. Legacy SQLite ledgers are imported automatically on first read; explicit legacy `.sqlite3` paths keep working after import.

`template` schema:

```json
{
  "lint": {
    "canonical": "~/AI/CODING/LINT"
  }
}
```

`lint` semantics:
- `canonical`: path to a directory of canonical GitHub and lint-policy files. Carson discovers files in this directory and syncs them to governed repos. Explicit GitHub paths stay under `.github/` (`workflows/lint.yml` → `.github/workflows/lint.yml`, `.github/labeler.yml` → `.github/labeler.yml`); flat policy files default to `.github/linters/` (`rubocop.yml` → `.github/linters/rubocop.yml`). Legacy root lint configs become stale and are removed on apply. Default: `nil` (no canonical files). The deprecated alias `template.canonical` is still accepted when loading config.

## Output interface

Report output directory precedence:
- `~/.carson/cache`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility

- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
