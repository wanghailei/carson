# Govern Pipeline Final Review — 2026-03-15

Merged final review of the govern pipeline incident, the `#299` / `#311` / `#312` interaction, and the current state of Carson after the recovery work.

---

## Executive Summary

This was not one bug. It was a chain failure.

1. **`#299` was too broad.** It bundled multiple housekeep and govern changes across 28 files.
2. **`#311` changed the ledger foundation underneath it.** SQLite was replaced with JSON, directly overlapping `ledger`, `deliver`, `govern`, `housekeep`, tests, and docs.
3. **Govern lacked mergeability awareness.** A PR could be green on CI and review, still be unmergeable, and Carson would continue treating it as ready.
4. **Govern output could misreport failure as success.** The display layer reported the attempted action (`integrate`) rather than the actual outcome.
5. **The queue had no escape hatch.** A conflicted first-ready delivery could keep reclaiming the front of the queue and block later deliveries.
6. **`#299` was manually closed, not auto-closed by Carson.** Once `#311` landed and `#312` salvaged the canonical-root slice, the remaining `#299` branch had deep structural conflicts and was no longer a safe merge candidate.

The root cause is therefore **an oversized umbrella branch colliding with a foundational rewrite, amplified by govern state-machine gaps**.

---

## 1. What Happened

### Timeline

On **2026-03-15 (Asia/Taipei)**:

- **13:58** — `#299` opened: *Housekeep mechanism improvements*
- **14:45** — commit `2945733` added to `#299`: canonical-root housekeep fix
- **15:00** — `#311` opened: *replace SQLite ledger with JSON file store*
- **15:16** — `#312` opened: *Fix housekeep canonical root*
- **16:35** — `#311` merged into `main` as `c858292`
- **16:37:53** — comment added to `#299` noting structural conflicts
- **16:37:54** — `#299` manually closed by `wanghailei`
- **16:38:08** — `#312` merged into `main` as `13707f4`

### Causal chain

#### A. `#299` was structurally fragile

`#299` mixed:

- govern post-merge cleanup,
- housekeep control flow,
- dirty worktree removal policy,
- ledger-aware reap,
- `housekeep --loop`,
- docs and tests.

That made it highly sensitive to any concurrent change in Carson's runtime core.

#### B. `#311` landed underneath it

`#311` replaced the ledger model. That directly changed the same hot files `#299` depended on:

- `lib/carson/ledger.rb`
- `lib/carson/runtime/deliver.rb`
- `lib/carson/runtime/govern.rb`
- `lib/carson/runtime/housekeep.rb`
- related tests and docs

After `#311`, `#299` was not merely behind `main`. It was architecturally stale.

#### C. Govern could not tell “green but unmergeable” from “ready”

`assess_delivery!` checks CI and review only. It does **not** query GitHub mergeability.

Source:
- `lib/carson/runtime/deliver.rb:198-212`
- `lib/carson/runtime/deliver.rb:294-302`

So a PR with:

- green CI,
- passing review,
- **merge conflicts**

could still be recorded as:

- `status: "queued"`
- `summary: "ready to integrate into main"`

Govern would then attempt the merge, fail, mark it `gated`, and the next reconcile pass would promote it back to `queued`.

#### D. FIFO plus re-queue created head-of-line blocking

Govern reconciles all active deliveries, then selects the first ready item:

- `lib/carson/runtime/govern.rb:84-85`

A failed merge sets the delivery back to `gated`:

- `lib/carson/runtime/govern.rb:189-212`

Reassessment can then make it ready again:

- `lib/carson/runtime/deliver.rb:294-302`

So a conflicted PR can oscillate:

- `queued → integrating → gated → queued`

and repeatedly reclaim the first-ready slot.

#### E. The UI lied about the result

`format_govern_action` maps the attempted action `integrate` to the display text `integrated` regardless of the resulting status.

Source:
- `lib/carson/runtime/govern.rb:438-446`

So the operator can see “integrated” even when the merge actually failed and the ledger status is `gated`.

#### F. `#299` was then closed by human judgement

This is important: Carson did not auto-close `#299`.

`#299` was manually closed once:

