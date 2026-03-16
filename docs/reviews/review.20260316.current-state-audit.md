# Carson Current-State Audit — 2026-03-16

## Executive summary

Carson is in a better state than it feels.

The last four days were not random churn. They were a compression event:

1. Carson narrowed its product story.
2. Carson took a real wound in the govern pipeline.
3. Carson turned that wound into concrete runtime guardrails.

The current overall verdict is **yellow-green**.

- **Deliver** is now strong enough to trust for normal work, but still young enough to deserve suspicion around edge semantics.
- **Worktree + housekeep** are much safer than they were on 2026-03-15, especially around main-tree mutation and cleanup truth.
- **Govern** has crossed from “dangerously optimistic” to “operationally credible”, but it still has blind spots around remote-only branch movement and queue steering.
- **Status, audit, and recover** now fit the story better: Carson is trying to be an explicit branch/worktree governor, not a vague repo-overlord.

The centre of gravity has moved.

Carson is no longer best described as “portfolio automation with some worktree helpers”. It is now best described as **a worktree-first branch delivery governor for coding agents, with portfolio govern layered on top**.

---

## Scope and evidence

This audit covers the period **2026-03-12 through 2026-03-16** and focuses on Carson's main business actions:

- `deliver`
- `worktree create/list/remove`
- `govern`
- `housekeep`
- `status`
- `audit`
- `recover`
- `abandon`

Evidence used for this review:

- `git log --since='4 days ago'`
- `README.md`, `MANUAL.md`, `API.md`, `RELEASE.md`
- `docs/develop.md`
- `docs/reviews/review.20260315.*`
- `docs/spec.20260316.*`
- `lib/carson/runtime/*.rb`
- `lib/carson/runtime/local/*.rb`
- `lib/carson/worktree.rb`
- live command checks:
  - `./exe/carson --help`
  - `./exe/carson deliver --help`
  - `./exe/carson govern --help`
  - `./exe/carson worktree --help`
  - `./exe/carson housekeep --help`
  - `./exe/carson status --json`
  - `./exe/carson audit --json`
  - `./exe/carson worktree list --json`
  - `./exe/carson govern --dry-run`
  - `./exe/carson status --all`
- verification:
  - full test suite: **492 runs, 1746 assertions, 0 failures, 0 errors, 0 skips**
  - targeted deliver/status/merge-proof tests: green
  - targeted govern/worktree/housekeep/sync/abandon tests: green

---

## 1. The story of the last four days

### 2026-03-12 — Carson narrowed its promise

Carson stopped trying to sound abstract and started sounding specific.

The public story shifted towards:

- worktree-first operation,
- branch delivery as the main unit of work,
- Carson-owned delivery operations,
- outsider governance rather than repo-embedded tooling.

That was a healthy contraction. The product became easier to explain.

### 2026-03-13 — boundary cleanup

This was a cleanup day.

The repo shed stale template ideas and made its “outsider governor” boundary clearer. That matters because Carson's credibility depends on not becoming the thing it governs.

### 2026-03-15 — the incident day

This is the real pivot.

The govern pipeline incident around `#299`, `#311`, and `#312` exposed five hard truths:

1. umbrella PRs are fragile;
2. foundational rewrites destabilise everything above them;
3. govern was judging by partial truth;
4. govern could narrate an attempted action as if it were a completed result;
5. queue policy without escape hatches becomes self-blocking.

This was the day Carson stopped being a theory.

### 2026-03-16 — the hardening sprint

Most of the 15 March findings were translated directly into runtime changes:

- mergeability-aware govern behaviour,
- truthful integration outcomes,
- delivery freshness gates,
- bounded synchronous settle loop in `deliver`,
- merge proof surfaces,
- safer worktree handling,
- fetch-only govern post-merge proof,
- cleaner loop UX and `TERM` shutdown,
- explicit governed repair path via `recover --check`.

This is the healthiest kind of refactor burst: one driven by a real scar.

---

## 2. Carson's current identity

Carson currently has one coherent product story:

> Carson is an outsider tool that governs repository work for coding agents by making worktrees, branch delivery, cleanup, and merge truth disciplined and explicit.

That story now appears consistently in:

- `README.md`
- `MANUAL.md`
- `API.md`
- `docs/develop.md`
- the recent specs for settle loop, branch freshness, and authority

There is still some future-looking language in the authority material, but the implemented product is much clearer than the aspirational language.

The practical model today is:

- **single-repo depth first**
- **portfolio govern second**
- **remote authority in spirit, but not yet perfectly in runtime truth**

That last clause matters.

The design language is now ahead of one important implementation detail: `worktree create` still falls back to local `main` when remote-baseline proof fails.

---

