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
       ├─ worktree flow ──────►  create → work → deliver → clean up
       └─ portfolio layer ────►  status --all | refresh --all | govern
```

The outsider boundary still matters: Carson governs repositories without becoming a runtime dependency inside them.

## Principles

- **Worktree-first** — substantive work happens in worktrees, not on `main`.
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

# work and test, then either commit yourself or let Carson create the delivery commit
carson deliver --commit "fix: describe this delivery"

# inspect cleanup recommendations once the work is landed
carson worktree list
```

`carson deliver` owns the normal branch-delivery path: before any push, Carson verifies the branch is fresh against the configured remote `main`. If freshness is behind or unknown, delivery stops with an explicit block and no PR side effect. If the branch is fresh, Carson pushes the branch, creates or refreshes the PR, watches the delivery for a bounded settle window, merges when clear, and syncs local `main`. If the settle window expires without integration, Carson exits with an explicit `Merge deferred` or `Merge blocked` handoff instead of leaving the PR mysteriously open. Deferred and blocked exits say whether Carson attempted merge and list the next commands in order. Use plain `carson deliver` when the branch is already committed. Use `carson deliver --commit "..."` when the worktree is dirty and Carson should create one all-dirty delivery commit first.

When one Carson-governed required check is already red on the default branch and the current PR is the repair, use `carson recover --check "..."`. Recovery is the explicit exceptional path: Carson proves the baseline failure, keeps every other gate intact, records an audit event, and never teaches operators to step outside Carson first.

`carson worktree list` is the visibility surface for cleanup: it shows every registered worktree, the branch, PR state, whether the content is already on `main`, and Carson's keep or reap recommendation. When work needs to be abandoned instead of landed, use `carson abandon <pr-number|pr-url|branch>` to close the PR and clean up the branch/worktree safely.

## Portfolio Layer

Single-repo depth comes first. Once multiple repositories are onboarded, the same discipline scales out across them:

```bash
carson status --all
carson refresh --all
carson govern --dry-run
```

`carson govern` is the portfolio layer. It reassesses active deliveries across governed repositories, dispatches revision work for blocked branches, and surfaces what needs human judgement. Governed integration is squash-only and happens one repository at a time.

## Where to Read Next

- **MANUAL.md** — installation, setup, operating strategies, daily workflows, command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
