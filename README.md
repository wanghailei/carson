<img src="icon.svg" width="141" alt="Carson">

# ⧓ Carson

*Carson at your service.*

Named after the head of household in Downton Abbey, Carson is your autonomous git strategist and repositories governor — you write the code, Carson manages everything else. From commit-time checks through PR triage, agent dispatch, merge, and cleanup, Carson runs the household with discipline and professional standards. Carson itself has no intelligence — it follows a deterministic decision tree. The intelligence comes from the coding agents it dispatches (Codex, Claude) to fix problems.

## The Problem

Managing a growing portfolio of repositories is rewarding work — but the operational overhead scales faster than the code itself. PR templates go stale, reviewer feedback gets quietly buried, and what passes on a developer's laptop fails in CI. When coding agents start producing PRs across multiple projects, the coordination load multiplies: checking results, dispatching fixes, clicking merge, cleaning up branches.

Carson exists so you can focus on what matters — building — while governance runs itself.

## What Carson Does

Carson is an autonomous git strategist and repositories governor that lives on your workstation and in CI, never inside the repositories it governs. Two roles, one tool:

**Git strategist** — Carson knows *when* to branch, *how* to isolate concurrent work, *what order* to merge, and *how* to recover from failures. Every git decision encodes a strategy learned from real agent workflow failures.

**Repositories governor** — Carson enforces rules, gates merges, manages templates, and coordinates coding agents across your portfolio. `carson govern` triages every open PR: merge what's ready, dispatch agents to fix what's failing, escalate what needs human judgement. One command, all your projects, unmanned.

```
  ~/.carson/                     ← Carson lives here, never inside your repos
       │
       ├─ hooks ──────────────►  commit gates      (every governed repo)
       └─ govern ─────────────►  PR triage → merge | dispatch agent | escalate
```

This separation is Carson's defining trait — the **outsider boundary**: no Carson scripts, config files, or governance payloads are ever placed inside a governed repository.

### Strategies

Carson's git decisions are not arbitrary — each encodes a strategy learned from real failures.

**As git strategist:**

- **Sync before branch** — always pull main before creating any branch. Stale bases cause merge pain; Carson eliminates them at the source.
- **Worktree isolation** — all concurrent work happens in worktrees, never the main working tree. Prevents cross-agent conflicts and keeps the host repository clean.
- **Atomic delivery** — commit, push, PR, and merge as one continuous flow via `carson deliver`. No half-shipped states.
- **Content-aware merge detection** — proves branch content is on main regardless of how it was merged (squash, rebase, or fast-forward). Compares file content, not commit SHAs — so squash-merged branches are correctly recognised as done.
- **Fast-forward-only main** — main stays linear. Non-fast-forward pulls are rejected. If main has diverged, something is wrong — Carson surfaces it instead of papering over it.
- **Push rejection recovery** — when a push is rejected as non-fast-forward, Carson triages by context: if an open PR exists, advise a fresh branch (force-push would disrupt review); if no PR, clean up the stale remote ref and re-push.
- **Worktree-aware merge** — inside a worktree, Carson merges without `--delete-branch` (which would fail because main is already checked out elsewhere). Branch cleanup is deferred to `carson prune`, run from the main tree.
- **Post-merge guidance** — after a successful merge, Carson detects where the agent is (worktree or main tree) and provides the exact next command for cleanup.

**As repositories governor:**

- **Outsider boundary** — no Carson-owned artefacts inside governed repositories. Offboarding leaves no trace.
- **Active review gating** — every reviewer comment must be explicitly acknowledged (accepted, rejected, or deferred) before merge. Feedback is never silently buried.
- **Command interception** — blocks raw `git push` and `gh pr create/merge` from agents via a three-layer guard (pre-push hook, PreToolUse hook, main-branch push guard). Redirects to `carson deliver`.
- **Portfolio triage** — `carson govern` classifies every open PR across all governed repos through ordered gates: CI status, review decision, review gate. Each PR gets one disposition: merge, dispatch agent, or escalate.
- **CI baseline enforcement** — if the default branch CI is broken, Carson blocks operations. Fix the baseline before merging anything new.
- **Advisory vs critical checks** — checks are stratified by severity. Critical checks block merge; advisory checks warn but do not block.
- **Check-wait window** — a grace period for CI checks to register before triage. Avoids premature merge while checks are still spinning up.
- **Review convergence** — polls review state until activity stabilises (two consecutive identical snapshots). No premature merge while comments are still arriving.
- **Agent dispatch deduplication** — tracks dispatched agents per PR and objective. Running agents are not re-dispatched; failed agents are retried.
- **Pending tracking** — batch operations track repos that were skipped (active worktree, uncommitted changes) and retry them on the next `--all` run.
- **Template propagation** — syncs templates via a detached worktree with hooks disabled (prevents recursive Carson invocation). Trunk repos push directly; branch repos create a PR.

