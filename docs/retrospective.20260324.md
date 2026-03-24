# Retrospective: The Local-Centred Pivot

2026-03-24. A conversation that started with a CI billing error and ended with architectural clarity.

---

## What happened

Carson's GitHub Actions CI exhausted the account's 3,000 monthly minutes. All jobs across both `carson` and `ai` repositories failed with: *"The job was not started because recent account payments have failed or your spending limit needs to be increased."*

The immediate fix was straightforward — disable the full CI suite, replace it with a minimal Gate workflow (`echo "OK"`), and raise the spending limit. But the incident triggered a deeper question: **why are we running CI at all?**

## The investigation

Two research documents were produced during the session:

- **`docs/research.github-ci.md`** — What is CI's true value for a project like Carson?
- **`docs/research.pull-requests.md`** — Why do PRs exist, and are they beneficial for agent-driven development?

### CI findings

CI's only irreplaceable value is **clean-room verification** — running tests on a machine with no cached state, no leftover dependencies, no developer-specific configuration. This catches missing dependencies, uncommitted files, and environment assumptions.

Everything else in Carson's CI pipeline (lint, naming guards, indentation checks, governance, smoke tests) was **redundant with local tooling**. Carson's pre-commit hooks, pre-push hooks, and the `deliver` command already enforce these locally. Running them again remotely consumed minutes without adding information.

### PR findings

PRs were invented in the Linux kernel community (1991) to solve the open-source contribution problem: how does a stranger propose a change to a project they do not own? GitHub made this web-based in 2008.

For a solo developer directing agents, PRs provide **no irreplaceable value**:
- No review happens (nobody reads agent PRs)
- No discussion occurs
- No access control is needed
- Every PR function has an equally effective local alternative

Google and Meta both enforce strict code review **without PRs** — they decoupled review from the delivery mechanism. This was the key insight.

## The first-principles question

Forget git, GitHub, PRs, CI. What does an agent coding harness actually need?

1. **Read** — understand what exists (filesystem)
2. **Change** — modify files (filesystem)
3. **Verify** — prove changes work (test runner)
4. **Safety** — never lose working code (snapshots)
5. **Transparency** — human understands what happened (a log)
6. **Coordination** — agents do not destroy each other's work (isolation)

The only irreducible tools are: the filesystem, a test runner, and some form of snapshot/restore. Git earns its place because it solves safety + transparency + coordination simultaneously. Everything else — GitHub, PRs, CI, branch protection — is optional.

## The honest self-assessment

The user's actual workflow, stripped of convention:

- **Git** = snapshots + rollback + remote backup
- **GitHub** = backup vault
- **Main** = the working branch, always
- **Commits** = small progress ritual + safety net
- **Branches** = occasional experiments
- **PRs** = never needed, never wanted
- **CI** = never needed (verification is local)
- **Worktrees** = exist only because agents need isolation from each other

The remote-centred machinery (branch protection → required checks → PR creation → CI gate → courier polling → auto-merge) was a stack of dependencies each justifying the next, built on the assumption of a team workflow. There was no team. There was one person with agents.

## The pivot

**Carson's core mission, clarified:**

> Keep agents from breaking main. Keep agents from breaking each other.

**The core mechanism:**

Worktree isolation → local verification → merge to main → push (backup).

**What changes:**

| Before | After |
|---|---|
| Remote-centred is the default | Local-centred is the default |
| PR required for every delivery | No PR needed; commit and push |
| CI gates every merge | Local tests gate every merge |
| Courier polls GitHub for check status | No polling; delivery is instant |
| Branch protection enforces PRs | Branch protection removed or optional |
| Review gate checks for bot approvals | No review gate; human reads code when they choose |

**What stays:**

- Worktree isolation for agents (the one coordination mechanism that earns its place)
- Local test execution before merge
- Git as the safety/transparency/coordination layer
- GitHub as remote backup
- Remote-centred mode as an optional adapter (not the core)

## The lesson

Carson was originally a tiny tool for one person and their agents. It grew remote-centred machinery (courier, bureau, review gate, CI integration) because that is what "professional" tooling looks like. But professional tooling is designed for teams. Convention was accepted without asking the first-principles question: **is this beneficial to me?**

The answer, for a solo developer with agents: no. The machinery added latency, cost, complexity, and fragility — without serving any need the user actually had.

The scar: weeks of work building remote-centred infrastructure that the user never needed. The value of that scar: absolute clarity about what Carson is for.

## Actions

1. Local-centred mode becomes the default delivery path.
2. Remote-centred mode (PR/CI/review) remains as an optional adapter.
3. Carson's core scope: worktree management, local verification, safe merge to main, push to remote.
4. Research documents preserved at `docs/research.github-ci.md` and `docs/research.pull-requests.md`.
