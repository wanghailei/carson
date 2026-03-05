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
| `carson setup` | Interactive quiz to configure remote, main branch, workflow, and merge method. Writes `~/.carson/config.json`. |
| `carson onboard [repo_path]` | Apply one-command baseline setup for a target git repository. Auto-triggers `setup` on first run. Installs or refreshes Carson-managed global hooks. |
| `carson refresh [repo_path]` | Re-apply hooks, templates, and audit after upgrading Carson. Auto-propagates template updates to the remote via worktree (branch workflow: PR on `carson/template-sync`; trunk workflow: push to main). |
| `carson offboard [repo_path]` | Remove Carson-managed host artefacts, detach Carson hooks path, and deregister from `govern.repos`. |

### Daily commands

| Command | Purpose |
|---|---|
| `carson audit` | Evaluate governance status and generate report output. |
| `carson sync` | Fast-forward local `main` from configured remote when tree is clean. |
| `carson prune` | Remove stale local branches whose upstream refs no longer exist. |
| `carson template check` | Detect drift between managed templates and host `.github/*` files. |
| `carson template apply` | Write canonical managed template content into host `.github/*` files. |

### Govern commands

| Command | Purpose |
|---|---|
| `carson govern [--dry-run] [--json] [--loop SECONDS]` | Portfolio-level PR triage: classify, merge, dispatch agents, escalate. |

`--loop SECONDS` runs the govern cycle continuously, sleeping SECONDS between cycles. The loop isolates errors per cycle — a single failing cycle does not stop the daemon. `Ctrl-C` cleanly exits with a cycle count summary. SECONDS must be a positive integer.

`govern.merge.method` accepts `squash`, `merge`, or `rebase` (default: `squash`). Squash keeps main linear — one PR, one commit. When the target repository enforces linear history via branch protection, both `squash` and `rebase` are accepted by GitHub — only `merge` is rejected.

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
- Any file discovered from `template.canonical` — user's canonical `.github/` files

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
  "template": {
    "canonical": "~/AI/LINT"
  }
}
```

`template` semantics:
- `canonical`: path to a directory of canonical `.github/` files. Carson discovers files in this directory and syncs them to governed repos alongside its own governance files. The directory mirrors `.github/` structure — `workflows/lint.yml` deploys to `.github/workflows/lint.yml`. Default: `nil` (no canonical files).

## Output interface

Report output directory precedence:
- `~/.carson/cache`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility

- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
