# Carson Product Definition

## Product statement
Carson is an outsider governance runtime that keeps repository governance consistent without embedding Carson-owned runtime artefacts inside client repositories.

Named after Carson, the head of household in Downton Abbey, Carson embodies the same role for your repositories: you write the code, Carson manages everything else — from commit-time checks through merge-readiness on GitHub to cleaning up your local workspace afterwards. Like the consummate head of staff, Carson runs the household with strict discipline and professional standards, but never oversteps — it prepares everything for the merge decision without making it, and keeps the estate (your repositories) in impeccable order without owning it.

## Problem statement
Repository controls degrade when local workflows diverge, review handling is inconsistent, or policy checks are treated as optional. Developers should focus on writing code, not on chasing unresolved review comments, keeping templates in sync, or pruning stale branches. Teams need a repeatable governance layer that is strict enough for enterprise stability while remaining operationally practical — one that takes over the entire housekeeping burden so developers never think about it.

## Target outcomes
- Deterministic governance checks for local and CI operation.
- Clear hard-stop behaviour when policy is violated.
- Minimal host-repository footprint with explicit outsider boundaries.
- Predictable onboarding and daily operation for repository maintainers.

## In-scope capabilities
- Local governance commands (`onboard`, `audit`, `sync`, `prune`, `template`, `review`, `offboard`, `refresh`, `refresh --all`).
- Portfolio governance commands (`govern`).
- Review governance via `review gate` and `review sweep`.
- Whole-file management of selected GitHub-native policy files under `.github/*`.
- Strict exit status contract suitable for automation.

## Out-of-scope capabilities
- Replacing GitHub as merge authority (Carson has optional merge authority gated by `govern.auto_merge`, but defers to GitHub rulesets and human judgement by default).
- Deciding business-domain policy for host repositories.
- Executing force merges or bypassing required checks.
- Persisting Carson-specific configuration inside host repositories.

## Primary users
- Repository maintainers responsible for policy enforcement.
- Internal platform teams operating governance at scale.
- CI owners needing deterministic pass/fail policy signals.

## Success criteria
- New repository can reach governed baseline through one command (`carson onboard`).
- Daily governance cadence is short and repeatable.
- Policy failures are actionable and deterministic.
- Host repositories remain free of Carson-owned runtime fingerprints.

## Ideal user journey

### Stage 1 — Installation

The user installs Carson with one command and it is immediately usable. No project scaffolding, no configuration wizard, no environment variables to set. Carson detects sensible defaults on first use.

The user does not think about Carson's installation again. If they upgrade, `bash install.sh` runs the upgrade and propagates any changes to governed repositories automatically.

### Stage 2 — Onboarding a repository

The user runs `carson onboard` once per repository. Carson asks only what it cannot detect: the merge method and whether to register the repo for portfolio governance. Everything else — remote, main branch, workflow style — is inferred from the repository itself.

After onboarding, the user commits the generated `.github/*` files. The repository is governed. That is the last time the user thinks about setup for that repository.

### Stage 3 — Daily commit flow

This is the core of the daily experience. The user writes code and commits. Most of the time, nothing happens — governance is healthy and Carson is silent. The commit goes through.

When governance is not healthy, the commit is blocked. Carson surfaces exactly one actionable message: what is wrong, and what command fixes it. The user runs that command, commits again. No digging through logs, no guessing.

The psychological contract: _silence means safety_. If Carson says nothing, the user can trust the commit is clean. This makes the occasional block feel informative rather than obstructive.

### Stage 4 — Review and merge

Before recommending a merge, the user runs `carson review gate`. Carson checks for unresolved review threads, outstanding CHANGES_REQUESTED reviews, and comments containing risk keywords. If anything is open, Carson reports it with the URL and blocks.

The user either resolves the thread or records a disposition (`Disposition: accepted`, `rejected`, or `deferred`) acknowledging the finding. Carson re-evaluates. When the gate passes, the user can recommend merge with full confidence that every reviewer comment has been seen and handled.

This stage removes the social anxiety of merge decisions — the user is not guessing whether something was missed. Carson has verified the record.

### Stage 5 — Portfolio governance

