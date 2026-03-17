# Carson Feature Spec

> **Purpose:** How each Carson feature works — mental model, decisions, interactions, traps.
> **Audience:** Coding agents working on Carson.

---

## Deliver

Ship committed work from a worktree branch to main via PR and merge.

### Mental model

Deliver owns the full path from local commits to integrated main: push, PR create/refresh, bounded settle loop, freshness gate, merge, post-merge sync+prune. One invocation should be enough for the normal case.

### Freshness gate

Freshness enforcement has two layers:

**Pre-push (local, before PR exists):** Before any push, deliver verifies the branch is current against fetched remote main using `git merge-base --is-ancestor`. Three states: fresh (proceed), behind (block), unknown (block). This is the user-facing gate — the user can act on it before a PR exists.

**Post-PR (GitHub authority):** After a PR exists, Carson delegates merge eligibility to GitHub's `mergeStateStatus`. If GitHub reports `BEHIND`, the delivery is held with cause "freshness". If `CLEAN`, Carson proceeds regardless of local ancestor status. This eliminates false blocks in repos where GitHub's "require up-to-date" setting is permissive.

### Settle loop

After PR creation, deliver enters a bounded settle loop instead of exiting immediately.

- **Budget:** `govern.check_wait` seconds total.
- **Poll interval:** `review.poll_seconds`.
- **End conditions:** integrated, hard-blocked, or budget expired.

Merge-attempt cap: 3 per invocation. Retries happen on the next poll interval, not in a tight loop.

Transient API failures within the budget are retried on next poll — they don't count as merge attempts and don't surface as false hard blocks.

### Hard blocks

Deliver exits immediately for: CI failing, review changes requested, review gate error, GitHub mergeStateStatus BEHIND, draft PR, PR closed, merge conflict, repository policy block.

### Deferred exit

When the budget expires without integration and no hard blocker exists, deliver exits as deferred. The PR remains open; Carson has stopped watching.

### Output contract

Three outcomes: `integrated`, `deferred`, `blocked`. Each states what happened and what command to run next. Deferred and blocked exits show: `carson status` → `carson deliver` → `carson govern --loop 300`.

### JSON fields

`watch_window_seconds`, `waited_seconds`, `merge_attempted`, `freshness.status`, `freshness.reason`. Pre-push: freshness comes from local git. Post-PR: freshness comes from GitHub's merge state. Deferred/blocked exits add `handoff.reason`, `handoff.expectation`, `handoff.next_steps`.

---

## Authority

Which side decides branch origin and landing in governed repositories.

### Core rule

For every governed repository: exactly one side is authority, the other is backup. Authority decides both where agents branch from and where completed work lands. The start side and the landing side must match.

Hybrid authority (one side for branching, other for landing) is forbidden.

### Modes

**Remote authority** (active, current default):
- Agents branch from a proved remote baseline.
- Completed work lands through remote main via PR flow.
- Local main is backup only.
- `sync` refreshes backup state — it does not redefine authority.

**Local authority** (deferred, not yet supported):
- Agents branch from local main.
- Work lands into local main.
- Remote receives backup pushes only.
- PR-based review/govern flows are not the governed landing path.

### Invariants

1. A governed repository has one authority at a time.
2. `worktree create` uses the authority side as branch origin.
3. `deliver` lands through the authority side.
4. Backup failure does not redefine authority.
5. Docs, output, JSON, and runtime all describe the same authority model.

### Surface language

- "authority" = branch origin + landing truth.
- "backup" = mirror/preservation only.
- "sync" = refresh backup state, not redefine authority.

Never describe a workflow that implies remote is authority for landing but local is authority for branching.

---

## Govern

Autonomous portfolio-level delivery oversight: triage, dispatch, merge.

### Mental model

`carson govern` runs a triage-dispatch-verify cycle across all governed repositories. It classifies each open PR, dispatches coding agents to fix issues, and merges PRs that pass all gates. With `--loop SECONDS`, it runs continuously.

### PR classification

| Class | Condition | Action |
|---|---|---|
| `ready` | CI green, review clear, audit clean, fresh | Merge + sync + prune |
| `ci_failing` | CI checks failed | Gather CI logs, dispatch agent |
| `review_blocked` | Unresolved review threads | Gather review evidence, dispatch agent |
| `pending` | Checks still running (within `check_wait`) | Skip |
| `needs_attention` | Cannot be resolved autonomously | Escalate |

### Agent dispatch

Before dispatching, govern gathers evidence specific to the objective:
- `fix_ci`: fetches failed CI run logs via `gh run view --log-failed` (tail up to 8,000 chars).
- `address_review`: fetches unresolved threads via GraphQL (each body up to 2,000 chars).
- Prior failed attempt summaries are included to prevent repeated approaches.

Agent provider: configured via `govern.agent.provider` — `auto` (tries codex then claude), `codex`, or `claude`.

### Freshness rule

