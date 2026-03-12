# Carson API

This document defines Carson's user-facing interface contract for CLI commands, configuration inputs, and exit behaviour.
For operational usage and daily workflows, see `MANUAL.md`.

## Command interface

Command form:

```bash
carson <command> [subcommand] [arguments]
```

### Tier 1 streams

Carson's primary agent-facing interface is a fixed set of named streams. There is no generic passthrough command such as `carson do`.

| Command | Purpose |
|---|---|
| `carson deliver [--pr-only] [--json]` | Default post-commit delivery stream: push/update branch, open or reuse PR, wait briefly for readiness, merge when ready, then sync local `main`. |
| `carson realign [--json]` | Realign a clean non-`main` branch onto the latest `main`, then safely update the remote branch. |
| `carson revert <pr-number-or-sha> [--json]` | Prepare a revert branch/worktree for merged work and hand it off to `deliver`. |
| `carson release <version> [--notes-file PATH] [--draft] [--json]` | Tag and publish an already-prepared release from clean, synced `main`. |
| `carson track <open|comment|close|reopen> ...` | Issue-only lifecycle stream for GitHub issues. |
| `carson review <gate|sweep|comment|reply|approve|request-changes|disposition> ...` | Pull-request-only review workflow stream. |

`deliver` semantics:
- Default behaviour is the full stream. `--pr-only` is the only built-in escape hatch when an agent wants to stop after PR creation or update.
- If checks or approval are still pending after the bounded watch window, `deliver` exits `0` with `status: pending` and a resumable recovery path.
- If CI fails or review is blocked, `deliver` exits `2`.
- Post-merge cleanup remains explicit via `carson housekeep`.

`track` scope:
- `carson track open --title TITLE [--body TEXT | --body-file PATH]`
- `carson track comment ISSUE_NUMBER --body TEXT | --body-file PATH`
- `carson track close ISSUE_NUMBER`
- `carson track reopen ISSUE_NUMBER`

`review` scope:
- `carson review gate`
- `carson review sweep`
- `carson review comment PR_NUMBER --body TEXT | --body-file PATH`
- `carson review reply FINDING_URL --body TEXT | --body-file PATH`
- `carson review approve PR_NUMBER [--body TEXT | --body-file PATH]`
- `carson review request-changes PR_NUMBER --body TEXT | --body-file PATH`
- `carson review disposition FINDING_URL <accepted|rejected|deferred> [--body TEXT | --body-file PATH]`

### Setup commands

| Command | Purpose |
|---|---|
| `carson setup` | Interactive quiz to configure remote, main branch, workflow, and merge method. Writes `~/.carson/config.json`. |
| `carson onboard [repo_path]` | Apply one-command baseline setup for a target git repository. Auto-triggers `setup` on first run. Installs or refreshes Carson-managed global hooks. |
| `carson refresh [repo_path]` | Re-apply hooks, templates, and audit after upgrading Carson. Auto-propagates template updates to the remote via worktree (branch workflow: PR on `carson/template-sync`; trunk workflow: push to main). |
| `carson offboard [repo_path]` | Remove Carson-managed host artefacts, detach Carson hooks path, and deregister from `govern.repos`. |

### Support commands

| Command | Purpose |
|---|---|
| `carson audit` | Evaluate governance status and generate report output. |
| `carson sync` | Fast-forward local `main` from configured remote when tree is clean. |
| `carson prune` | Remove stale local branches whose upstream refs no longer exist. |
| `carson template check` | Detect drift between managed templates and host `.github/*` files. |
| `carson template apply` | Write canonical managed template content into host `.github/*` files. |
| `carson status` | Show repository state (branch, worktrees, PRs, governance). |
| `carson worktree <create|remove> ...` | Manage isolated coding worktrees. |
| `carson housekeep [--all]` | Sync, reap dead worktrees, and prune stale branches. |

### Batch commands (Layer 2)