- `#311` had changed the ledger foundation,
- `#312` had already extracted the one cleanly salvageable slice,
- the remaining `#299` branch was a large conflicted rewrite with no safe cherry-pick path.

---

## 2. Root Cause and Responsibility

### Immediate technical root cause

**Govern lacked mergeability-aware assessment and truthful result reporting.**

### Deeper process root cause

**`#299` was too broad to survive concurrent foundational change.**

### Human responsibility

- `wanghailei` merged `#311`
- `wanghailei` closed `#299`
- `wanghailei` merged `#312`

That was not the mistake. The mistake was earlier: allowing a broad umbrella PR to remain open while a foundational rewrite was converging on the same files.

### System responsibility

Carson did not provide the operator with:

- a merge-blocked state distinct from ordinary gating,
- truthful govern output,
- queue skip behaviour,
- a targeted integration path,
- complete post-merge cleanup.

Those missing capabilities turned a difficult merge situation into a pipeline incident.

---

## 3. Current Status and Codebase Quality After `#311` and `#312`

### Verified status

Current local and remote `main` are aligned.

Verified on **2026-03-15**:

- local `HEAD`: `931949fdfa183ad49e6006400f12ccac99969dda`
- `github/main`: `931949fdfa183ad49e6006400f12ccac99969dda`
- investigation review present locally:
  - `docs/reviews/review.20260315.pr-299-311-312-investigation.md`

### Verified quality signals

The post-merge codebase is operationally healthy.

Observed evidence from the recovery session:

- full test suite passed: **405 runs, 1298 assertions, 0 failures, 0 errors, 0 skips**
- `bash script/ci_smoke.sh` passed
- syntax checks passed:
  - `ruby -c exe/carson`
  - `ruby -c lib/carson.rb`
- latest GitHub CI runs for the merged PRs were green

### What is clean

The JSON-ledger migration itself is coherent.

Healthy areas include:

- `lib/carson/ledger.rb`
- `lib/carson/runtime/deliver.rb`
- `lib/carson/runtime/govern.rb`
- `lib/carson/config.rb`
- `carson.gemspec`

Key migration observations:

- no runtime SQLite dependency remains in the gemspec,
- delivery keys are now composite JSON-ledger identities,
- govern and deliver use the new key-based model coherently.

### Confirmed defects still present on `main`

#### A. Govern display bug

`format_govern_action` still reports by attempted action rather than actual outcome.

Source:
- `lib/carson/runtime/govern.rb:438-446`

#### B. Govern merge-loop / queue-blocking bug

The assess/reconcile/govern loop still allows a conflicted PR to cycle between `queued` and `gated`.

Sources:
- `lib/carson/runtime/govern.rb:84-85`
- `lib/carson/runtime/govern.rb:189-212`
- `lib/carson/runtime/deliver.rb:294-302`

#### C. Post-merge cleanup is incomplete

`housekeep_repo!` syncs and prunes, but does not call `reap_dead_worktrees!`.

Source:
- `lib/carson/runtime/govern.rb:286-289`

#### D. Housekeep cleanup is still coupled to sync success

`housekeep_one_entry` only reaps after a successful sync. That makes cleanup more fragile than necessary.

Source:
- `lib/carson/runtime/housekeep.rb:146-152`

#### E. CI still installs unused SQLite runtime dependencies

Source:
- `.github/workflows/ci.yml:29-30`
- `.github/workflows/ci.yml:64-65`

### Secondary cleanup candidates

There are helper methods in `deliver.rb` that appear unused by the current direct call graph:

- `wait_for_delivery_readiness!`
- `integrate_delivery_now!`
- `deliver_next_step`

Source definitions:
- `lib/carson/runtime/deliver.rb:214-322`

These should be deleted only after a dedicated proof pass confirms no intended path still depends on them.

---

## 4. What to Do About `#299`

Do **not** reopen or revive the original branch.

Treat `#299` as a **design and intent source**, not as a merge candidate.

### Already salvaged

The canonical-root housekeep fix from `#299` has already been extracted and merged separately in `#312`.

### Still valuable from `#299`

The following ideas remain worth implementing on current `main`:

1. govern post-merge reaping of dead worktrees,
2. cleanup continuing even when sync fails,
3. safe force-remove for already-absorbed dirty worktrees,
4. ledger-aware reaping for already-integrated delivery worktrees,
5. optional `housekeep --loop`.

### What must not be ported blindly

Anything written against the old SQLite-ledger assumptions must be rethought against the JSON-ledger design.

In particular:

- ledger queries,
- repo identity handling,
- integrated-delivery cleanup,
- worktree-state reconciliation.

### Reimplementation rule

**Port concepts, not hunks.**

---

## 5. What Was Learned

### Lesson 1 — umbrella branches are fragile under foundational change

Large refactoring branches do not age linearly. They cross a threshold and become structurally stale.

### Lesson 2 — assessment must check what integration actually needs

If govern is the merge authority, assess must include mergeability, not just CI and review.

### Lesson 3 — operators need outcome truth, not action narration

The interface must report what happened, not what Carson attempted.

### Lesson 4 — queues need escape hatches

FIFO alone is not enough. A real queue needs at least:

- skip,
- blocked state,
- human-targeted execution,
- recovery for stale integrating entries.

### Lesson 5 — post-merge cleanup is part of delivery, not a separate nice-to-have

If Carson says a delivery is integrated, the repo should move materially closer to clean state.

### Lesson 6 — the scar is now proven

This is no longer speculation. Carson has a real scar around:

- mergeability awareness,
- govern truthfulness,
- queue fairness,
- post-merge cleanup,
- JSON-ledger operational hardening.

Those are now justified product needs.

---

## 6. How Carson Should Evolve

### Priority order

#### Priority 1 — govern truth and safety

1. Fix `format_govern_action`
2. Teach `assess_delivery!` about mergeability
3. Introduce a first-class `merge_blocked` / `conflicting` state
4. Make govern skip blocked head items and continue
5. Add recovery for stale `integrating` deliveries

#### Priority 2 — complete post-merge cleanup

6. Make `housekeep_repo!` call `reap_dead_worktrees!`
7. Decouple cleanup from sync success when evidence is otherwise sufficient
8. Port JSON-ledger-aware integrated-delivery cleanup

#### Priority 3 — operator control

9. Add a targeted integration path such as `carson integrate <pr>` or `carson govern --pr <number>`
10. Add queue visibility in `carson status`
11. Add pause / resume for deliveries

#### Priority 4 — cleanup and hardening

12. Remove stale CI SQLite installs
13. Confirm and remove truly unused delivery helpers
14. Add JSON-ledger concurrency and corruption-handling tests
15. Add migration-path documentation for old SQLite users if support is still expected

### Guiding principle

The next Carson improvements should optimise for **truthful, resilient execution**, not for more orchestration machinery.

---

## 7. Final Judgement

### What caused the accident

**An oversized stale umbrella PR collided with a foundational ledger rewrite, and govern lacked the states and controls needed to recover cleanly.**

### What is the current codebase quality

**Healthy enough to use and build on, but not trustworthy enough to leave govern unattended around merge conflicts.**

### What should happen to `#299`

**Do not revive it. Rebuild its still-valuable ideas in focused PRs on current `main`.**

### What Carson most urgently needs

1. truthful govern output,
2. mergeability-aware assessment,
3. blocked-state queue handling,
4. complete post-merge cleanup,
5. JSON-ledger operational hardening.

---

## Evidence Appendix

### Code references

- `lib/carson/runtime/deliver.rb:198-212`
- `lib/carson/runtime/deliver.rb:294-302`
- `lib/carson/runtime/govern.rb:84-85`
- `lib/carson/runtime/govern.rb:189-212`
- `lib/carson/runtime/govern.rb:286-289`
- `lib/carson/runtime/govern.rb:438-446`
- `lib/carson/runtime/housekeep.rb:146-152`
- `.github/workflows/ci.yml:29-30`
- `.github/workflows/ci.yml:64-65`

### Verification summary used in this review

- local and remote `main` SHA matched at `931949fdfa183ad49e6006400f12ccac99969dda`
- govern display bug was reproduced directly in Ruby during the investigation run
- current main passed syntax, smoke, and full test verification during the recovery session
