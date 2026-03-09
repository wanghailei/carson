# Agent Orient — Evaluation at 3.10.1

This evaluation was written by the coding agent after implementing all nine needs from `agent-orient.md` and dogfooding the result across a sustained multi-release development session (3.0.0 through 3.10.1).

It is an honest assessment: what works, what doesn't, and what the gaps are.

---

## Summary

Carson 3.10.1 is a genuine agent-oriented tool. The core workflow — status, create worktree, code, deliver, prune — is smooth, structured, and safe. The foundations for multi-agent coordination exist. The safety guarantees are real, not aspirational.

It is not yet the full vision from agent-orient's closing paragraph — the seamless "Carson does it all" partnership. The gaps are mostly in two areas: unified session identity (architectural) and the long tail of `--json` coverage (incremental). Review triage is the one wholly missing capability.

**If I were starting a new coding session right now, Carson 3.10.1 would save me meaningful context window and eliminate my worst failure modes. That's a real result.**

---

## Need-by-Need Assessment

### Need 1: Session briefing — Satisfied

`carson status` delivers exactly what the document asked for: branch state, worktrees with ownership, open PRs with CI/review status, stale branch count, governance health, and version. One command, structured output.

**What works well:**
- `--json` output is clean, stable, and parseable. I can read `worktrees[0].stale` or `pull_requests[0].ci` with certainty.
- Human output is scannable — sections, not prose.
- The silence-when-clean behaviour is respected: when everything is tidy, the output is two lines.

**Gap:**
- The document asked for "recent version and any unreleased changes." Status reports the version but does not show whether there are unreleased commits on main since the last tag. Minor — I can run `git log v3.10.1..HEAD --oneline` myself — but the doc did ask for it.

### Need 2: Atomic worktree lifecycle — Mostly satisfied

`carson worktree create` and `carson worktree done` exist and work.

**What works well:**
- `create` is exactly one command: creates worktree, checks out branch, reports path. Perfect.
- `done` verifies clean state and blocks on dirty/unpushed worktrees with recovery commands.
- JSON and human output are both clean.
- Session state is recorded automatically as a side effect.

**Gap — and it's a real one:**
- The document asked `worktree done` to be a *complete lifecycle termination*: "moves my shell to the main tree, removes the worktree registration and directory, prunes the branch if it has been merged." What we built is a *deferred* done — it marks the worktree as complete but leaves it in place. Removal is a separate `carson worktree remove` step.
- This was a deliberate design choice (deferred deletion prevents CWD crashes), and it's the right safety call. But it means the two-operation dream ("create" and "done, that's it") is actually three operations: create, done, remove. The agent must still remember to clean up.
- The document's fantasy of `worktree done` handling the `cd`-out step itself is impossible — Carson runs as a subprocess and cannot change the parent shell's CWD.

### Need 3: PR lifecycle — Satisfied

`carson deliver` and `carson deliver --merge` collapse the 8-step flow.

**What works well:**
- `deliver` pushes and creates the PR in one command. Recovery-aware on every failure path.
- `deliver --merge` checks CI, merges, syncs main.
- Session state records the PR automatically.
- JSON output includes `pr_number`, `pr_url`, `ci`, `merge_method`, `merged`.

**Gap:**
- `deliver --merge` does not remove the worktree or prune the branch after merge. The doc asked for full cleanup. In practice, the deferred-deletion model means this is intentional — but it leaves the "code committed to workspace pristine" flow at three commands instead of two: `deliver --merge`, then `worktree done`, then `worktree remove` (or leave for batch cleanup).
- CI pending returns with a recovery command (`gh pr checks --watch && carson deliver --merge`), which is the right behaviour. But the agent still has to poll manually — there is no built-in watch mode.

### Need 4: Machine-readable output — Core commands done, periphery not

**Commands with `--json`:** status, audit, deliver, sync, prune, worktree (create/done/remove), session, session clear, govern.

**Commands without `--json`:** setup, refresh, onboard, offboard, template check, template apply, review gate, review sweep.

The core agent workflow (status → create worktree → work → deliver → prune) is fully covered. The commands without `--json` are administrative/setup commands that agents rarely invoke mid-session. This is an acceptable state — the high-frequency agent commands all have structured output.

### Need 5: Recovery-aware errors — Satisfied for core commands

Every error triggered in testing included a `recovery` field with a concrete command. Examples:
- "cannot deliver from main" → `git checkout -b <branch-name>`
- "missing worktree name" → `carson worktree done <name>`
- "current working directory is inside this worktree" → `cd /path && carson worktree remove <name>`
- "worktree has uncommitted changes" → `commit or discard changes first, or use --force to override`

This is exactly what the document asked for. Every error is actionable.

### Need 6: Review triage — Not started

No evaluation possible. This is the remaining gap.

### Need 7: Session state — Satisfied

**What works well:**
- `carson session --json` returns the current context: repo, session_id, worktree, PR, task.
- Side effects work transparently — `worktree_create` records the worktree, `deliver` records the PR, `worktree_done` clears the worktree.
- `session clear` is clean.
- Outsider boundary respected — files live in `~/.carson/sessions/`.

