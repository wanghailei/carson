# Govern Pipeline Recovery Action Plan — 2026-03-15

Concrete delivery plan for fixing the govern incident scars without reopening `#299`.

---

## Goal

Make Carson's govern pipeline truthful, mergeability-aware, queue-safe, and cleanup-complete on the current JSON-ledger architecture.

## Scope

In scope:

- govern display truthfulness,
- mergeability-aware delivery assessment,
- blocked-state queue behaviour,
- stale integrating recovery,
- post-merge cleanup completion,
- JSON-ledger-aware reap support,
- CI cleanup,
- targeted operator controls if still needed after the safety fixes.

Out of scope for this plan:

- reviving `#299` as a branch,
- unrelated Carson UX redesign,
- speculative multi-repo orchestration features.

---

## Delivery Strategy

Ship this as **small sequential PRs**. Do not bundle the whole recovery into one branch.

Each PR must:

- stay within one coherent behaviour change,
- include regression tests,
- include doc updates where behaviour changes,
- merge before the next dependent PR starts.

---

## PR 0 — Remove obsolete delivery helpers

### Problem

`deliver.rb` still contains helper methods that are no longer used by the current delivery flow.

These methods increase noise in the very file that later recovery PRs need to modify:

- `wait_for_delivery_readiness!`
- `integrate_delivery_now!`
- `deliver_next_step`

### Files

- `lib/carson/runtime/deliver.rb`
- `test/runtime_deliver_test.rb`

### Change

Delete the obsolete helper methods and any test scaffolding that exists only for them.

This PR stays deliberately narrow. It is cleanup only, with no behaviour change intended.

### Acceptance criteria

- the obsolete helper methods are removed
- stale test scaffolding for those methods is removed
- `carson deliver` behaviour remains unchanged

### Verification

- repository-wide grep confirms no remaining callers
- targeted deliver tests still pass

---

## PR 1 — Fix govern result reporting

### Problem

Govern can print `integrated` when the merge actually failed.

### Files

- `lib/carson/runtime/govern.rb`
- `test/runtime_govern_test.rb`

### Change

Replace action-based display with outcome-based display.

Rules:

- if action was `integrate` and resulting status is `integrated`, print `integrated`
- if action was `integrate` and resulting status is `gated`, print `held at gate` or equivalent failure-aware wording
- dry-run wording stays action-oriented

### Acceptance criteria

- failed merge attempts are never displayed as `integrated`
- successful merge attempts still display `integrated`
- dry-run output remains clear

### Verification

- targeted govern unit test for failed merge display
- targeted govern unit test for successful merge display

---

## PR 2 — Teach assessment about mergeability

### Problem

`assess_delivery!` can mark an unmergeable PR as `queued`.

### Files

- `lib/carson/runtime/deliver.rb`
- `lib/carson/runtime/govern.rb`
- tests covering delivery assessment and govern reconciliation

### Change

Add a PR-mergeability query to assessment.

Expected state mapping:

- `CLEAN` → eligible for `queued` if CI and review also pass
- `CONFLICTING` → blocked state with explicit conflict cause
- `BLOCKED` / policy-blocked state → blocked state with explicit summary
- `BEHIND` → still eligible for `queued`, with explicit summary that the head branch is behind base but merge remains eligible under Carson's current merge policy

### Acceptance criteria

- a conflicting PR is never assessed as `queued`
- a `BEHIND` PR can still be assessed as `queued` when CI and review pass
- govern does not attempt to merge a PR known to be conflicting
- delivery summary explains why the PR is blocked

### Verification

- assessment tests for `CLEAN`, `CONFLICTING`, `BEHIND`, and blocked merge states
- govern test proving a conflicting PR is not chosen as next-to-integrate

---

## PR 3 — Add first-class blocked queue handling

### Problem

A conflicted head item can reclaim the front of the queue repeatedly.

### Files

- `lib/carson/runtime/govern.rb`
- `lib/carson/runtime/status.rb`
- govern/status tests

### Change

Introduce explicit queue-safe handling for merge-blocked items.

Minimum behaviour:

- deliveries blocked by merge conflicts stay blocked
- govern skips blocked head items and continues to the next genuinely ready delivery
- status output makes the queue position and block reason visible

### Acceptance criteria

- one blocked delivery does not stop a later ready delivery from being selected
- status exposes which delivery is next and which ones are blocked

### Verification

- govern test with two deliveries: first conflicting, second clean; second is selected
- status test includes next delivery and blocked reason text

---

## PR 4 — Recover stale `integrating` deliveries

### Problem

A delivery can be left in `integrating` after an interrupted or partial govern run.

### Files

- `lib/carson/runtime/govern.rb`
- ledger/govern tests

### Change

Add timeout-based or evidence-based recovery for stale `integrating` entries.

Recovery rules should be explicit:

- if PR is already merged → mark integrated
- if PR is closed unmerged → mark failed
- if merge attempt is stale and PR still open/unmerged → return to a blocked state with recovery guidance

### Acceptance criteria

- stale integrating entries do not remain indefinitely ambiguous
- govern can recover safely after interrupted runs

### Verification

- tests for merged, closed, and stale-open integrating cases

---

## PR 5 — Complete post-merge cleanup

### Problem

Govern merges but does not perform full housekeep semantics.

### Files

- `lib/carson/runtime/govern.rb`
- `lib/carson/runtime/housekeep.rb`
- housekeep/govern tests

### Change

Upgrade `housekeep_repo!` so that a successful govern merge performs:

1. sync,
2. reap dead worktrees when safe,
3. prune.

### Acceptance criteria

- successful govern integration triggers reap logic, not just sync and prune
- safely reaped delivery worktrees are cleared from the filesystem and ledger state as designed

### Verification

- test proving `housekeep_repo!` calls reap path after merge
- integration-style test for merged delivery cleanup

---

## PR 6 — Decouple cleanup from sync success

### Problem

Housekeep currently refuses some cleanup work when sync fails.

### Files

- `lib/carson/runtime/housekeep.rb`
- relevant tests

### Change

Allow reap and prune to proceed when their own evidence is sufficient, even if sync failed.

Output must remain truthful:

- sync failure should still be reported,
- cleanup success should not be hidden behind sync failure.

### Acceptance criteria

- failed sync does not automatically prevent safe cleanup
- result reporting distinguishes sync failure from cleanup outcome

### Verification

- test where sync fails but reap/prune still proceed safely

---

## PR 7 — Port the surviving `#299` ideas to the JSON ledger

### Problem

`#299` contained useful cleanup ideas that still do not exist on current `main`.

### Files

- `lib/carson/ledger.rb`
- `lib/carson/runtime/housekeep.rb`
- tests for ledger-backed cleanup

### Change

Add JSON-ledger-aware lookup for already-integrated deliveries with retained `worktree_path` values.

Suggested API:

- `integrated_deliveries(repo_path:)`

This should support safe reaping of delivery worktrees already known to be integrated.

### Acceptance criteria

- integrated delivery worktrees can be discovered from the JSON ledger
- reap logic can use that data without SQLite assumptions

### Verification

- ledger test for integrated-deliveries query
- housekeep test consuming that query for cleanup decisions

---

## PR 8 — CI dependency cleanup

### Problem

CI still installs `sqlite3` even though runtime SQLite support is gone.

### Files

- `.github/workflows/ci.yml`

### Change

Remove both `gem install sqlite3 --no-document` steps.

### Acceptance criteria

- CI config has no stale SQLite install step
- smoke and audit jobs still pass

### Verification

- local syntax review of workflow file
- GitHub Actions passing after merge

---

## PR 9 — Evaluate targeted integration UX

### Problem

Operators may still need a direct “integrate this PR now” path after the safety fixes land.

### Files

TBD after design choice.

### Decision gate

Only start this PR after PRs 1–4 land.

### Options

1. `carson integrate <pr>`
2. `carson govern --pr <number>`
3. no new command if queue-skip + status visibility fully solve the operator need

### Acceptance criteria

- the chosen interface solves a proven operator workflow pain
- it does not bypass govern rules or duplicate logic unsafely

### Verification

- command-level tests for the selected path
- documentation update in `README.md`, `MANUAL.md`, and/or `API.md` as needed

---

## Suggested Order

1. PR 0 — remove obsolete delivery helpers
2. PR 1 — govern result reporting
3. PR 2 — mergeability-aware assessment
4. PR 3 — queue-safe blocked handling
5. PR 4 — stale integrating recovery
6. PR 5 — complete post-merge cleanup
7. PR 6 — decouple cleanup from sync success
8. PR 7 — JSON-ledger-aware reap
9. PR 8 — CI sqlite cleanup
10. PR 9 — targeted integration UX, only if still justified

---

## Risks

### Risk 1 — accidental policy changes while fixing state logic

Mitigation:

- keep PRs narrow,
- add regression tests before refactor,
- avoid combining queue logic and cleanup logic in one branch.

### Risk 2 — status explosion from too many new states

Mitigation:

- add only states with proven operational meaning,
- prefer a small explicit vocabulary over many subtly different states.

### Risk 3 — cleanup becoming destructive

Mitigation:

- preserve evidence gates for reap and force-remove,
- never force-remove without clear proof of absorption or integration.

---

## Success Definition

This recovery plan is successful when all of the following are true:

1. govern never reports a failed merge as integrated,
2. a conflicting PR is not assessed as ready,
3. one blocked PR cannot freeze the queue behind it,
4. stale integrating entries recover safely,
5. successful govern merges perform full cleanup semantics,
6. the JSON ledger supports integrated-delivery cleanup directly,
7. CI no longer installs unused SQLite runtime dependencies.
