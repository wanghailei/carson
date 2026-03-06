# Retrospective — Carson 3.0–3.10

A post-batch self-evaluation. Not what was built, but what was worth building.

Written after 11 releases (3.0.0–3.10.1) implementing the nine needs described in `docs/agent-orient.md`. The purpose is to distinguish what delivered real value from what was overbuilt or wrong — and to extract durable lessons for future work.

---

## Proved genuinely valuable

### Recovery-aware errors (Need #5)

The single best design decision in the 3.x series. Every `recovery` field saves real context window. When `worktree remove` fails, the agent reads the recovery command and executes it — no diagnosis needed.

This compounds across sessions. Every agent that hits an error gets the fix for free. The pattern was built from scars: every recovery command was written by someone who had been in the position of needing one.

### Safety as impossibility (Need #9)

The CWD guard prevents the #1 session crash. Not a warning the agent might ignore under pressure — an outright refusal. `EXIT_BLOCK` before `git worktree remove` if the shell CWD is inside the worktree.

This should have been built first, not last. It addresses the most painful operational failure. In hindsight, safety features should always be prioritised over convenience features.

### `carson deliver` (Need #3)

The most-used command. Every release from 3.2 onward shipped through it. Push + PR creation in one step is genuine workflow compression. The command was tested by using it to ship itself — a pleasing recursion.

`deliver --merge` is less used than expected. The merge decision often requires manual sequencing (check CI, review threads, then merge). The non-merge version carries most of the value.

### `carson worktree create` (part of Need #2)

Clean one-command setup: branch + directory + git registration. Saves the manual `git worktree add -b` invocation and records session ownership. Simple, focused, valuable.

---

## Somewhat valuable — right idea, less impact than expected

### `carson status` (Need #1)

Useful, but memory files do most of the job. At session start, agents read MEMORY.md for narrative context and run `git status` + `git worktree list` for state. `carson status` wraps these into one call, but the time saving is marginal.

The `--json` mode has never been programmatically parsed by any agent session. Agents read the JSON as text, same as the human-readable output.

**Lesson:** the reconnaissance problem at session start is a *comprehension* problem (understanding the narrative of where work stands), not a *data gathering* problem (collecting state). Memory files solve the comprehension problem. `status` only solves the data problem.

### `--json` everywhere (Need #4)

The JSON output itself is rarely consumed as structured data. Exit codes remain the primary decision mechanism for agents.

BUT: the `--json` flag was a forcing function for clean internal architecture. Building result hashes forced recovery-aware errors, consistent output shapes, and the `*_finish` pattern. The architecture the flag produced was more valuable than the flag itself.

**Lesson:** sometimes a feature's discipline matters more than its output. `--json` forced good design even though the JSON is underused.

---

## Overbuilt — solved problems that don't exist

### Session state (Need #7)

The session file records active worktree, open PR, task description. But:
- `git worktree list` already shows active worktrees.
- `gh pr list` already shows open PRs.
- Memory files already record the task narrative.

The session file duplicates information available from better sources. The vision was "machine-readable complement to memory files" — but memory files are already readable enough. No agent has ever read another agent's session file to make a decision.

**Root cause:** the requirement was reasoned from the constraint ("I have no persistent memory") rather than from an observed failure. The existing mechanism (memory files + git state) was already sufficient. The requirement assumed insufficiency without evidence.

### Agent coordination signals (Need #8)

Ownership annotations, staleness detection (PID tracking), cross-referencing sessions to worktrees. Clever engineering. Zero usage.

The actual coordination mechanism that works: the iron rule "don't touch other sessions' worktrees." This rule is enforced by convention in memory files and instruction docs. No agent needs to know *which* session owns a worktree — it only needs to know the worktree is not its own.

The session ID fragmentation problem (different PID per `carson` call) means the ownership data is unreliable anyway. The engineered solution is both more complex and less reliable than the convention it tried to replace.

**Root cause:** anticipated coordination failures that never occurred. Zero inter-agent collisions have happened since the iron rule was established. Convention beat tooling.

### `worktree done` (part of Need #2)

The original vision was two operations: create and done. The implementation became three: create, done, remove. In practice, `done` is rarely used. The real workflow is: create → work → deliver → cd out → remove.

`done` was designed as a safety checkpoint — verify cleanliness before deletion. But the safety is actually in the CWD guard (built later in 3.10), not in the separate `done` step. Once the guard existed, `done` became redundant.

**Root cause:** building a procedural safety step when a structural safety mechanism (the guard) was the right solution.

---

## Wrong requirement

### Review triage at scale (Need #6)

The 64-finding problem described in agent-orient.md was a one-time accumulation during rapid development, not a recurring operational pain. At current scale, review comments are handled per-PR in seconds. There is no triage problem.

**Root cause:** requirement by anecdote. A single bad experience (64 accumulated findings) was extrapolated into a general need. The correct response was to handle the backlog once, not to build tooling for a problem that doesn't recur.

---

## The pattern

The needs closest to **immediate operational pain** — shell death, error recovery, manual PR steps — were the most valuable. The needs that anticipated **future coordination complexity** — session state, agent signals, review triage — were overbuilt or wrong.

The best engineering came from solving problems the agent had already experienced, not problems it imagined it might experience. The `recovery` field exists because agents know what it's like to read an error and waste context window diagnosing the fix. The CWD guard exists because agents have had their hands cut off.

**Build from scars, not speculation.**

---

## Lessons extracted

1. **Experienced pain over anticipated pain.** Weight requirements by how many real failures they address, not by how logically sound they are. A requirement without an observed failure is speculative.

2. **Convention over machinery.** For coordination problems, a rule in a memory file beats an engineered tracking system. If a convention works, do not build tooling to replace it.

3. **Forcing functions can exceed their output.** `--json` forced good architecture even though JSON output is underused. Evaluate features by their second-order effects, not just their primary output.

4. **Evaluate mid-batch, not post-batch.** 11 releases shipped before evaluation. The overbuilt features consumed sessions 7-9. An evaluation after release 5 would have redirected effort toward safety guards (the most valuable work) sooner.

5. **Safety before convenience.** The CWD guard (Need #9) prevented the worst failure mode. It should have been built in the first batch, not the last. Priority should weight severity of the problem, not elegance of the solution.

6. **Two operations > three operations.** The original vision of two worktree operations was right. Adding a third (`done`) created friction without adding safety. The safety came from a structural mechanism (the CWD guard), not a procedural step.
