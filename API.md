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
| `carson lint setup --source <path-or-git-url> [--ref <git-ref>] [--force]` | Seed or refresh `~/.carson/lint` policy files from an explicit source. |
| `carson init [repo_path]` | Apply one-command baseline setup for a target git repository. |
| `carson hook` | Install or refresh Carson-managed global hooks. |
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

### Review commands

| Command | Purpose |
|---|---|
| `carson review gate` | Block until actionable review findings are resolved or convergence timeout is reached. |
| `carson review sweep` | Scan recent PR activity and update a rolling tracking issue for late actionable feedback. |

### Info commands

| Command | Purpose |
|---|---|
| `carson version` | Print installed Carson version. |
| `carson check` | Verify Carson-managed hook installation and repository setup. |

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

`lint.languages` schema:

```json
{
  "lint": {
    "languages": {
      "ruby": {
        "enabled": true,
        "globs": ["**/*.rb"],
        "command": ["ruby", "/absolute/path/to/carson/lib/carson/policy/ruby/lint.rb", "{files}"],
        "config_files": ["~/.carson/lint/rubocop.yml"]
      }
    }
  }
}
```

`lint.languages` semantics:
- `enabled`: boolean toggle per language.
- `globs`: file-match patterns applied to the selected audit target set.
- `command`: argv array executed without shell interpolation.
- `config_files`: required files that must exist before lint runs.
- `{files}` token: replaced with matched files; if omitted, matched files are appended at the end of argv.
- Default Ruby policy source is `~/.carson/lint/rubocop.yml`; Ruby execution logic is Carson-owned.
- Client repositories containing repo-local `.rubocop.yml` are hard-blocked by `carson audit` in outsider mode.
- Non-Ruby language entries (`javascript`, `css`, `html`, `erb`) are present but disabled by default.

Lint target file source precedence in `carson audit`:
- staged files for local commit-time execution.
- PR changed files in GitHub `pull_request` events.
- full repository tracked files in GitHub non-PR events.
- local working-tree changes as fallback.

Private-source clone token for `carson lint setup`:
- `CARSON_READ_TOKEN` (used when `--source` points to a private GitHub repository).

Ruby source requirement for `carson lint setup` (when Ruby lint is enabled):
- `CODING/rubocop.yml` must exist in the source tree.

Policy layout requirement:
- Language policy files are stored directly under `CODING/` and copied to `~/.carson/lint/` without language subdirectories.

## Output interface

Report output directory precedence:
- `~/.carson/cache`
- `TMPDIR/carson` (used when `HOME` is invalid and `TMPDIR` is absolute)
- `/tmp/carson` (fallback)

## Versioning and compatibility

- Pin Carson in automation by explicit release and version pair (`carson_ref`, `carson_version`).
- Review upgrade actions in `RELEASE.md` before moving to a newer minor or major version.
