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
| `carson lint policy --source <path-or-git-url> [--ref <git-ref>] [--force]` | Distribute lint configs from a central source into the governed repo's `.github/linters/`. |
| `carson onboard [repo_path]` | Apply one-command baseline setup for a target git repository. Auto-triggers `setup` on first run. |
| `carson prepare` | Install or refresh Carson-managed global hooks. |
| `carson refresh [repo_path]` | Re-apply hooks, templates, and audit after upgrading Carson. |
| `carson offboard [repo_path]` | Remove Carson-managed host artefacts and detach Carson hooks path where applicable. |

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
| `carson housekeep` | Sync main + prune stale branches (also runs automatically after govern merges). |

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
| `carson inspect` | Verify Carson-managed hook installation and repository setup. |

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
- `.github/carson-instructions.md` — governance baseline (source of truth)
- `.github/copilot-instructions.md` — agent discovery pointer for Copilot
- `.github/CLAUDE.md` — agent discovery pointer for Claude Code
- `.github/AGENTS.md` — agent discovery pointer for Codex
- `.github/pull_request_template.md` — PR template
- `.github/workflows/carson-lint.yml` — MegaLinter CI workflow

## Configuration interface

Default global configuration path:
- `~/.carson/config.json`

Override path:
- `CARSON_CONFIG_FILE=/absolute/path/to/config.json`

Environment overrides:
- `CARSON_HOOKS_BASE_PATH`
- `CARSON_REVIEW_WAIT_SECONDS`
- `CARSON_REVIEW_POLL_SECONDS`
- `CARSON_REVIEW_MAX_POLLS`
- `CARSON_REVIEW_DISPOSITION_PREFIX`
- `CARSON_REVIEW_SWEEP_WINDOW_DAYS`
- `CARSON_REVIEW_SWEEP_STATES`
- `CARSON_WORKFLOW_STYLE`
- `CARSON_RUBY_INDENTATION`
- `CARSON_LINT_POLICY_SOURCE`
- `CARSON_GOVERN_REPOS`
- `CARSON_GOVERN_MERGE_AUTHORITY`
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
    "merge": {
      "authority": false,
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
- `merge.authority`: `false` (default) — Carson does not merge until explicitly enabled.
- `merge.method`: `"squash"` (default), `"merge"`, or `"rebase"`.

`lint` schema:

```json
{
  "lint": {
    "policy_source": "wanghailei/lint.git"
  }
}
```

`lint` semantics:
- `policy_source`: default source for `carson lint policy` when `--source` is not specified.

Environment overrides:
- `CARSON_LINT_POLICY_SOURCE` — overrides `lint.policy_source`.

Private-source clone token for `carson lint policy`:
- `CARSON_READ_TOKEN` (used when `--source` points to a private GitHub repository).

Policy layout requirement:
- Lint config files sit at the root of the source repo and are copied to `<governed-repo>/.github/linters/`.
- MegaLinter auto-discovers configs in `.github/linters/` during CI.

## Output interface

Report output directory precedence:
- `~/.carson/cache`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility

- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
