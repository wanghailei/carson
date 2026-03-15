# Review — investigation into PRs #299, #311, and #312

Date: 2026-03-15  
Repository: `carson`  
Scope: how the incident happened, current codebase status after `#311` and `#312`, how to recover the value from `#299`, lessons, and Carson evolution needs.

## Executive summary

This was **not** Carson auto-closing `#299`.

`#299` was **manually closed by WHL** after `#311` landed and changed the ledger foundation, and after the one safe slice from `#299` had been extracted into `#312` and merged separately.

The root cause was a combination of:

1. **Overlapping concurrent PR scope** on shared hot files (`ledger`, `govern`, `housekeep`, tests, and docs).
2. **A foundational rewrite landing underneath an umbrella branch**: `#311` replaced the SQLite ledger with a JSON ledger, which invalidated part of `#299`'s implementation approach.
3. **Govern design defects that obscure and worsen merge conflicts**:
   - govern summary text can report a failed merge as "integrated" (`lib/carson/runtime/govern.rb:431-446`),
   - govern can endlessly retry a conflicting PR and block ready PRs behind it (`lib/carson/runtime/govern.rb:84-85`, `189-212`; `lib/carson/runtime/deliver.rb:291-299`).

The current codebase on `main` is **healthy enough to run and ship from**: local tree clean, CI green for both merged PRs, full local test suite green, and smoke tests green. But it is **not yet healthy enough to trust unattended govern operation around merge conflicts**.

The right recovery is **not** to reopen `#299`. The right recovery is to **re-implement its still-valid ideas as a sequence of focused PRs on current `main`**, starting with govern hardening.

---

## 1. How this happened

### Timeline

All times below are on **2026-03-15** in **UTC+08:00**.

| Time | Event | Evidence |
|---|---|---|
| 13:58 | PR `#299` opened: **Housekeep mechanism improvements** | GitHub PR metadata |
| 14:45 | Commit `2945733` added to `#299`: **fix: housekeep from worktree resolves to canonical repo root** | local git history |
| 15:00 | PR `#311` opened: **Json ledger** | GitHub PR metadata |
| 15:16 | PR `#312` opened: **Fix housekeep canonical root** | GitHub PR metadata |
| 16:35 | PR `#311` merged by `wanghailei` as `c858292` | local git history + GitHub PR metadata |
| 16:37:53 | Comment on `#299`: structural conflicts after main evolved significantly | GitHub PR comment |
| 16:37:54 | PR `#299` closed by `wanghailei` | GitHub PR metadata |
| 16:38 | PR `#312` merged by `wanghailei` as `13707f4` | local git history + GitHub PR metadata |

### Direct cause

`#299` overlapped with both `#311` and `#312`.

#### `#299` vs `#311`

Overlapping files included:

- `API.md`
- `lib/carson/ledger.rb`
- `lib/carson/runtime/govern.rb`
- `test/ledger_test.rb`
- `test/runtime_govern_test.rb`
- plus additional docs and support files

#### `#299` vs `#312`

Overlapping files included:

- `lib/carson/runtime/housekeep.rb`
- `test/runtime_housekeep_test.rb`

This is visible from the surviving `housekeep/improvements` branch diff versus `main`, and from merge-tree conflict output against current `main`.

### Structural cause

`#299` was a **broad umbrella branch**. Its unique commits were:

- `bb143db` — govern should reap dead worktrees before pruning
- `b2e3060` — decouple cleanup from sync success
- `f844b25` — force-remove dirty worktrees when absorption or merge is proven
- `c801570` — ledger-aware reap for integrated delivery worktrees
- `d44232e` — `housekeep --loop`
- `cddee63` — review-fix follow-up
- `2945733` — canonical-root housekeep fix

That branch touched 36 files and mixed:

- foundation changes,
- follow-on cleanup logic,
- CLI surface,
- documentation,
- tests.

Then `#311` replaced the ledger foundation. Once that happened, `#299` was no longer merely stale. It became **structurally incompatible** with `main`.

### Who or what was the root cause?

#### Human actors