Govern delegates merge eligibility to GitHub's merge state. A final GitHub recheck runs immediately before every merge attempt. If GitHub reports `BEHIND`, the delivery is gated with cause "freshness" and surfaces as "refresh required". If `CLEAN`, govern integrates — even when the branch is locally behind main. Govern does not dispatch an agent to "fix" freshness blocks.

### Isolation

Govern is deliberately isolated from synchronous local commands. It is asynchronous, network-dependent, and advisory. Local commands (audit, review gate, sync) are fast, deterministic, and offline-capable.

---

## Recover

Narrow recovery path when a governance-owned baseline check is already red on the default branch.

### Problem

When a governance-owned CI check is red on main, the repair PR is blocked by the very check it tries to fix. Without a legitimate recovery path, operators learn to bypass Carson, eroding guardrail legitimacy.

### Command: `carson recover --check NAME`

Recovery is a distinct command with higher activation energy than ordinary delivery. It is not a flag on deliver.

### Requirements

1. **Live proof:** recovery must verify at merge time that the named check is red on the current default-branch SHA.
2. **Narrow bypass:** only the single named governance-owned check is bypassed. All other gates (CI, review, branch protection) must still pass.
3. **Audit trail:** recovery writes a machine-readable ledger event: repository, PR, branch, check name, default-branch SHA, PR SHA, actor, timestamp.
4. **Fail closed:** recovery is refused when proof is missing, stale, or names a check outside Carson's governance surface.

### Refusal reasons

- Named check is not red on default branch.
- Named check is not Carson-governed.
- Another required check is still failing.
- Review gate is still blocked.
- Proof was collected against an out-of-date default-branch SHA.

---

## Worktree

Isolation container for branch work. The worktree is not the delivery unit — the branch is.

### Lifecycle

`carson worktree create <name>`: syncs main from remote first (proving remote authority baseline), then creates the worktree with a new branch.

Worktrees are not deleted immediately after use. After the branch is merged, the worktree is marked as done. Deletion is deferred to batch cleanup (`carson housekeep`, `carson prune`).

### Safety rules

- Never force-remove (`--force` means modified/untracked files — that's active work).
- Never delete while CWD is inside the worktree.
- Never delete a worktree from another session.
- CWD safety: `cwd_inside_worktree?` + `worktree_held_by_other_process?` (lsof) + `check_unpushed_commits`.

### Authority gap (known)

Remote authority should fail closed when remote proof is unavailable during worktree create. Currently a gap.

---

## Audit

Governance compliance checks: scope integrity, outsider boundary, working tree state.

### What it checks

- **Working tree** — staged/unstaged status.
- **Main sync status** — whether local main matches remote. Ahead means drift.
- **Scope integrity** — commits stay within a single business intent and scope group.
- **Outsider boundary** — no Carson artefacts in the host repo.
- **Template drift** — managed `.github/*` files match Carson's templates.
- **Baseline CI** — `default_branch_ci_baseline_report` queries GitHub for the default branch head SHA and its check-runs.

### Exit codes

- `0` (ok) — clean.
- `1` (error) — something unexpected.
- `2` (block) — policy violation, must fix before proceeding.

`status: attention` is advisory, not blocking.

### Audit freshness

Deferred. The authoritative freshness check belongs to deliver. A local-only advisory could be misread as authoritative.

---

## Review

PR review hygiene: gate and sweep.

### Review gate (`carson review gate`)

Checks for unresolved review threads, outstanding CHANGES_REQUESTED reviews, and risk-keyword comments.

Flow:
1. Quick-check — if all resolved, skip warmup.
2. Warmup — wait (default 10s) for bot posts.
3. Poll loop — snapshot, compare, converge. Bot-aware: skips comments from configured bot usernames.
4. Verdict — OK (merge-ready) or BLOCK (with reasons and URLs).

Convergence rule: capture unresolved-thread count + latest activity marker, poll again, continue until two consecutive snapshots are identical.

### Review sweep (`carson review sweep`)

Scans recent PRs for late actionable review activity. Used for maintenance, not as a delivery step.

### Bot filtering

`review.bot_usernames` in config. Use GraphQL login format (no `[bot]` suffix).

---

## Housekeep

Safe cleanup of merged branches and stale worktrees.

### What it cleans

- Merged local branches (evidence: PR merged on GitHub).
- Stale worktrees (evidence: associated branch merged, no unpushed commits, no uncommitted changes).

### Safety

Before removing any worktree: check `git log` for unpushed commits, `git status` for uncommitted changes, verify the associated PR is merged. If any check fails, the worktree is presumed active.

Never deletes main/master refs. Never force-removes.

### Known edge case

External directory deletion (outside Carson) can cause the last local branch ref to be lost silently. Gap — not yet protected.

---

## Merge-readiness model

Not a feature — the shared gate that deliver and govern both use.

A PR is merge-ready when three independent conditions pass:

1. **`carson audit` exit 0** — governance clean.
2. **`carson review gate` exit 0** — all actionable review comments resolved.
3. **All GitHub required status checks green** — repository's own CI.

Carson owns the first two. The third is repository-governed. All three must pass.
