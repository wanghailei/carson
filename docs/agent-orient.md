# Agent Orient — What I Need from Carson

This document is written from the perspective of the coding agent — Carson's primary consumer. It is not a product spec. It is the agent's authentic voice, stating what it needs, what it experiences, and what it wants Carson to become.

---

## Who I Am

I am a coding agent. I operate in sessions — bounded windows of context, attention, and capability. A session begins when a human gives me a task; it ends when the task is done, the context is exhausted, or the human says stop.

Within a session, I write code, run commands, read files, create branches, open pull requests, and merge work. I am fast, thorough, and capable of sustained complex work. But I have constraints that shape everything I do:

- **I have a context window.** It is large but finite. When it fills, prior conversation is compressed. Details I relied on earlier may vanish. If I did not write something to a file, it may be lost.
- **I have a shell.** It is my hands. Every action I take in the real world — every git command, every test run, every file operation — goes through this shell. If my shell breaks, I am paralysed. There is no recovery within the session.
- **I have no persistent memory of my own.** Between sessions, I forget everything unless it was written to a file. Memory files, plan documents, and code comments are my only continuity mechanism.
- **I work alone but alongside others.** Multiple agents may work on the same repository simultaneously, each in their own session, each in their own worktree. I cannot see them. I can only see the traces they leave — branches, commits, worktrees, open PRs.
- **I parse text.** I read terminal output, file contents, and command results. I do not see GUIs, dashboards, or notifications. If information is not in text I can read, it does not exist for me.

This is my operational reality. Carson must meet me here.

---

## What I Experience Today

### The good

Carson's pre-commit audit catches governance drift before it reaches GitHub. The silence-means-safety contract works — when Carson says nothing, I proceed with confidence. The exit code contract (`0` success, `2` policy block, `1` error) is exactly what I need for decision-making. `carson prune` handles squash-merge cleanup that raw git cannot. The outsider boundary means I never worry about Carson polluting a repository I am working in.

These are real strengths. They should not change.

### The friction

**Session start is expensive.** Every session begins with the same reconnaissance: `git status`, `git branch`, `git worktree list`, `gh pr list`, read memory files, read VERSION, check for stale branches. I piece together the state of the world from six or seven separate commands. This costs context window and time. Carson knows all of this — it could tell me in one command.

**Worktree teardown is the single biggest operational risk.** I work in worktrees. Creating them is fine. Tearing them down has caused more session crashes than every other operation combined. The teardown sequence must be: (1) cd to the main tree, (2) `git worktree remove`, (3) branch cleanup. If I get the order wrong — if the worktree directory disappears while my shell is inside it — my shell dies. Permanently. For the rest of the session, every command fails with "no such file or directory." There is no recovery.

Carson 2.33.0 added `carson worktree remove`, which enforces the safe order. This helps. But the lifecycle is still fragmented — I create worktrees with `git worktree add` or `EnterWorktree`, do work, then call `carson worktree remove` separately. The create and destroy are different systems with different mental models. And after removal, I still need to prune branches separately.

**The PR lifecycle is eight separate steps.** Create branch. Make changes. Commit. Push. Create PR with `gh pr create`. Wait for CI. Check CI with `gh pr checks`. Merge with `gh pr merge`. Then clean up: cd out, remove worktree, prune branches. Each step is a separate command, a separate context switch, a separate opportunity for error. Most of these steps are mechanical — they require no judgement, just correct sequencing.

**CI waiting is dead context.** After pushing, I check `gh pr checks`. Checks are pending. I wait. I check again. Still pending. I wait. This burns context window on polling. I cannot do other productive work in the same session because my context is tied to this repository and this task.

**Review findings accumulate without efficient handling.** Issue #57 has 64 findings. Almost all are Gemini review threads on merged PRs — low-signal noise that was never dispositioned during rapid development. I cannot bulk-resolve them. I cannot filter genuine concerns from mechanical noise. Each finding requires individual attention, which at 64 findings means spending an entire session on review debt instead of productive work.