- `#311` merge actor: `wanghailei`
- `#299` close actor: `wanghailei`
- `#312` merge actor: `wanghailei`

#### Tooling root cause

Carson did **not** close `#299`.

Current merge and govern paths show no govern-side PR close behaviour that explains `#299`:

- merge path: `lib/carson/runtime/deliver.rb:521-539`
- govern post-merge cleanup: `lib/carson/runtime/govern.rb:286-289`
- explicit close path exists in abandon flow, not govern: `lib/carson/runtime/abandon.rb`

So the closure was manual. The tooling failure was elsewhere: Carson makes conflict situations harder to reason about because it does not model them clearly.

### Carson defects exposed by this incident

#### 1. Govern summary can lie

`format_govern_action` in `lib/carson/runtime/govern.rb:438-446` maps the attempted action, not the resulting state.

For example, `format_govern_action(status: "gated", action: "integrate")` returns **`"integrated"`**.

That means a failed merge can still be displayed as if it succeeded.

#### 2. Govern can loop forever on a conflicting PR

Current causal chain:

1. govern selects the **first ready delivery**: `lib/carson/runtime/govern.rb:84-85`
2. merge failure sets it back to **`gated`**: `lib/carson/runtime/govern.rb:206-212`
3. reassessment promotes it back to **`queued`** when review and CI are clean: `lib/carson/runtime/deliver.rb:291-299`
4. govern chooses it again on the next cycle
5. later ready deliveries stay blocked behind it because only the first ready item is selected

This is head-of-line blocking caused by a missing conflict state.

---

## 2. Current status and quality of the codebase after `#311` and `#312`

## Current status

Current `main`:

- `13707f4` — **fix: housekeep from worktree resolves to canonical repo root (`#312`)**
- parent `c858292` — **replace SQLite ledger with JSON file store (`#311`)**

Local tree state during investigation:

- clean working tree
- `main` aligned with local `github/main`

### Verification run during this investigation

Commands run locally:

```bash
ruby -c exe/carson
ruby -c lib/carson.rb
ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |path| require File.expand_path(path) }'
bash script/ci_smoke.sh
```

Observed results:

- Ruby syntax checks: **OK**
- full test suite: **405 runs, 1298 assertions, 0 failures, 0 errors, 0 skips**
- smoke tests: **passed**

### GitHub CI status

Recent push runs on `main`:

- `#311` push run: **success**
- `#312` push run: **success**

PR check surfaces for both merged PRs were green.

## Quality assessment

### `#311` — JSON ledger replacement

Strengths:

- Simplifies the storage model by removing SQLite dependency from the gem itself.
- The JSON ledger implementation is coherent and easier to reason about than the old database layer.
- The test suite covers core state semantics well enough for confidence in the normal path.

Important residual concerns:

1. **No migration path from old SQLite state**  
   The PR explicitly chose no migration. That is a release-risk issue for existing users, even though it is not a current local failure.

2. **Concurrency is designed, but not stress-proved**  
   File lock + atomic rename exist in `lib/carson/ledger.rb`, but there is still no direct concurrency regression proof.

3. **CI workflow still installs `sqlite3`**  
   `.github/workflows/ci.yml:29-30` and `64-65` still run `gem install sqlite3 --no-document` even though the runtime no longer depends on it.

### `#312` — canonical-root housekeep fix

Strengths:

- Narrow and correct.
- Good regression coverage.
- Clear causal fix: use `main_worktree_root` in housekeep just as deliver, status, and govern already do.

This PR is high quality.

## Defects still present on `main`

### A. Govern output bug

- File: `lib/carson/runtime/govern.rb:431-446`
- Problem: human summary text can claim integration even when merge failed
- Severity: high for operator trust

### B. Govern merge-loop / queue-blocking bug

- Files: `lib/carson/runtime/govern.rb:84-85`, `189-212`; `lib/carson/runtime/deliver.rb:291-299`
- Problem: one conflicting PR can be retried forever and block later ready PRs
- Severity: high for unattended govern

### C. Govern post-merge cleanup is incomplete

