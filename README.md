<img src="icon.svg" width="141" alt="Carson">

# ⧓ Carson

Named after the butler of Downton Abbey, Carson is a strategic governor for multiple agents working in one repo.

Carson is deterministic infrastructure for simultaneous agent work. It governs how work starts, lands, and cleans up so agents can code without trampling each other. The agents provide the intelligence; Carson provides the discipline.

Carson was built in real multi-agent work. Its strategies come from scars: it was forged while running more than ten agents across multiple projects at once and fixing the failures that kept repeating.

## The Problem

When several agents work on one repository, plain Git stops being enough. Branches start from different bases, work lands back on `main` through inconsistent paths, old worktrees linger, and one cleanup step can disrupt another session. The same problem appears again at portfolio scale, but it starts inside a single repo.

Carson solves the single-repo concurrency problem first, then applies the same discipline across multiple repositories.

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

Carson 4 has two repo authorities.

**Remote** — remote `main` is the integration authority. Agents still work in local worktrees, but completed work rejoins through remote `main`.

**Local** — local `main` is the integration authority. Agents still work in local worktrees, but completed work rejoins through local `main`, then `main` is pushed to the remote as backup.

Both authorities use worktrees. The authority changes how work lands, not whether Carson is needed.

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your `PATH`. `gh` (GitHub CLI) is recommended for full review governance features.

```bash
gem install carson
```

Onboard a repository:

```bash
carson onboard ~/Dev/your-repo
```

By default, Carson onboards repositories as `remote`. Switch authority when needed:

```bash
carson repo authority local
```

Then use the core worktree loop:

```bash
carson worktree create fix-login
cd ~/Dev/your-repo/.claude/worktrees/fix-login

# work, test, commit

carson deliver --merge
# Carson prints the exact next clean-up step.

cd ~/Dev/your-repo
carson worktree remove fix-login
carson prune
```

In `remote`, `deliver` lands through remote `main`. In `local`, the same loop lands on local `main` and then pushes `main` to the remote as backup.

## Portfolio Layer

Single-repo depth comes first. Once multiple repositories are onboarded, the same discipline scales out across them:

```bash
carson status --all
carson refresh --all
carson govern --dry-run
```

`carson govern` is the portfolio layer: it triages open PRs, merges what is ready, dispatches agents to fix what is failing, and reports what needs human judgement.

## Principles

- **Worktree-first** — substantive work happens in worktrees, not on `main`.
- **Carson-owned operations** — Carson owns worktree and delivery operations in governed repositories.
- **Self-diagnosing output** — every block should say what happened and the exact next command.
- **Outsider boundary** — Carson governs repositories without becoming a host-repository runtime dependency.

## Where to Read Next

- **MANUAL.md** — installation, setup, operating strategies, daily workflows, command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