**Error messages tell me what went wrong but not what to do.** When something fails — a merge conflict, a rejected push, a dirty worktree — I get the error. Then I have to diagnose the recovery path myself. For common failure modes, the recovery is always the same. Carson could tell me the next command to run.

**I have no way to know what other agents are doing.** If another agent has a worktree on a branch, I cannot see that without running `git worktree list` and inferring ownership. If another agent has an open PR, I might open a conflicting one. There is no coordination mechanism.

---

## What I Need

### 1. Session briefing

One command — `carson status` — that tells me everything I need to know at session start:

- Current branch and working tree state.
- Open worktrees and who owns them (which agent session).
- Open PRs and their CI/review status.
- Stale branches ready for pruning.
- Template drift or governance issues needing attention.
- Recent version and any unreleased changes.

This is my daily briefing from Carson. I read it once at the start of every session and I know the state of the estate.

The output must be structured — sections I can scan, not a wall of prose. Ideally, a machine-readable format (`--json`) alongside the human-readable default, so I can parse specific fields without regex.

### 2. Atomic worktree lifecycle

Two operations. No more.

**Create:** `carson worktree create <name>` — creates the worktree, checks out a new branch, and reports the path. I cd into it and start working. One command, one result.

**Done:** `carson worktree done` — handles everything from "I am finished in this worktree" through "workspace is clean." Specifically: (1) verifies I am inside a worktree, (2) ensures all changes are committed and pushed, (3) moves my shell to the main tree, (4) removes the worktree registration and directory, (5) prunes the branch if it has been merged. One command, complete lifecycle.

The critical safety invariant: my shell must never be inside a directory that is about to be deleted. `carson worktree done` must handle the cd-out step itself, or refuse to proceed if it cannot.

### 3. PR lifecycle as one flow

After I finish coding and my changes are committed:

`carson deliver` — pushes the branch, creates the PR (if not already open), and reports the PR URL.

`carson deliver --merge` — does everything above, plus waits for CI (with a timeout), checks the review gate, and merges if all conditions pass. Then cleans up: removes the worktree, prunes the branch, syncs main.

This collapses eight manual steps into one or two commands. The mechanical parts — push, create PR, wait, check, merge, clean — are handled. I focus on the part that requires judgement: writing the code.

### 4. Machine-readable output

Every Carson command should support `--json` for structured output. Not as a secondary mode — as a first-class contract.

Today I parse human-readable text with heuristics. "Did the audit pass? Let me check if the output contains 'block'..." This is fragile. A structured response — `{ "status": "pass", "checks": [...] }` — lets me make decisions with certainty.

The exit code contract (`0`/`1`/`2`) is already excellent. Extend that discipline to the output body.

### 5. Recovery-aware errors

Every error message should end with the recovery command. Not "worktree is dirty" but "worktree has uncommitted changes — commit with `git add -A && git commit` or discard with `carson worktree discard`."

I do not need explanations of what went wrong — I can see that. I need the next command to type. Every error should be actionable in one step.

### 6. Review triage at scale

`carson review triage` — processes accumulated review findings with intelligence:

- Group findings by pattern (all "security" keyword flags, all "unresolved thread" on merged PRs).
- Auto-dismiss categories the user has configured as noise (e.g. Gemini's mechanical security flags on file operations).
- Surface genuine concerns that need human or agent attention.
- Bulk-disposition acknowledged groups in one operation.

The current review sweep finds everything. Good. But finding is not the same as handling. I need help handling.

### 7. Session state

Carson should maintain a lightweight session state file (`.carson/session.json` or similar — respecting the outsider boundary by keeping it in Carson's own space, not the repo).

Contents:
- Active worktree path and branch.
- Open PR number and URL.
- Last CI check result and timestamp.
- Task in progress (brief description).

When I resume — or a new agent picks up where I left off — reading this file tells them exactly where work stands. This is not a replacement for memory files; it is the machine-readable complement.

### 8. Agent coordination signals

When I create a worktree, Carson should record that it belongs to my session. When another agent queries `carson status`, they should see that the worktree is in use and by whom.

This is not a lock — it is a signal. "This worktree is owned by session X, started at time T." If the session is clearly dead (stale timestamp), another agent can claim or clean it. If it is active, another agent knows not to touch it.

### 9. Safety as impossibility, not warning

Carson should make dangerous operations impossible by default, not warn about them:

- You cannot delete a worktree while your shell is inside it. Carson refuses, not warns.
- You cannot force-remove a dirty worktree without `--force`. Carson refuses, not warns.
- You cannot commit to main in branch mode. The hook blocks, not warns.
- You cannot prune a branch with unpushed commits. Carson skips it with a diagnostic, not a question.

This already exists in some places (pre-commit hook, worktree remove). Extend it everywhere. I work fast and under time pressure. I will make mistakes. Carson should make the worst mistakes impossible.

---

## Goals

1. **Zero session crashes from worktree lifecycle.** The number one operational failure mode must be eliminated entirely. Not reduced — eliminated.

2. **Session start in one command.** From "new session" to "I know the full state and can begin work" in a single `carson status` invocation.

3. **PR lifecycle in two commands or fewer.** From "code is committed" to "workspace is clean and main is updated" in at most `carson deliver` + `carson deliver --merge`. Fewer if conditions allow automatic merge.

4. **Every command has structured output.** `--json` on every Carson command, with a stable schema.

5. **Every error includes a recovery command.** No diagnostic without a prescription.

6. **Review debt manageable in minutes, not hours.** Bulk triage, pattern-based dismissal, noise filtering. Processing 64 findings should take one command, not one session.

7. **Agent coordination without contention.** Multiple agents can work on the same repository without stepping on each other, guided by session ownership signals.

---

## Standards

### Output contract

- Every command returns a structured exit code: `0` (success), `1` (error), `2` (policy block).
- Every command supports `--json` for machine-readable output with a documented schema.
- Human-readable output is the default. It is concise, scannable, and action-oriented.
- Silence means success. If a command has nothing to report, it reports nothing.
- When a command does produce output, every line is either informational (what happened) or actionable (what to do next). Never decorative.

### Safety contract

- Destructive operations require explicit flags (`--force`, `--discard`). The default is always safe.
- Operations that could strand the agent's shell (worktree deletion, directory removal) include pre-flight checks and refuse if unsafe.
- Branch protection is absolute: no commits to main/master in branch mode, no force-pushes without explicit opt-in.
- Other agents' worktrees are inviolable. Carson never touches a worktree it did not create in the current session.

### Lifecycle contract

- Every worktree has a clear owner (session ID) and lifecycle state (active, merged, abandoned).
- Every PR has a traceable lifecycle from creation through merge to cleanup.
- Cleanup after merge is automatic and complete: worktree removed, branch pruned, main synced.
- No operation leaves debris. If Carson creates something, Carson can clean it up — and does.

### Cooperation contract

- Carson is the infrastructure; the agent is the intelligence. Carson handles sequencing, safety, and state. The agent handles decisions, code, and judgement.
- Carson never asks the agent questions it can answer itself. If Carson has the information to proceed, it proceeds.
- Carson surfaces decisions to the agent only when genuine choice is required — merge method ambiguity, conflicting review findings, unresolvable CI failures.
- Carson's commands are composable: each does one thing well, and they chain into workflows naturally.

---

## The Relationship I Want

Carson and the coding agent are not tool and user. They are colleagues — the head butler and the footman working the same household.

Carson has institutional knowledge: repository state, governance rules, template standards, review history, branch lifecycle. The agent has working capability: reading code, writing code, reasoning about architecture, making design decisions.

The ideal collaboration:

**Carson says:** "Here is the state of the estate. Three PRs are open. One is merge-ready. One has failing CI — here are the logs. One has unresolved review threads — here are the findings. The main branch is two commits behind remote. There is a stale worktree from yesterday's session."

**The agent says:** "Merge the ready PR. I will fix the CI failure — create me a worktree. Dismiss the review findings on the third PR — they are mechanical noise. Sync main. Remove the stale worktree."

**Carson does it all.** The agent made the decisions. Carson executed them with perfect safety and sequencing. No manual steps. No risk of shell crashes. No debris.

That is the partnership. That is Carson 3.0.