Once multiple repositories are onboarded, the user shifts from per-repo commands to portfolio commands. `carson govern` runs across all registered repositories: it triages open PRs, merges what is ready, dispatches coding agents to fix what is failing, and escalates what needs human judgment. The user reviews the escalation list; everything else was handled.

`carson refresh --all` keeps templates in sync across all repositories without the user visiting each one. When Carson is upgraded, this runs automatically.

The psychological contract at portfolio scale: _one command means all is well_. The user runs `carson govern`, sees the summary, and knows the state of every project.

### Stage 6 — Offboarding

When a repository no longer needs governance, `carson offboard` removes every Carson-managed file cleanly. The repository returns to exactly the state it was in before onboarding — no lingering hooks, no managed templates, no Carson configuration. The offboard is transparent: Carson lists every file it removes before removing it.

---

## UX principles

**Silence is the success signal.** Carson should not produce output when governance is healthy. Noise trains users to ignore messages. Every line Carson prints must carry information the user needs to act on.

**Every message is self-diagnosing.** A blocked commit, a failed audit, a drifted template — each message names what went wrong, why it matters, and what command resolves it. If a user has to read source code or documentation to understand a message, that message is a defect.

**Ask once, remember forever.** Carson prompts for preferences during setup and stores them. It never asks the same question twice. Re-running a command should feel identical to the first time, without re-entering preferences.

**Carson manages; the user decides.** Carson prepares everything for a merge decision but does not make it. It surfaces policy violations but does not bypass them. It dispatches agents to fix problems but reports what was done. The user retains authority; Carson handles the administration.

**Upgrades are invisible.** When Carson is updated, governed repositories are updated with it. The user should not need to visit each repository after an upgrade, remember to apply templates, or clean up old files. Carson does this automatically.

**Failures are exact.** Exit codes are deterministic. `0` means success. `2` means policy blocked — a known, expected state, not an error. `1` means something unexpected went wrong. Automation can trust the exit code; humans can read the message.

## Core design decision

**Carson is for coding agents, not for humans.** The primary user of Carson's commands and lifecycle management is the coding agent working on behalf of the developer. What makes working with agents best — therefore makes the human owners most happy with no burden — Carson should handle. Carson is confident because it is professional and knows things deeply well. It does not hedge, guess, or ask unnecessary questions. It acts with the certainty of a butler who has managed the household for decades.

The human owner benefits indirectly: when Carson keeps the agent's environment disciplined and predictable, the agent produces better work, and the human never has to intervene in housekeeping. The ideal state is that the human owner forgets Carson exists — everything just works.

## Architecture principles

**Single-repo depth is the core.** Working on one repository thoroughly well is the essence and the foundation. Multi-repo governance is just the same discipline repeated across the estate. Get the single-repo story perfect first; multi-repo follows naturally with `--all`.

**`--all` is the elegant extension.** Every command that works on a single repository gains cross-repo reach through a single `--all` flag. No separate commands, no different mental model — same operation, wider scope. The flag says "do what you always do, but everywhere."

**Worktree lifecycle is first-class.** Coding agents use worktrees as their unit of work, not branches. Carson should own the full worktree lifecycle: create, track, and clean up.

The safe teardown order is an iron rule:

1. Exit the worktree (cd to the main repository root).
2. `git worktree remove <path>` — removes the directory and the worktree registration.
3. Branch cleanup — delete the local branch, prune the remote.

If any step is skipped or reordered, the agent's shell CWD can land inside a deleted directory. Once that happens, the shell tool becomes permanently unusable for the rest of the session — every command fails with "path does not exist" before it even runs. The only escape hatch is recreating the directory with a file-write tool, which is fragile and error-prone.

Carson must enforce this order so agents never have to remember it. The goal: worktree teardown is one command, always safe, never leaves debris.

## Open decisions

**Overseer model (3.0.0).** Carson's current model is per-repo: `carson onboard` sets up each repository individually. The future model is central oversight: repositories are *registered* under Carson's protection, and Carson oversees all of them by default. This makes cross-repo operations natural — you never need to know which repo you're standing in to manage the estate. The vocabulary shifts from "onboard" to "register." This is the 3.0.0 boundary.