## 3. Main business actions — health evaluation

### A. `deliver` — **green with yellow edges**

**What it is now**

`deliver` is Carson's strongest business action.

It now owns the full synchronous happy path for one branch:

1. preflight,
2. template sync,
3. optional commit,
4. freshness proof,
5. push,
6. PR create or refresh,
7. bounded settle loop,
8. merge when clear,
9. local sync,
10. merge proof.

**What improved**

- freshness is checked before side effects and during reassessment;
- the settle loop now covers the common “GitHub needed a little more time” case;
- merge proof is more meaningful than a bare “PR merged” claim;
- sync-after-merge is safer around detached or misattached main worktrees.

**Why this matters**

Before, Carson could feel like a handoff tool. Now it feels like a delivery tool.

That is a major product improvement.

**Remaining yellow edges**

- help text still understates the true synchronous behaviour;
- blocked or deferred post-PR outcomes still exit `0`, so scripts must inspect JSON rather than trust exit code alone;
- some recovery guidance still leaks raw `git`/`gh` commands, which weakens the Carson-owned story;
- user-facing freshness wording is still more consistent in the spec than in runtime output.

**Judgement**

`deliver` is the healthiest core action in Carson today. It is not yet boring, but it is credible.

---

### B. `worktree` — **yellow-green**

**What it is now**

Worktrees are clearly treated as the isolation primitive, not an optional convenience.

`worktree list` is also better than before: it is no longer just an inventory; it is a cleanup diagnosis surface.

**What improved**

- create is now fetch-first rather than pull-on-main;
- remove guards against current-shell CWD, other-process CWD, dirty state, and unpushed work;
- list surfaces absorbed state, PR state, and keep-or-reap recommendations;
- dirty worktrees are no longer automatically swept away by cleanup logic.

**Current live picture**

On 2026-03-16, Carson reported:

- **6 tracked worktrees** total,
- **5 outside main**,
- **3 clean reap candidates** from merged PRs,
- **1 detached keep case**,
- **1 absorbed-but-no-evidence keep case**.

That is actually a useful diagnostic picture. Carson can now tell a believable story about what should be cleaned and what should be preserved.

**Remaining yellow edges**

1. **Remote-authority gap**
   - `worktree create` still falls back to local `main` if remote proof fails.
   - That conflicts with Carson's active authority spec.

2. **Missing-directory deletion risk**
   - if a registered worktree directory disappears externally, cleanup can still delete the branch ref even when that ref was the last local copy.

**Judgement**

Worktree handling has improved sharply. The main remaining issue is not everyday ergonomics; it is authority truth and last-reference safety.

---

### C. `govern` — **yellow-green, but still the least boring major action**

**What it is now**

`govern` finally behaves more like an overseer and less like a hopeful queue consumer.

It now:

- reassesses truthfully,
- checks mergeability, freshness, CI, and review,
- integrates one ready delivery at a time,
- defers revision when the target worktree is occupied,
- avoids mutating the user's main worktree after merge,
- supports looped operation with better visibility and cleaner `TERM` exit.

**What improved**

This is where the 15 March scar is most visible.

The system specifically fixed:

- false-success narration,
- mergeability blindness,
- unsafe post-merge main-tree mutation,
- occupied-worktree revision dispatch,
- poor loop observability.

That is substantial recovery.

**Current live picture**

On 2026-03-16:

- `./exe/carson govern --dry-run` reported **3 governed repos**,
- none currently had active deliveries.

That does not prove govern is perfect, but it does show the portfolio layer is currently calm rather than actively failing.

**Remaining yellow edges**

1. **Remote-only supersede blind spot**
   - if the remote PR branch advances but the local branch reference does not, govern can miss the supersede condition.

2. **Queue steering remains coarse**
   - there is still no first-class targeted “integrate this PR now” or more refined queue management surface.

3. **The product story is ahead of the operator surface**
   - govern is more truthful now, but the docs from 2026-03-15 are partly incident-history and partly obsolete-state.

**Judgement**

Govern has gone from “the dangerous part” to “the complicated part”. That is real progress. It still deserves the most scrutiny.

---

### D. `housekeep` — **green for ordinary use, yellow for edge safety**

**What it is now**

Housekeep is no longer trying to be too clever with too little proof.

It now:

- resolves to the canonical main root,
- can continue cleanup when sync blocks,
- reaps with stronger evidence,
- leaves dirty worktrees alone,
- cooperates better with the worktree cleanup classifier.

**What improved**

The important change is philosophical as much as technical:

Housekeep has become more conservative.

That is the right direction. Cleanup tools should be boring and slightly stubborn, not eager.

**Remaining yellow edge**

The missing-directory case is still too destructive if the vanished worktree held the last local branch reference.

