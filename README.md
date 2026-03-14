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

## Two Authorities

Each governed repo chooses one integration authority.

**Remote** — remote `main` is the integration authority. Agents still work in local worktrees, but completed work rejoins through remote `main`.

**Local** — local `main` is the integration authority. Agents still work in local worktrees, but completed work rejoins through local `main`, then `main` is pushed to the remote as backup.

This is about where completed work rejoins shared truth, not about team size. Both authorities use worktrees. The authority changes how work lands, not whether Carson is needed.

## Principles

- **Worktree-first** — substantive work happens in worktrees, not on `main`.
- **Carson-owned operations** — Carson owns worktree and delivery operations in governed repositories.
- **Self-diagnosing output** — every block should say what happened and the exact next command.
- **Outsider boundary** — Carson governs repositories without becoming a host-repository runtime dependency.

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your `PATH`. `gh` (GitHub CLI) is recommended for review governance features.

```bash
gem install carson
carson onboard your/repo/path

carson worktree create your-worktree
cd your/repo/path/.claude/worktrees/your-worktree

# work, test, commit
carson deliver
carson status

# keep govern running to advance queued deliveries
carson govern --loop 300
```

By default, repositories onboard as `remote`. `carson deliver` is the branch handoff: it pushes the branch, creates or refreshes the PR, records delivery state, and returns immediately. `carson status` shows the active branch deliveries, and `carson govern` advances queued work across the governed portfolio.

## Portfolio Layer

Single-repo depth comes first. Once multiple repositories are onboarded, the same discipline scales out across them:

```bash
carson status --all
carson refresh --all
carson govern --dry-run
```

`carson govern` is the portfolio layer. It advances queued deliveries, dispatches revision work for blocked branches, and surfaces what needs human judgement. Governed integration is squash-only and happens one repository at a time.

## Where to Read Next

- **MANUAL.md** — installation, setup, operating strategies, daily workflows, command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