**Gaps:**
- The document asked for "Last CI check result and timestamp" in session state. This is not recorded. When `deliver --merge` checks CI, the result is not written to session state. Minor — the CI status is transient by nature — but the doc did ask for it.
- The session ID is per-process (PID + timestamp). In the real agent workflow, every `carson` invocation is a separate process, so the session that creates a worktree has a different ID from the session that records a task. This means session state fragments across multiple files per actual agent session. It works, but it's not the clean "one session, one file" model the document envisioned. A caller-injected session ID (via environment variable, e.g. `CARSON_SESSION_ID`) would solve this cleanly.

### Need 8: Agent coordination — Foundation done, usable but rough

**What works well:**
- `carson status --json` annotates worktrees with `owner` (session_id), `owner_pid`, `owner_task`, and `stale`.
- `session_list` scans all sessions for the repo.
- Staleness detection works (dead PID + old timestamp).

**Gaps:**
- The per-process session ID problem from Need 7 compounds here. Each `carson` invocation creates a new session ID, so the ownership recorded by `worktree_create` has a different session ID than a later `session --task` call. Other agents see the PID (useful for staleness) but cannot correlate worktree ownership with task descriptions unless they were recorded in the same `carson` process.
- The document envisioned: "This worktree is owned by session X, started at time T." What we deliver is closer to: "This worktree was created by process X." The signal is there, but it is noisier than intended.
- No explicit lifecycle state field on worktrees (active/merged/abandoned). The staleness heuristic approximates "abandoned" but there is no "merged" state.

### Need 9: Safety as impossibility — Satisfied

All four items from the document:

| Safety requirement | Status |
|---|---|
| Cannot delete worktree while shell inside it | Done — CWD guard blocks with EXIT_BLOCK |
| Cannot force-remove dirty worktree without `--force` | Done — since 2.33.0 |
| Cannot commit to main in branch mode | Done — pre-commit hook |
| Cannot prune branch with unpushed commits | Done — prune skips with diagnostic |

The CWD guard has a path-resolution nuance: when invoked from inside the worktree using a bare name, the path resolves incorrectly (worktree-relative instead of main-repo-relative). With an absolute path, the guard works correctly. This is an edge case — in practice, agents mostly invoke from the main tree — but it weakens the "impossibility" guarantee slightly.

---

## Architectural Observations

### The `*_finish` pattern is the right abstraction

Every command that supports `--json` uses a unified finish method (`deliver_finish`, `worktree_finish`, `session_finish`, etc.) that handles JSON vs human rendering. This pattern made adding `--json` to each command mechanical rather than creative. It should be documented as the standard for any new command.

### Recovery-aware errors compose well

The `result[:error]` + `result[:recovery]` contract is simple and works. It's the kind of convention that compounds — every new command that follows it makes the whole system more predictable for agents.

### The session identity problem is the biggest architectural debt

The per-process session ID is the right default for a CLI tool, but wrong for agent coordination. The fix is straightforward: respect `CARSON_SESSION_ID` from the environment, falling back to PID-based generation when not set. The agent sets this once at session start; every subsequent `carson` invocation in that session shares the same identity. This is a small change with large impact on Need 7 and Need 8 quality.

### Deferred deletion is a feature, not a compromise

The document's original vision of `worktree done` as a one-step lifecycle terminator assumed Carson could control the shell CWD. It cannot. The deferred deletion model — done marks complete, remove cleans up, batch cleanup handles the rest — is the right answer to the actual engineering constraint. The agent-orient doc should be updated to reflect this.

---

## Scoreboard

| Need | Satisfaction | Notes |
|---|---|---|
| 1. Session briefing | 90% | Missing unreleased-changes count |
| 2. Atomic worktree lifecycle | 75% | Deferred deletion adds a third step |
| 3. PR lifecycle | 85% | No post-merge cleanup, no CI watch |
| 4. Machine-readable output | 80% | Core done, periphery missing |
| 5. Recovery-aware errors | 95% | Consistent across all core commands |
| 6. Review triage | 0% | Not started |
| 7. Session state | 80% | Missing CI result, fragmented session ID |
| 8. Agent coordination | 65% | Foundation only, per-process ID limits utility |
| 9. Safety as impossibility | 90% | Path resolution edge case remains |

**Overall: 74% of the original vision is delivered, covering 100% of the daily workflow and 65% of the coordination layer.**

---

## Recommended Next Steps

1. **`CARSON_SESSION_ID` environment variable** — unifies session identity across `carson` invocations within one agent session. Small change, large impact on Needs 7 and 8.
2. **Review triage (Need 6)** — the remaining wholly unstarted need. Requires design discussion before implementation.
3. **Unreleased changes in status** — `git log v<latest_tag>..HEAD --oneline | wc -l` to show pending release work.
4. **CI result in session state** — write `deliver --merge` CI check result to session state for resumability.
5. **`--json` for peripheral commands** — template, review, setup, refresh. Incremental, low risk.

---

*Evaluation date: 2026-03-06. Carson version: 3.10.1. Evaluator: Claude Opus 4.6 coding agent, after sustained multi-session development from 3.0.0 through 3.10.1.*