**Judgement**

For normal merged-PR cleanup, housekeep now looks trustworthy. For unusual filesystem-loss scenarios, it still needs a stronger scar-based guard.

---

### E. `status` and `audit` — **green**

**What they are now**

These surfaces now tell a fairly coherent truth:

- `status` is branch-delivery centred,
- `status --all` is a portfolio snapshot,
- `audit` checks local governance health and default-branch baseline state.

**Observed live state on 2026-03-16**

- `status --json` reported Carson **3.28.0** on `main`, clean, in sync, no active deliveries.
- `audit --json` returned **status: ok**.
- `status --all` reported **AI**, **carson**, and **nexus**, all with no active deliveries.

There was one transient moment where a human-format audit output reported a pending baseline check, but the later structured audit returned clean. That suggests timing or surface inconsistency rather than a durable health problem.

**Judgement**

These are now useful operations, not decorative ones.

---

### F. `recover` — **small but strategically important**

**What it is now**

`recover --check` is not a daily tool. It is an integrity tool.

It gives Carson a legitimate path through the “baseline-red governance check blocks its own repair” deadlock.

That matters because without it, users learn bypass habits.

**Judgement**

This is a strong addition. It is narrow, principled, and aligned with Carson's own scar history.

---

### G. `abandon` — **green for intent, yellow for language polish already mostly fixed**

`abandon` now behaves more honestly:

- committed-but-unpushed work is treated as intentional discard,
- dirty worktrees still block,
- unsupported `--force` suggestions were removed.

This command is now aligned with its semantic meaning: abandonment is disposal, not archival safety.

---

## 4. Current command map

| Family | Main commands | Current status |
|---|---|---|
| Setup and boundary | `setup`, `onboard`, `refresh`, `offboard`, `template` | coherent |
| Single-repo daily ops | `deliver`, `recover`, `status`, `audit`, `sync`, `prune`, `housekeep`, `abandon` | coherent |
| Worktree lifecycle | `worktree create`, `worktree list`, `worktree remove` | strong, with one authority gap |
| Portfolio layer | `status --all`, `audit --all`, `refresh --all`, `housekeep --all`, `govern` | credible |
| Review governance | `review gate`, `review sweep` | present but not the centre of recent change |
| Info | `version` | fine |

The most mature action family is now:

- **branch delivery and evidence**

The least mature action family is now:

- **portfolio orchestration under edge conditions**

---

## 5. What is healthy now

These are the strongest current signs:

1. **The product story is tighter.**
2. **The core commands match real scars.**
3. **The full test suite is green.**
4. **The dangerous 15 March defect class was mostly addressed directly, not cosmetically.**
5. **Carson now produces more evidence and less theatre.**

That last point is the most important.

The current Carson is more interested in proving delivery truth than in narrating confidence. That is exactly the right evolution.

---

## 6. What is still risky

These are the highest-value remaining gaps.

### Priority 1 — authority truth gap in `worktree create`

If Carson says remote authority is the rule, branch creation should fail closed when remote proof is unavailable.

Right now the docs are stricter than the runtime.

### Priority 2 — remote-only supersede gap in `govern`

Govern should notice branch advancement even when only the remote ref moved.

Otherwise it can continue reasoning from stale local branch state.

### Priority 3 — missing-directory branch-loss risk

If a worktree directory disappears externally, Carson should not assume the local branch ref is safe to delete.

This is exactly the kind of rare but painful edge case that deserves an explicit scar guard.

### Priority 4 — Carson-owned language consistency

Recovery and failure guidance should stop teaching raw `git` and `gh` commands when Carson claims ownership of the workflow.

### Priority 5 — old incident docs vs current truth

The 15 March review docs are valuable history, but parts of them are already stale as current-state description.

A fresh current-state review should exist beside them.

---

## 7. Bottom line

Carson is not lost.

Carson is in the middle of becoming itself.

The recent chaos was the cost of collapsing several half-compatible stories into one real one:

- not generic governance, but agent governance;
- not abstract orchestration, but branch/worktree discipline;
- not optimistic automation, but explicit proof and guarded cleanup.

That transition hurt because it happened under live fire. But the result is better than the feeling it leaves behind.

### The shortest honest summary

- **Deliver**: strong and getting sharper.
- **Worktree**: much safer, with one serious authority gap left.
- **Govern**: no longer naive, still the riskiest subsystem.
- **Housekeep**: conservative in the right way.
- **Status/Audit/Recover**: increasingly coherent support surfaces.

If Carson's job is to make multiple coding agents safe in one repository, the current codebase is now much closer to that job than it was four days ago.

It does not need reinvention.

It needs one more round of truth-alignment and edge-case hardening.