- File: `lib/carson/runtime/govern.rb:286-289`
- Problem: `housekeep_repo!` only does `sync!` and `prune!`; it does not call `reap_dead_worktrees!`
- Severity: medium-high because this leaves behind worktree debris

### D. Housekeep still couples cleanup to sync success

- File: `lib/carson/runtime/housekeep.rb:146-152`
- Problem: cleanup paths are skipped if sync fails
- Severity: medium

### E. Proven-safe force removal and ledger-aware integrated-delivery reap are still missing

The ideas existed in `#299` but are not on current `main`.

## Overall judgement on current codebase

**Status:** operationally healthy.  
**Quality:** solid enough for normal day-to-day work.  
**Limit:** not yet reliable enough for conflict-heavy unattended govern operation.

---

## 3. What to do about `#299`

## Do not reopen it

`#299` is the wrong vehicle now.

It should be treated as a **design and evidence branch**, not as something to merge.

The correct move is to re-implement the surviving value from `#299` as focused PRs on top of current `main`.

## Commit-by-commit disposition

### Already salvaged

- `2945733` — canonical-root housekeep fix  
  Already merged separately as `#312`.

### Still valuable and should be re-implemented

- `bb143db` — govern should reap dead worktrees before pruning
- `b2e3060` — cleanup should not be blocked by sync failure
- `f844b25` — force-remove dirty worktrees when safety proof exists
- `c801570` — ledger-aware reap for integrated delivery worktrees

### Lower priority / optional

- `d44232e` — `housekeep --loop`
- `cddee63` — fold the review-fix details into the relevant reimplementation PRs

## Recommended reimplementation order

### PR 1 — govern hardening

This should land first because it addresses the accident-producing path.

Scope:

- truthful govern summary text
- a real conflict/merge-blocked state
- skip blocked/conflicting head item and continue with later ready work
- regression tests for:
  - failed merge must not render as integrated
  - one conflicting PR must not block later ready PRs forever

### PR 2 — govern post-merge cleanup completeness

Re-implement the intent of `bb143db`.

Scope:

- after successful govern merge, run full housekeep semantics, not just sync + prune
- add regression proof for worktree reaping on safe merged cases

### PR 3 — decouple cleanup from sync success

Re-implement the intent of `b2e3060`.

Scope:

- if sync fails, still allow reap/prune when their own safety evidence is sufficient
- report sync failure separately from cleanup result

### PR 4 — JSON-ledger-aware integrated-delivery cleanup

Re-implement the intent of `c801570` on the new JSON ledger model.

Scope:

- add JSON-ledger query path for integrated deliveries
- clear `worktree_path` after confirmed reap
- preserve failed and superseded deliveries
- tests for canonical-path and worktree-path identity handling

### PR 5 — proven-safe force removal

Re-implement the intent of `f844b25`.

Scope:

- force-remove only when proof is strong:
  - exact merged PR evidence for branch tip, or
  - branch content absorbed into `main`
- never force-remove merely abandoned / closed-unmerged work
- add strong safety regression tests

### PR 6 — only then consider `housekeep --loop`

`housekeep --loop` is useful only after cleanup semantics are trustworthy.

---

## 4. What we learned from this accident

### 1. Do not carry umbrella branches across foundational rewrites

Once `#311` landed, any branch that still assumed the old ledger model had to be rewritten, not rebased mechanically.

### 2. Shared hot files need smaller PR slices

`ledger`, `govern`, and `housekeep` are high-collision surfaces. They need smaller, ordered PRs with a clear dependency chain.

### 3. Govern needs first-class failure states

"gated" is too coarse. Merge conflicts, failing CI, review blocks, missing tooling, and policy blocks are different things and need different behaviour.

### 4. Autonomous tools must tell the truth

A tool that prints "integrated" after a failed merge destroys confidence in every other status line.

### 5. Queue fairness matters

A FIFO queue without skip logic is fragile. One bad head item can freeze the whole lane behind it.

### 6. The missing tests were exactly on the scar path

The suite covers many state transitions, but not the merge-conflict retry loop or the lying summary output. Those tests now have concrete justification.

