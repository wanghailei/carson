# Agent Orient — Deferred Worktree Cleanup Model

Addendum to `agent-orient.md`, recorded during Carson 3.0.0 development.

This captures a design insight from the user that refines the worktree lifecycle section of the original agent-orient document.

---

## The insight

Worktrees do not need immediate deletion after use. The original agent-orient document proposed `carson worktree done` as an immediate teardown command. The user observed: worktrees are cheap, and the real danger is deleting one while an agent's shell CWD is inside it — which kills the session.

Deferred cleanup eliminates that risk entirely.

## The rule

**A work, a worktree.** One task per worktree, never reused, cleaned up in batch.

## Revised lifecycle

Three operations instead of two:

**Create:** `carson worktree create <name>` — creates the worktree, checks out a new branch, reports the path.

**Done:** `carson worktree done` — marks the worktree as completed. Ensures all changes are committed and pushed. Records that work is finished but does **not** delete the worktree. The directory stays. The branch stays. Deletion is deferred.

**Housekeep:** `carson housekeep` (or `carson prune`) — cleans up all completed worktrees in one pass, at a time when no agents are active. This is the safe moment for deletion.

## Why this is better

1. **Active sessions never trigger deletion.** The worktree stays until batch cleanup.
2. **Batch cleanup runs when no agents are working.** No shell CWD inside a directory that is about to disappear.
3. **Worktrees serve as historical record.** `carson status` can show what work was done, on which branches, and whether each is active or completed.
4. **Simpler mental model.** "Create, use, mark done" is easier than "create, use, carefully tear down in the right order or crash."

## Impact on other sections

- `carson deliver --merge` should mark the worktree as done and sync main, but leave the directory for batch housekeep.
- Goal #1 ("Zero session crashes from worktree lifecycle") is achieved through deferred cleanup rather than safe-ordering of immediate teardown.
- The lifecycle contract changes from "worktree removed, branch pruned, main synced" to "worktree marked done, cleaned up in batch via housekeep."
