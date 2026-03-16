# Carson Manual

This manual covers installation, first-time setup, CI configuration, and daily operations.
For the mental model and command overview, see `README.md`. For formal interface definitions, see `API.md`.

## Install Carson

Prerequisites: Ruby `>= 3.4`, `gem` and `git` in `PATH`. `gh` (GitHub CLI) recommended for full review governance.

```bash
gem install carson
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

### Onboard a repository

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
- Canonical `.github/*` template synchronisation (when `lint.canonical` is configured).
- Initial governance audit.

### Reconfigure later

```bash
carson setup
```

Re-run the interactive setup quiz to change your remote, main branch, workflow style, or canonical lint-policy path. Choices are saved to `~/.carson/config.json`.

### Commit generated files

After `onboard`, commit any `.github/*` changes in your repository. From this point the repository is governed.

## CI Setup

Use the reusable workflow with explicit release pins:

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v3.28.0
    secrets:
      CARSON_READ_TOKEN: ${{ secrets.CARSON_READ_TOKEN }}
    with:
      carson_ref: "v3.28.0"
      carson_version: "3.28.0"
      rubocop_version: "1.81.0"
```

Notes:
- When upgrading Carson, update both `carson_ref` and `carson_version` together.
- `CARSON_READ_TOKEN` must have read access to your policy source repository.
- The reusable workflow installs a pinned RuboCop gem before `carson audit`; mirror the same pin in host governance workflows for deterministic checks.

### Canonical Templates

Carson has no built-in template files. Instead, you tell Carson about your own canonical GitHub and lint-policy files via `lint.canonical`.

Set `lint.canonical` in `~/.carson/config.json`:

```json
{
  "lint": {
    "canonical": "~/AI/CODING/LINT"
  }
}
```

Flat lint-policy directories default to `.github/linters/`, while explicit GitHub paths stay under `.github/`:

```
~/AI/CODING/LINT/
├── rubocop.yml           → deployed to .github/linters/rubocop.yml
├── ruff.toml             → deployed to .github/linters/ruff.toml
├── workflows/
│   └── lint.yml          → deployed to .github/workflows/lint.yml
└── .github/
    └── labeler.yml       → deployed to .github/labeler.yml
```

Carson discovers files in this directory and syncs them to governed repos. Root files that are not recognised GitHub artefacts are treated as lint policy and written under `.github/linters/`; legacy root lint configs become stale and are removed on apply. `carson template check` detects drift, `carson template apply` writes them, and `carson refresh` propagates them to the remote. Carson still reads the deprecated `template.canonical` key for backwards compatibility, but new setup writes `lint.canonical`.

**Why this design.** Lint, CI, and tooling config are personal decisions — not governance decisions. Carson's job is to deliver your canonical files reliably, not to decide what they should contain.

## Operating Strategies

These strategies are the audit lens for Carson. If behaviour departs from them, either the product model or the implementation needs attention.

### Git Strategist

- **Worktree-first discipline** — substantive work happens in worktrees, never on the main working tree. This keeps concurrent agent work isolated and makes cleanup explicit.
- **Deterministic base selection** — new work starts from a synced remote baseline, not from whatever branch state happens to be lying around.
- **Single landing path** — completed work rejoins through remote `main` via PR-based delivery.
- **Content-aware merge detection** — Carson proves whether a branch's content is already on `main` without relying on commit SHAs, so squash and rebase merges are handled correctly.
- **Worktree-aware delivery** — Carson lands work without assuming `main` can be checked out in the active worktree, and cleanup is deferred to the correct context.
- **Exact post-merge guidance** — after a successful landing, Carson tells the caller the next clean-up command instead of leaving the lifecycle half-finished.

### Repo Governor

- **Outsider boundary** — Carson governs repositories without writing Carson-specific config, scripts, or runtime payloads into them.
- **Command ownership** — in governed repositories, Carson owns worktree and delivery operations so agents do not mix raw git flows with governed ones.
- **Main-tree protection** — on the governed main working tree, Carson blocks `git add` and `git commit` until the agent creates a Carson worktree for the task.
- **Governed delivery** — completed work returns to shared truth through remote `main` via PR-based delivery. Carson owns the landing path.
- **Active review gating** — when the repo uses PR-based delivery, review findings must be acknowledged before merge. Feedback is never silently buried.
- **Portfolio triage** — `carson govern` applies the same discipline across multiple repositories: classify, merge, dispatch, or escalate.
- **Template propagation** — Carson treats canonical policy files as managed infrastructure and keeps them consistent across repos.

### Safety Strategies

- **Process-aware worktree removal** — Carson checks whether the current shell or another process has its CWD inside a worktree before attempting removal.
- **Stale worktree sweep** — Carson removes worktrees whose content has already been absorbed into `main` so dead state does not block later maintenance.
- **Protected branch preservation** — Carson never deletes protected branches and does not prune branches that are still held by active worktrees.
- **Hook bypass only for managed operations** — Carson uses controlled bypasses such as `--no-verify` only for its own managed flows, not as a general escape hatch.
- **Self-diagnosing errors** — blocks and failures must explain the condition and prescribe the exact recovery command.
- **Self-configuring guardrails** — running Carson should install and refresh its own safeguards rather than expecting manual post-install housekeeping.

## Agent Worktree Workflow

The core workflow for coding agents using Carson. One command per step, full lifecycle.

**1. Create a worktree** — Carson syncs remote `main` and starts new work from that baseline rather than from the caller's current HEAD:

```bash
carson worktree create my-feature
cd /path/to/.claude/worktrees/my-feature
```

On the governed main working tree, Carson blocks raw `git add` / `git commit` and blocks raw `git worktree add/remove`, raw `git pull --rebase`, and raw `gh pr create/merge`. Use `carson worktree create`, `carson sync`, and `carson deliver` instead.

**2. Work** — make changes, test them, and either commit normally or let Carson create the delivery commit.

**3. Hand the branch to Carson** — `deliver` is the synchronous happy path. Before any push, Carson verifies the branch is fresh against the configured remote `main`. If freshness is behind or unknown, delivery stops immediately and no PR is created or refreshed. If freshness is good, Carson pushes the branch, creates or refreshes the PR, watches the delivery for a bounded settle window, merges when the path is clear, syncs local `main`, and then reports merge proof for the delivered branch. If the window expires without integration, Carson exits with an explicit `Merge deferred` or `Merge blocked` handoff that states whether merge was attempted and what to run next. Plain `carson deliver` transports existing commits and blocks if the worktree is dirty. `carson deliver --commit "..."` creates one all-dirty agent-authored commit first, then continues the same delivery flow. Managed template drift is still corrected in a separate Carson-managed commit before push.

```bash
carson deliver
# or, if the worktree is still dirty:
carson deliver --commit "fix: describe this delivery"
# Output: merged into main, or an explicit deferred/blocked handoff
```

**4. Inspect or wait when needed** — when `deliver` cannot merge immediately, Carson tells you whether the PR was deferred or blocked, whether merge was attempted, and which command to run next. `status` still shows the current branch, the next queued delivery, and blocked-delivery summaries for the repository. When the current branch has a Carson delivery record, `status` also shows Carson's last observed PR state and merge proof. Keep `govern` running when you want unattended portfolio reassessment and revision dispatch across governed repositories:

```bash
carson status
carson govern --loop 300
```

### Recover a baseline-red governance check

When a governance-owned required check is already red on the default branch, the PR that repairs it can deadlock behind that same gate. Use the explicit recovery path instead of reaching for raw `gh api`:

```bash
carson recover --check "Carson governance"
```

Recovery is narrow. Carson proves that the named check is red on the default branch, verifies that the current branch is repairing the governance surface, requires every other required check and the review gate to pass, then records a machine-readable audit event before reporting success.

If Carson refuses recovery, the message explains the exact missing proof or remaining gate and tells you what to do next.

**5. Clean up landed work** — once the delivery is integrated, use Carson cleanup commands from the main worktree. `worktree list` shows every registered worktree with PR state, absorbed-into-main detection, and Carson's cleanup recommendation:

```bash
cd /path/to/repo
carson worktree list
carson housekeep
```

`housekeep` still performs safe reaping and branch pruning when `sync` cannot complete. A blocked sync no longer prevents cleanup work that has its own safety evidence. Absorbed-into-main detection is informational; Carson only auto-reaps when it also has stronger abandonment evidence such as a missing directory, merged PR, or closed abandoned PR.

`housekeep` also reconciles integrated delivery worktree records from the ledger. If the recorded worktree is already gone, Carson clears the stale ledger path. If the worktree still points at the integrated head and is safe to remove, Carson reaps it and clears the ledger path in the same pass.

When you need to abandon a stale branch or PR instead of landing it:

```bash
carson abandon 291
# or:
carson abandon https://github.com/owner/repo/pull/291
# or:
carson abandon feature/stale-work
```

`abandon` closes the PR when it is still open, removes the matching worktree when safe, deletes the local and remote branch refs when allowed, and marks the delivery as failed in Carson's ledger.

**Safety guards** — `worktree remove` blocks when:
- Shell CWD is inside the worktree (prevents session crash).
- Branch has unpushed commits with content that differs from main (prevents data loss).

After squash or rebase merge, the content matches main — removal proceeds without `--force`.

**Stale worktree recovery** — if a worktree directory is destroyed externally (for example by a raw GitHub merge/delete flow), `worktree remove`, `worktree list`, `housekeep`, and `prune` handle the stale entry gracefully: they clean up the git registration and delete the branch without error when Carson has enough evidence. Use Carson's delivery and cleanup commands instead of raw `gh pr merge --delete-branch` so the worktree directory stays intact for orderly cleanup.

### Carson vs Claude Code EnterWorktree

Claude Code has a built-in `EnterWorktree` tool. Both create a git worktree under `.claude/worktrees/` with a new branch — but they solve different problems and have different trade-offs.

**What Carson adds over EnterWorktree:**

| Concern | EnterWorktree | Carson |
|---|---|---|
| Governed baseline before branching | No — branches from current HEAD, which may be stale | Yes — branches from the repo's governed baseline rather than the caller's current HEAD |
| CWD guard on removal | No | Yes — blocks if shell is inside the worktree |
| Unpushed-commits guard | No | Yes — blocks if work hasn't been pushed |
| Content-aware squash/rebase detection | No | Yes — compares tree content, not SHAs |
| Branch cleanup (local + remote) | No | Yes — one command removes worktree, local branch, and remote branch |
| `.git/info/exclude` management | No | Yes — prevents `.claude/` appearing as untracked |
| Recovery-aware errors | No | Yes — every error includes a concrete recovery command |
| `--json` output | No | Yes — machine-readable for agent consumption |

**What EnterWorktree does that Carson does not:**

- **Automatic session CWD switch.** After creating the worktree, Claude Code moves the agent's working directory into it — no manual `cd` required. This is genuine friction that Carson should learn from.

**What EnterWorktree gets wrong:**

- **Session-exit cleanup prompt.** On session exit, Claude Code asks the user whether to keep or remove each worktree. In an agent workflow this is pure friction — the user cannot verify the state of bot-created worktrees and is forced to choose "keep" every time. Carson's approach is better: deferred deletion by default, with safety guards when you do choose to clean up.
- **Random names.** Without a name argument, EnterWorktree generates a random string. `git branch` output becomes unreadable. Carson requires a meaningful name that doubles as the branch name.

**Relationship — complementary, not competing:**

The two tools serve different layers. EnterWorktree owns the session (CWD switch); Carson owns the git lifecycle (sync, safety, cleanup). The ideal integration is Claude Code's `WorktreeCreate`/`WorktreeRemove` hook mechanism — Carson registers as the hook handler, so `EnterWorktree` delegates creation to `carson worktree create` and gets both Carson's safety and Claude Code's automatic CWD switch.

## Daily Operations

**Start of work:**

```bash
carson sync                                          # fast-forward local main
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

**Portfolio overview:**

```bash
carson repos           # list all governed repositories
carson repos --json    # machine-readable output
carson status --all    # branch, worktrees, governance per repo
```

**Portfolio maintenance (Layer 2):**

All `--all` commands run across every governed repository registered via `carson onboard`.

```bash
carson refresh --all           # re-apply hooks, templates, audit across all repos
carson sync --all              # fast-forward main across all repos
carson audit --all             # governance audit across all repos
carson prune --all             # remove stale branches across all repos
carson template check --all    # detect template drift across all repos
carson housekeep --all         # full maintenance cycle across all repos
carson housekeep --all --loop 300   # housekeep every 5 minutes
```

`refresh --all` checks each repo for safety before operating: repos with active worktrees or uncommitted changes are skipped with clear reasons. Other batch commands attempt each repo and report failures without stopping.

`housekeep --all --loop SECONDS` runs the full housekeep cycle continuously, sleeping SECONDS between passes. It requires `--all`, accepts only positive integers, and exits cleanly on `Ctrl-C` with a cycle count summary.

**Periodic maintenance:**

```bash
carson review sweep    # update tracking issue for late review feedback
carson prune           # remove stale local branches
```

## Running Carson Govern Continuously

Use `--loop SECONDS` to run `carson govern` as a persistent daemon that cycles on a schedule:

```bash
carson govern --loop 300              # cycle every 5 minutes
carson govern --loop 300 --dry-run    # observe mode, no integration or revision dispatch
```

The loop is built-in and cross-platform — no cron, launchd, or Task Scheduler required. Run it in a terminal, tmux, screen, or as a system service.

Each cycle runs independently: if one cycle fails (network error, GitHub API timeout), the error is logged and the next cycle proceeds normally. Press `Ctrl-C` to stop — Carson exits cleanly with a cycle count summary.

### Govern and Coding Agents

`carson govern` dispatches coding agents (Codex or Claude) when an active delivery is blocked by CI, review, or policy feedback. The agent receives the failure context and attempts a revision. If the agent succeeds, the delivery re-enters the governance pipeline. If it fails repeatedly or times out, the delivery is escalated for human attention.

After a live merge attempt, govern reports the actual outcome. Failed merges stay held at gate instead of being reported as integrated. Successful integrations also report merge proof for the landed branch.

After CI and review pass, Carson still checks GitHub mergeability. Conflicting PRs exit as `Merge blocked` with an explicit merge-conflict summary. `BEHIND` is treated as a freshness failure, not a harmless squash detail: Carson blocks and requires a branch refresh before it will continue.

After a successful govern merge, Carson runs the same cleanup path as `carson housekeep`: sync, reap safe worktrees, then prune.

The agent provider is configurable via `govern.agent.provider` (`auto`, `codex`, or `claude`). In `auto` mode, Carson selects the first available provider.

## Governed Integration Policy

Governed integration is fixed to `squash`. Carson no longer exposes merge-method choice for governed delivery, and config validation rejects non-squash values.

**Why squash is fixed.** Squash-to-main keeps history linear: one delivered branch = one commit on main. Every commit on main corresponds to a reviewed, CI-passing unit of work. The benefits:

- `git log --oneline` on main tells the full story without merge noise or work-in-progress commits.
- Every commit is individually revertable — `git revert <sha>` undoes exactly one PR.
- `git bisect` operates on meaningful boundaries, not intermediate fixup commits.
- Individual branch commits are still preserved in the PR on GitHub for full traceability.

**When to use other methods:**

There is no governed manual-final-merge mode. Repositories that require a human to perform the final merge are outside Carson's governed delivery contract.

## Defaults and Why

### Principles (iron rules)

These define what Carson *is*. They are not configurable.

- **Outsider boundary** — Carson never places its own artefacts inside a governed repository.
- **Canonical delivery** — your canonical `.github/` files distributed into each governed repo, zero per-repo drift. What those files contain is your call.
- **Active review** — undisposed reviewer findings block merge; feedback must be acknowledged.
- **Self-diagnosing output** — every warning and error names what went wrong, why, and what to do next.
- **Transparent governance** — Carson prepares everything for merge but never makes decisions without telling you.
- **Structural-edit discipline** — coding agents must not use Python or other blind text-rewrite scripts to edit Carson's Ruby source. Ruby files are edited with scoped patches or Ruby-aware tools so structural `end` boundaries are not truncated by cross-language text munging.

### Configurable defaults

These are starting points chosen during `carson setup`. Every default has a reason, but all can be changed.

#### Workflow style

How code reaches main.

- **`branch`** (default) — every change goes through a PR. Hooks block direct commits and pushes to main/master. PRs enforce review and CI gates before code reaches main.
- **`trunk`** — commit directly to main. Hooks allow all commits. Suits solo projects or flat teams that don't need PR-based review.

Change: `carson setup` or `CARSON_WORKFLOW_STYLE`.

#### Governed integration

How Carson lands ready deliveries.

- **`squash`** (fixed) — one delivered branch = one commit on main. Linear, bisectable history. Branch commits remain visible in the PR on GitHub.

This is part of Carson's governed contract, not a setup preference.

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

Change: `CARSON_HOOKS_PATH`.

#### Review disposition

Whether reviewer findings require acknowledgement.

- Default: **required**. Comments containing risk keywords (`bug`, `security`, `regression`, etc.) must have a `Disposition:` response from the PR author before merge. Prevents feedback from being buried.

Change: `CARSON_REVIEW_DISPOSITION`.

#### Output verbosity

How much Carson prints.

- Default: **concise**. A healthy audit prints one line. Problems print actionable summaries with cause and fix.
- `--verbose` restores full diagnostic key-value output for debugging.

## Configuration

Default global config path: `~/.carson/config.json`.

Precedence (highest wins): environment variables > config file > built-in defaults.

Override the config file path with `CARSON_CONFIG_FILE=/absolute/path/to/config.json`.

Common environment overrides:

| Variable | Purpose |
|---|---|
| `CARSON_HOOKS_PATH` | Custom hooks installation directory. |
| `CARSON_REVIEW_WAIT_SECONDS` | Initial wait before first review poll. |
| `CARSON_REVIEW_POLL_SECONDS` | Interval between review polls. |
| `CARSON_REVIEW_MAX_POLLS` | Maximum review poll attempts. |
| `CARSON_REVIEW_DISPOSITION` | Required disposition keyword for review comments. |
| `CARSON_REVIEW_SWEEP_WINDOW_DAYS` | Lookback window for review sweep. |
| `CARSON_REVIEW_SWEEP_STATES` | PR states to include in sweep. |
| `CARSON_REVIEW_BOT_USERNAMES` | Comma-separated bot usernames to ignore in review gate and sweep. |
| `CARSON_WORKFLOW_STYLE` | Workflow style override (`branch` or `trunk`). |
| `CARSON_RUBY_INDENTATION` | Ruby indentation policy (`tabs`, `spaces`, or `either`). |

For the full configuration schema, see `API.md`.

## Troubleshooting

**`carson: command not found`**
- Confirm Ruby and gem installation.
- Confirm `$(ruby -e 'print Gem.user_dir')/bin` is in `PATH`.

**`review gate` fails on actionable comments**
- Respond with a valid disposition comment using the required disposition keyword.
- Re-run `carson review gate`.

**Template drift blocks**

```bash
carson template apply
carson template check
```

**Hook version mismatch after upgrade**
- Run `carson refresh` to re-apply hooks and templates for the new Carson version.
- Run `carson refresh --all` to refresh all governed repositories at once.

**Template auto-propagation**

When `carson refresh` detects template drift, it applies the updates locally and then auto-propagates them to the remote:

- **Branch workflow** (default): creates a `carson/template-sync` branch, pushes updates, and opens (or updates) a PR. Re-running refresh force-pushes to the same branch — idempotent.
- **Trunk workflow**: pushes template changes directly to main.

Propagation uses a temporary git worktree so the user's working tree and current branch are never disturbed. If propagation fails (no remote, push denied), the local apply still succeeds — propagation errors are reported but non-blocking.

## Offboard a Repository

To retire Carson from a repository:

```bash
carson offboard /path/to/your-repo
```

This removes Carson-managed host artefacts, unsets `core.hooksPath` when it points to Carson-managed global hooks, and deregisters the repository from `govern.repos` so `carson govern` and `carson refresh --all` no longer target it.

## Related Documents

- Mental model and command overview: `README.md`
- Formal interface contract: `API.md`
- Release notes: `RELEASE.md`