### 7. Build from scars, not speculation

This incident created real scars:

- merge conflict handling,
- post-merge cleanup completeness,
- queue fairness,
- truthful output.

Those are now proven product needs.

---

## 5. How Carson should evolve

## Immediate evolution required

### A. Conflict-aware govern state machine

Carson needs explicit states such as:

- `merge_blocked`
- `conflicting`
- `needs_human`
- `retryable`

Each must carry distinct policy:

- retry later,
- skip and continue,
- escalate immediately,
- or hold for human judgement.

### B. Truthful result-driven govern output

Govern summary text must derive from the **resulting delivery status**, not from the attempted action token.

### C. Queue fairness and skip logic

Govern should not keep selecting the same conflicting PR forever.

It needs:

- skip-on-conflict behaviour,
- bounded retries or cool-down,
- the ability to continue with later ready deliveries.

### D. Complete cleanup contract

Carson still has not fully fulfilled its own desired contract around:

- merge,
- sync,
- worktree reap,
- branch prune,
- ledger cleanup.

That remains incomplete today.

### E. JSON ledger hardening

Now that JSON is the foundation, Carson needs:

- concurrent-writer regression proof,
- corruption-handling tests,
- explicit upgrade policy from SQLite-era users,
- dependency and CI cleanup to remove stale SQLite assumptions.

## Secondary evolution worth doing

1. Remove stale `sqlite3` installation from CI workflows.
2. Move more govern process calls behind adapters for testability and clarity (`docs/develop.md:32-34` already identifies govern as the exception).
3. Add unreleased-mainline visibility to status output.
4. Consider built-in watch / retry UX after gated delivery states.

## Evolution Carson does **not** need from this incident

This incident does **not** justify:

- more session-state machinery,
- more agent ownership signalling,
- speculative large-scale review triage infrastructure.

Carson's own retrospectives were right to remove or avoid those.

The unmet need here is not more metadata. It is **more truthful, more resilient execution**.

---

## Recommended next actions

1. Open a focused govern-hardening issue covering:
   - truthful output,
   - conflict state,
   - queue fairness,
   - regression tests.
2. Re-implement the surviving `#299` ideas as focused PRs on current `main` in the order above.
3. Remove stale `sqlite3` installation from CI.
4. Add release-note entry once the govern hardening lands, because this is user-visible behaviour.

---

## Evidence appendix

### Local commands run

```bash
git log --oneline --decorate -n 25
gh pr list --state all --limit 400 --json number,title,state,mergedAt,closedAt,headRefName,baseRefName,author,url
gh pr view 299 --json ...
gh pr view 311 --json ...
gh pr view 312 --json ...
git show --stat --summary c858292
git show --stat --summary 13707f4
git show --stat --summary 2945733
ruby -c exe/carson
ruby -c lib/carson.rb
ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |path| require File.expand_path(path) }'
bash script/ci_smoke.sh
gh run list --branch main --limit 10 --json databaseId,displayTitle,event,headSha,status,conclusion,workflowName,createdAt,updatedAt,url
gh pr checks 311
gh pr checks 312
git merge-tree $(git merge-base main housekeep/improvements) main housekeep/improvements
```

### Key current-code references

- govern picks first ready delivery: `lib/carson/runtime/govern.rb:84-85`
- failed merge returns delivery to gated: `lib/carson/runtime/govern.rb:206-212`
- govern post-merge cleanup is only sync + prune: `lib/carson/runtime/govern.rb:286-289`
- govern summary formatter: `lib/carson/runtime/govern.rb:431-446`
- delivery reassessment promotes clean PRs to queued: `lib/carson/runtime/deliver.rb:291-299`
- merge command path: `lib/carson/runtime/deliver.rb:521-539`
- current delivery state categories: `lib/carson/delivery.rb:4-7`
- housekeep still couples reap/prune to sync success: `lib/carson/runtime/housekeep.rb:146-152`
- CI still installs sqlite3: `.github/workflows/ci.yml:29-30`, `.github/workflows/ci.yml:64-65`