**Safety strategies:**

- **Process-aware worktree removal** — before removing a worktree, checks if the current shell or any other process (via `lsof`) has its CWD inside it. Blocks removal with a recovery command instead of crashing the shell.
- **Stale worktree sweep** — before batch operations, removes worktrees whose branches are already absorbed into main. Prevents stale worktrees from blocking `refresh --all` or `housekeep --all`.
- **Branch protection** — never deletes branches held by active worktrees. Prune skips them with a diagnostic message.
- **Environment signalling** — sets `CARSON_PUSH=1` during managed pushes so pre-push hooks can distinguish Carson-governed pushes from raw agent pushes.
- **Self-diagnosing errors** — every error names what happened, why, and the exact command to fix it. If you have to read source code to understand a message, that message is a bug.
- **Self-configuring** — running any Carson command installs all safety guards (hooks, command guard, config). No manual post-install setup.

### Principles

Carson is opinionated about governance. These are non-negotiable principles, not configurable defaults:

- **Outsider boundary** — Carson lives outside your repo, never inside. No Carson-owned artefacts in your repository. Offboarding leaves no trace.
- **Active review** — undisposed reviewer findings block merge. Feedback must be acknowledged, not buried.
- **Self-diagnosing output** — every warning and error names what went wrong, why, and what to do next. If you have to read source code to understand a message, that message is a bug.
- **Transparent governance** — Carson prepares everything for merge but never oversteps. It does not make decisions for you without telling you.

Everything else bends to your preference. Which branch is main, how PRs are merged, which repositories to govern, which coding agent to dispatch — Carson asks during setup and remembers. Sensible defaults are provided; you only change what matters to you. See `MANUAL.md` for the full list.

## When to Use Carson

- **You run coding agents across multiple repositories** and need a single command that triages every open PR, merges what's ready, dispatches agents to fix what's broken, and reports what needs your attention.
- **Your PR feedback gets buried.** Carson blocks merge until every reviewer comment is explicitly acknowledged — accepted, rejected, or deferred — so nothing is silently ignored.
- **CI breaks and nobody notices.** `carson audit` runs on every commit via managed hooks, and `carson govern` watches CI status across your portfolio continuously.
- **You onboard new repositories often** and want consistent hooks, templates, and governance from the first commit without manual setup.
- **You want agent-safe worktree management.** `carson worktree create` auto-syncs, branches, and isolates; `carson worktree remove` guards against unpushed work and active shells before cleanup.

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your PATH. `gh` (GitHub CLI) is recommended for full review governance features.

```bash
gem install carson
```

**Onboard a repository:**

```bash
carson onboard /path/to/your-repo
```

On first run, Carson walks you through setup — remote, main branch, workflow style, merge method — then installs hooks, syncs templates, and runs an initial audit.

After `carson onboard`, your repository has:
- Git hooks that run `carson audit` on every commit.
- Managed `.github/*` templates synchronised from Carson.
- An initial governance audit report.

Commit the generated `.github/*` changes, and the repository is governed.

**Govern your portfolio.** Once repositories are onboarded, `carson govern` is your recurring command. Run it whenever you want Carson to triage open PRs, enforce review policy, and dispatch coding agents across all governed repos:

```bash
carson govern --dry-run     # preview what Carson would do, change nothing
carson govern               # triage PRs, merge ready ones, dispatch agents
carson govern --loop 300    # run continuously, cycling every 5 minutes
```

## Where to Read Next

- **MANUAL.md** — installation, first-time setup, CI configuration, daily operations, full command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
