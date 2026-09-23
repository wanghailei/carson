<img src="icon.svg" width="141" alt="Carson">

# ⧓ Carson

Named after the butler of Downton Abbey, Carson is a strategic governor for multiple agents working in one repo.

Carson is deterministic infrastructure for concurrent agent work. It governs how work starts, how it rejoins shared truth, and how the repo is cleaned up afterwards so agents can code without trampling each other. The agents provide the intelligence; Carson provides the discipline.

Carson was built in real work. Its strategies come from scars: more than ten agents running across multiple projects at once, with each repeated failure turned into a rule, guardrail, or recovery path.

## The Problem

When several agents work on one repository, plain Git leaves too much to habit. Branches start from different bases, work lands back on `main` through inconsistent paths, old worktrees linger, and one clean-up step can disrupt another session.

Carson solves that single-repo concurrency problem first, then extends the same discipline across multiple repositories.

## What Carson Does

Carson lives on your workstation and in CI, never inside the repositories it governs. Two roles, one tool:

**Git strategist** — Carson decides how new work begins, which base it uses, how it returns to shared truth, and how cleanup happens safely.

**Repo governor** — Carson enforces the repo's operating contract: worktree-first flow, Carson-owned delivery operations, policy checks, and exact recovery guidance when work cannot proceed.

```
  ~/.carson/                     ← Carson lives here, never inside your repos
       │
       ├─ hooks ──────────────►  commit gates and command guards
       ├─ worktree flow ──────►  create → work → deliver → housekeep
       └─ portfolio layer ────►  list | refresh | receive
```

The outsider boundary still matters: Carson governs repositories without becoming a runtime dependency inside them.

## Principles

- **Worktree-first** — substantive work happens in worktrees, not on `main`.
- **Single landing path** — completed work rejoins shared truth through remote `main` via PR-based delivery.
- **Carson-owned operations** — Carson owns worktree and delivery operations in governed repositories. Raw `git worktree add/remove`, raw `git pull --rebase`, and raw `gh pr create/merge` are blocked, and `git add` / `git commit` are blocked on the main working tree until you create a Carson worktree.
- **Self-diagnosing output** — every block should say what happened and the exact next command.
- **Outsider boundary** — Carson governs repositories without becoming a host-repository runtime dependency.

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your `PATH`. `gh` (GitHub CLI) is recommended for review governance features.

```bash
gem install carson
carson onboard your/repo/path

carson worktree create your-worktree
cd your/repo/path/.claude/worktrees/your-worktree

# Carson places the worktree under the calling harness's agent directory:
# .claude/worktrees/ from Claude Code, .pi/worktrees/ from Pi
# (detected via PI_CODING_AGENT). Set CARSON_AGENT_DIR to override.

# work and test, then commit and hand the branch to Carson
git add -A
git commit -m "fix: describe this delivery"
carson deliver

# or let Carson create one all-dirty delivery commit:
# carson deliver --commit "fix: describe this delivery"

# once the delivery is integrated, clean up from the repo root
cd your/repo/path
carson housekeep
```

`carson deliver` runs Carson-owned branch delivery. Before any push, Carson verifies that the branch is fresh against the configured remote `main` using local git. If freshness is behind or unknown, delivery stops with an explicit block and no PR side effect. After a PR exists, Carson delegates merge eligibility to GitHub's `mergeStateStatus` — if GitHub reports `CLEAN`, Carson proceeds regardless of local ancestor status. Plain `deliver` transports existing commits only; `carson deliver --commit "..."` creates one all-dirty delivery commit first, then continues the same flow. If the branch is fresh, Carson pushes it, creates or refreshes the PR, watches the delivery for a bounded settle window, merges when clear, and syncs local `main`. If the settle window expires without integration, Carson exits with an explicit `Merge deferred` or `Merge blocked` handoff instead of leaving the PR mysteriously open. Deferred and blocked exits say whether Carson attempted merge and list the next commands in order.

When one Carson-governed required check is already red on the default branch and the current PR is the repair, use `carson recover --check "..."`. Recovery is the explicit exceptional path: Carson proves the baseline failure, keeps every other gate intact, records a recovery event, and never teaches operators to step outside Carson first.

`carson worktree list` is the visibility surface for cleanup: it shows every registered worktree, the branch, PR state, whether the content is already on `main`, and Carson's keep or reap recommendation. Content matching `main` is diagnostic, not standalone proof that a worktree is abandoned. `carson housekeep` is the main cleanup pass: sync main, reap worktrees with strong abandonment evidence (for example a missing directory, merged PR, or closed abandoned PR), and prune stale branches. When work needs to be abandoned instead of landed, use `carson abandon <pr-number|pr-url|branch>` to close the PR and clean up the branch/worktree safely.

## Portfolio Layer

Single-repo depth comes first. Once multiple repositories are onboarded, the same discipline scales out across them:

```bash
carson list
carson refresh
carson receive --dry-run
```

`carson <repo> receive` triages active deliveries for one repository: integrates ready branches, dispatches revisions for blocked work, and escalates what still needs human judgement. Governed integration is squash-only. Use `carson list --json` to script receive across your portfolio.

## Where to Read Next

- **MANUAL.md** — installation, setup, operating strategies, daily workflows, command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
