# Carson API

This document defines Carson's user-facing interface contract for CLI commands, configuration inputs, and exit behaviour.

## Command interface

Command form:

```bash
carson <command> [subcommand] [arguments]
```

Supported commands:

| Command | Purpose |
|---|---|
| `carson version` | Print installed Carson version. |
| `carson init [repo_path]` | Apply one-command baseline setup for a target git repository. |
| `carson sync` | Fast-forward local `main` from configured remote when tree is clean. |
| `carson audit` | Evaluate governance status and generate report output. |
| `carson hook` | Install or refresh Carson-managed global hooks. |
| `carson check` | Run governance checks against current repository state. |
| `carson prune` | Remove stale local branches whose upstream refs no longer exist. |
| `carson template check` | Detect drift between managed templates and host `.github/*` files. |
| `carson template apply` | Write canonical managed template content into host `.github/*` files. |
| `carson review gate` | Block until actionable review findings are resolved or convergence timeout is reached. |
| `carson review sweep` | Scan recent PR activity and update a rolling tracking issue for late actionable feedback. |
| `carson offboard [repo_path]` | Remove Carson-managed host artefacts and detach Carson hooks path where applicable. |

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
- selected GitHub-native files under `.github/*`

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
- `CARSON_RUBY_INDENTATION`

## Output interface
Report output directory precedence:
- `~/.cache/carson`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility
- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
