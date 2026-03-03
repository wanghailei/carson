# Carson Manual

This manual covers installation, first-time setup, CI configuration, and daily operations.
For the mental model and command overview, see `README.md`. For formal interface definitions, see `API.md`.

## Install Carson

Prerequisites: Ruby `>= 3.4`, `gem` and `git` in `PATH`. `gh` (GitHub CLI) recommended for full review governance.

```bash
gem install --user-install carson
```

If `carson` is not found after installation:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

Verify:

```bash
carson version
```

## First-Time Setup

### Step 1: Prepare your lint policy

Carson distributes lint configuration files from a central policy source — a directory or git repository you control — into each governed repo's `.github/linters/` directory, where MegaLinter auto-discovers them.

```bash
carson lint policy --source /path/to/your-policy-repo
```

After this command, `.github/linters/` contains your lint configs (`.rubocop.yml`, `biome.json`, `ruff.toml`, etc.). MegaLinter uses these in CI. Every governed repository gets the same rules — this is how Carson keeps lint consistent across languages.

Options:
- `--source <path-or-git-url>` — where to read policy files from (required).
- `--ref <git-ref>` — branch or tag when `--source` is a git URL.
- `--force` — overwrite existing `.github/linters/` files.

Policy layout: lint config files sit at the root of the source repo (flat layout, no subdirectories required).

### Step 2: Onboard a repository

```bash
carson onboard /path/to/your-repo
```

On first run (no `~/.carson/config.json` exists), `onboard` launches `carson setup` — an interactive quiz that detects your remotes, main branch, and preferred workflow. In non-interactive environments (CI, pipes), Carson auto-detects settings silently.

`onboard` performs:
- Interactive setup quiz (first run only).
- Remote detection and verification using configured `git.remote` (default `origin`).
- Hook installation under `~/.carson/hooks/<version>/`.
- Repository `core.hooksPath` alignment to Carson global hooks.
- Commit-time governance gate via managed `pre-commit` hook.
- Managed `.github/*` template synchronisation.
- Initial governance audit.

### Reconfigure later

```bash
carson setup
```

Re-run the interactive setup quiz to change your remote, main branch, workflow style, or merge method. Choices are saved to `~/.carson/config.json`.

### Step 3: Commit generated files

After `onboard`, commit the generated `.github/*` changes in your repository. From this point the repository is governed.

## CI Setup

Use the reusable workflow with explicit release pins:

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v1.0.0
    secrets:
      CARSON_READ_TOKEN: ${{ secrets.CARSON_READ_TOKEN }}
    with:
      carson_ref: "v1.0.0"
      carson_version: "1.0.0"
      rubocop_version: "1.81.0"