All batch commands operate across every governed repository registered in `govern.repos`.

| Command | Purpose |
|---|---|
| `carson refresh --all` | Re-apply hooks, templates, and audit across all governed repos. Skips repos with active worktrees or uncommitted changes. |
| `carson audit --all` | Run governance audit across all governed repos. Reports pass/block/fail per repo. |
| `carson sync --all` | Sync main branch across all governed repos. |
| `carson prune --all` | Remove stale branches across all governed repos. |
| `carson status --all [--json]` | Portfolio-wide status overview with branch, worktrees, and governance state per repo. |
| `carson template check --all` | Read-only template drift detection across all governed repos. |
| `carson housekeep --all` | Sync, reap dead worktrees, and prune across all governed repos. |

### Govern commands

| Command | Purpose |
|---|---|
| `carson govern [--dry-run] [--json] [--loop SECONDS]` | Portfolio-level PR triage: classify, merge, dispatch agents, escalate. |

`--loop SECONDS` runs the govern cycle continuously, sleeping SECONDS between cycles. The loop isolates errors per cycle — a single failing cycle does not stop the daemon. `Ctrl-C` cleanly exits with a cycle count summary. SECONDS must be a positive integer.

`govern.merge.method` accepts `squash`, `merge`, or `rebase` (default: `squash`). Squash keeps main linear — one PR, one commit. When the target repository enforces linear history via branch protection, both `squash` and `rebase` are accepted by GitHub — only `merge` is rejected.

### Info commands

| Command | Purpose |
|---|---|
| `carson version` | Print installed Carson version. |

## Exit status contract

- `0`: success
- `1`: runtime/configuration/command error
- `2`: policy blocked (hard stop)

Automation and CI integrations should treat exit `2` as an expected policy failure signal. Pending `deliver` runs are not failures: they return exit `0` with `status: pending`.

## Repository boundary contract

Blocked Carson artefacts in host repositories:
- `.carson.yml`
- `bin/carson`
- `.tools/carson/*`

Allowed Carson-managed persistence in host repositories:
- `.github/carson.md` — governance baseline (source of truth)
- `.github/copilot-instructions.md` — agent discovery pointer for Copilot
- `.github/CLAUDE.md` — agent discovery pointer for Claude Code
- `.github/AGENTS.md` — agent discovery pointer for Codex
- `.github/pull_request_template.md` — PR template
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
- `CARSON_GOVERN_AUTO_MERGE`
- `CARSON_GOVERN_MERGE_METHOD`
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
    "auto_merge": true,
    "merge": {
      "method": "squash"
    }
  }
}
```

`govern` semantics:
- `repos`: list of local repo paths to govern (empty = current repo only).
- `agent.provider`: `"auto"`, `"codex"`, or `"claude"`.
- `agent.codex` / `agent.claude`: provider-specific options (reserved).
- `check_wait`: seconds to wait for CI checks before classifying (default: `30`).
- `auto_merge`: `true` (default) — Carson may merge autonomously. Set to `false` to require explicit enablement.
- `merge.method`: `"squash"` (default), `"merge"`, or `"rebase"`.

`template` schema:

```json
{
  "lint": {
    "canonical": "~/AI/CODING/LINT"
  }
}
```

`lint` semantics:
- `canonical`: path to a directory of canonical GitHub and lint-policy files. Carson discovers files in this directory and syncs them to governed repos alongside its own governance files. Explicit GitHub paths stay under `.github/` (`workflows/lint.yml` → `.github/workflows/lint.yml`, `.github/labeler.yml` → `.github/labeler.yml`); flat policy files default to `.github/linters/` (`rubocop.yml` → `.github/linters/rubocop.yml`). Legacy root lint configs become stale and are removed on apply. Default: `nil` (no canonical files). The deprecated alias `template.canonical` is still accepted when loading config.

## Output interface

Report output directory precedence:
- `~/.carson/cache`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility

- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