```

Notes:
- When upgrading Carson, update both `carson_ref` and `carson_version` together.
- `CARSON_READ_TOKEN` must have read access to your policy source repository so CI can run `carson lint setup`.
- The reusable workflow installs a pinned RuboCop gem before `carson audit`; mirror the same pin in host governance workflows for deterministic checks.

## Daily Operations

**Start of work:**

```bash
carson sync                                          # fast-forward local main
carson lint policy --source /path/to/your-policy-repo # refresh policy if needed
carson audit                                         # full governance check
```

**Before push or PR update:**

```bash
carson audit
carson template check
```

If template drift is detected:

```bash
carson template apply
```

**Before merge:**

```bash
carson review gate
```

**Periodic maintenance:**

```bash
carson review sweep    # update tracking issue for late review feedback
carson prune           # remove stale local branches
```

## Running Carson Govern Continuously

Use `--loop SECONDS` to run `carson govern` as a persistent daemon that cycles on a schedule:

```bash
carson govern --loop 300              # cycle every 5 minutes
carson govern --loop 300 --dry-run    # observe mode, no merges or dispatches
```

The loop is built-in and cross-platform — no cron, launchd, or Task Scheduler required. Run it in a terminal, tmux, screen, or as a system service.

Each cycle runs independently: if one cycle fails (network error, GitHub API timeout), the error is logged and the next cycle proceeds normally. Press `Ctrl-C` to stop — Carson exits cleanly with a cycle count summary.

## Merge Method and Linear History

Carson's `govern.merge.method` controls how `carson govern` merges ready PRs. The options are `squash`, `merge`, and `rebase` (default: `squash`). Set this in `~/.carson/config.json`:

```json
{
  "govern": {
    "merge": {
      "method": "squash"
    }
  }
}
```

**Why squash is the default.** Squash-to-main keeps history linear: one PR = one commit on main. Every commit on main corresponds to a reviewed, CI-passing unit of work. The benefits:

- `git log --oneline` on main tells the full story without merge noise or work-in-progress commits.
- Every commit is individually revertable — `git revert <sha>` undoes exactly one PR.
- `git bisect` operates on meaningful boundaries, not intermediate fixup commits.
- Individual branch commits are still preserved in the PR on GitHub for full traceability.

**When to use other methods:**

- `rebase` — if you want to preserve individual commits from the branch on main. Both `squash` and `rebase` are compatible with GitHub's "Require linear history" branch protection — only `merge` is rejected.
- `merge` — if you want explicit merge commits. This creates a non-linear graph but preserves branch topology.

**Important:** Carson's merge method must match your GitHub repository's allowed merge types. If your repo only allows squash merges and Carson is set to `merge`, govern will fail when it tries to auto-merge. Check your repository settings under Settings > General > Pull Requests.

## Defaults and Why

### Principles (iron rules)

These define what Carson *is*. They are not configurable.

- **Outsider boundary** — Carson never places its own artefacts inside a governed repository.
- **Centralised lint** — one policy source distributed into each repo's `.github/linters/`, zero per-repo drift.
- **Active review** — undisposed reviewer findings block merge; feedback must be acknowledged.
- **Self-diagnosing output** — every message names the cause and the fix.
- **Transparent governance** — Carson prepares everything for merge but never makes decisions without telling you.

### Configurable defaults

These are starting points chosen during `carson setup`. Every default has a reason, but all can be changed.

#### Workflow style

How code reaches main.

- **`branch`** (default) — every change goes through a PR. Hooks block direct commits and pushes to main/master. PRs enforce review, scope integrity, and CI gates before code reaches main.
- **`trunk`** — commit directly to main. Hooks allow all commits. Suits solo projects or flat teams that don't need PR-based review.

Change: `carson setup` or `CARSON_WORKFLOW_STYLE`.

#### Merge method

How `carson govern` merges ready PRs.

- **`squash`** (default) — one PR = one commit on main. Linear, bisectable history. Every commit is individually revertable. Branch commits are preserved in the PR on GitHub.
- **`rebase`** — preserves individual branch commits on main. Linear history. Use when commit-level attribution matters.
- **`merge`** — creates merge commits. Non-linear graph but preserves branch topology. Use when branch structure is meaningful.

Must match your GitHub repo's allowed merge types. Change: `carson setup` or `govern.merge.method` in config.

#### Git remote

Which remote Carson checks for main sync and PR operations.

- Default: **`origin`**. Setup detects your actual remotes and presents them — pick the one that points to GitHub.
- If multiple remotes share the same URL, setup warns about the duplicate.

Change: `carson setup` or `git.remote` in config.

#### Main branch

Which branch Carson treats as the canonical baseline.

- Default: **`main`**. Setup detects whether `main` or `master` exists and offers both.

Change: `carson setup` or `git.main_branch` in config.

#### Hooks location

Where Carson installs git hooks.

- Default: **`~/.carson/hooks/<version>/`**. Outsider principle: hooks live outside your repo, versioned per Carson release, never committed to your repository.

Change: `CARSON_HOOKS_BASE_PATH`.

#### Lint policy source

Where lint configuration files come from and where they land.

- Default source: **`wanghailei/lint.git`**. A central repository containing lint configs for all languages.
- Target: **`<repo>/.github/linters/`**. MegaLinter auto-discovers configs here in CI.

Change: `carson lint policy --source <path-or-git-url>` or `lint.policy_source` in config. After changing policy, run `carson refresh --all` to propagate to all governed repositories.

#### Scope integrity

Whether cross-module changes are flagged.

- Default: **advisory** (attention, not block). Carson informs you when staged files span multiple module groups (e.g. both `domain` and `ui`), but doesn't prevent the commit. Useful for awareness; not a hard gate.

Customise groups: `scope.path_groups` in config.

#### Review disposition

Whether reviewer findings require acknowledgement.

- Default: **required**. Comments containing risk keywords (`bug`, `security`, `regression`, etc.) must have a `Disposition:` response from the PR author before merge. Prevents feedback from being buried.

Change prefix: `CARSON_REVIEW_DISPOSITION_PREFIX`.

#### Merge authority

Whether `carson govern` can merge PRs autonomously.

- Default: **enabled**. Carson merges PRs that pass all gates (CI green, review clean, audit clean). PRs that need human judgement are escalated, never silently merged.

Disable: `govern.merge_authority: false` in config.

#### Output verbosity

How much Carson prints.

- Default: **concise**. A healthy audit prints one line. Problems print actionable summaries with cause and fix.
- `--verbose` restores full diagnostic key-value output for debugging.

## Agent Discovery

Carson writes managed files that help interactive agents (Claude Code, Codex, Copilot) discover the governance system when they work in a governed repository.

**How it works:**

- `.github/carson-instructions.md` — the single source of truth containing the full governance baseline. This file tells agents what Carson is, what commands to run, and what rules to follow.
- `.github/CLAUDE.md` — read by Claude Code at session start. Points to `carson-instructions.md`.
- `.github/AGENTS.md` — read by Codex at session start. Points to `carson-instructions.md`.
- `.github/copilot-instructions.md` — read by GitHub Copilot. Points to `carson-instructions.md`.

Each agent reads its own expected filename and follows the reference to the shared baseline. One file to maintain, zero drift across agents.

All four files are managed templates — `carson template check` detects drift, `carson template apply` writes them, and `carson offboard` removes them.

**Why this matters:** without discovery, agents working in governed repos hit Carson's hooks blindly and don't understand the governance contract. With discovery, agents know to run `carson audit` before committing, `carson review gate` before recommending a merge, and to respect protected refs.

## Configuration

Default global config path: `~/.carson/config.json`.

Precedence (highest wins): environment variables > config file > built-in defaults.

Override the config file path with `CARSON_CONFIG_FILE=/absolute/path/to/config.json`.

Common environment overrides:

| Variable | Purpose |
|---|---|
| `CARSON_HOOKS_BASE_PATH` | Custom hooks installation directory. |
| `CARSON_REVIEW_WAIT_SECONDS` | Initial wait before first review poll. |
| `CARSON_REVIEW_POLL_SECONDS` | Interval between review polls. |
| `CARSON_REVIEW_MAX_POLLS` | Maximum review poll attempts. |
| `CARSON_REVIEW_DISPOSITION_PREFIX` | Required prefix for disposition comments. |
| `CARSON_REVIEW_SWEEP_WINDOW_DAYS` | Lookback window for review sweep. |
| `CARSON_REVIEW_SWEEP_STATES` | PR states to include in sweep. |
| `CARSON_WORKFLOW_STYLE` | Workflow style override (`branch` or `trunk`). |
| `CARSON_RUBY_INDENTATION` | Ruby indentation policy (`tabs`, `spaces`, or `either`). |

For the full configuration schema, see `API.md`.

## Troubleshooting

**`carson: command not found`**
- Confirm Ruby and gem installation.
- Confirm `$(ruby -e 'print Gem.user_dir')/bin` is in `PATH`.

**`review gate` fails on actionable comments**
- Respond with a valid disposition comment using the required prefix.
- Re-run `carson review gate`.

**Template drift blocks**

```bash
carson template apply
carson template check
```

**Audit blocks on lint failure**
- If `lint.command` is configured and fails, audit blocks (in `strict` mode) or warns (in `advisory` mode). Fix the lint issues and re-run `carson audit`.

**Hook version mismatch after upgrade**
- Run `carson refresh` to re-apply hooks and templates for the new Carson version.
- Run `carson refresh --all` to refresh all governed repositories at once.

## Offboard a Repository

To retire Carson from a repository:

```bash
carson offboard /path/to/your-repo
```

This removes Carson-managed host artefacts and unsets `core.hooksPath` when it points to Carson-managed global hooks.

## Related Documents

- Mental model and command overview: `README.md`
- Formal interface contract: `API.md`
- Release notes: `RELEASE.md`
