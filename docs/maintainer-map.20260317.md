# Carson Maintainer Map — 2026-03-17

## One-sentence identity

Carson is a **worktree-first branch delivery governor for coding agents**: it starts work safely, lands branches through a disciplined PR flow, and cleans up with proof rather than optimism.

## What Carson is

- **An outsider tool** — it governs repositories without becoming their runtime dependency.
- **A branch-delivery system** — the branch is the unit of delivery; the worktree is the isolation container.
- **A truth surface** — `status`, `audit`, merge proof, and govern should tell the operator what is actually true, not what Carson hoped would happen.
- **Single-repo first** — portfolio govern matters, but the product only works if one repository works boringly well.

## What Carson is not

- Not a generic repo automation platform.
- Not a local-authority workflow today.
- Not a background daemon that owns everything.
- Not a substitute for GitHub CI, review, or branch protection.
- Not successful just because it prints decisive-looking output.

## The command family map

| Job | Primary command(s) | Mental model |
|---|---|---|
| Start governed work | `setup`, `onboard`, `refresh`, `template` | install the rules and boundary |
| Create isolated work | `worktree create/list/remove` | start clean, keep sessions apart |
| Land the current branch | `deliver` | Carson's main business action |
| Repair governance deadlock | `recover --check` | narrow exceptional path |
| Check local truth | `status`, `audit`, `sync` | what state am I actually in? |
| Clean up safely | `housekeep`, `abandon`, `prune` | remove only with evidence |
| Run portfolio oversight | `status --all`, `audit --all`, `govern` | layer 2, not the centre |
| Review governance | `review gate`, `review sweep` | PR hygiene and review truth |

## The subsystem health map

### Green

- **`deliver`** — strongest subsystem; freshness, settle loop, merge proof, and sync-after-merge now form a believable delivery path.
- **`status` / `audit`** — increasingly useful truth surfaces.
- **`recover`** — narrow, principled, strategically important.

### Yellow-green

- **`worktree`** — much safer than before; still has one authority gap.
- **`housekeep`** — conservative in the right way; one ugly filesystem-loss edge remains.
- **`abandon`** — semantics now mostly honest.

### Yellow

- **`govern`** — no longer naive, but still the least boring major subsystem and the one most likely to hide edge-case complexity.

## If something breaks, where to look first

### Delivery feels wrong

Look at:
- `lib/carson/runtime/deliver.rb`
- `lib/carson/runtime/local/merge_proof.rb`
- `docs/spec.20260316.deliver-branch-freshness.md`
- `docs/spec.20260316.deliver-settle-loop.md`

Typical symptom classes:
- freshness block,
- settle-loop confusion,
- merge-attempt semantics,
- merge proof mismatch,
- exit-code vs JSON mismatch.

### Worktree behaviour feels unsafe

Look at:
- `lib/carson/worktree.rb`
- `lib/carson/runtime/local/worktree.rb`
- `lib/carson/runtime/local/sync.rb`
- `docs/spec.20260316.authority-model.md`

Typical symptom classes:
- wrong base branch,
- unsafe removal,
- CWD/process holds,
- missing-directory cleanup,
- authority drift.

### Govern behaves strangely

Look at:
- `lib/carson/runtime/govern.rb`
- `lib/carson/runtime/deliver.rb` (assessment logic shared with govern)
- `lib/carson/ledger.rb`
- `docs/reviews/review.20260315.govern-pipeline-final.md`

Typical symptom classes:
- stale queued/gated state,
- supersede detection,
- revision dispatch into occupied worktree,
- mergeability truth,
- queue head blocking.

### Cleanup or state feels inconsistent

Look at:
- `lib/carson/runtime/housekeep.rb`
- `lib/carson/runtime/status.rb`
- `lib/carson/runtime/audit.rb`
- `lib/carson/ledger.rb`

Typical symptom classes:
- stale active deliveries,
- worktree reap decisions,
- baseline CI ambiguity,
- status disagreeing with live GitHub state.

## The three ideas maintainers should protect

### 1. Truth beats convenience

If Carson cannot prove something, it should block or say unknown.

### 2. Main-tree safety beats eager cleanup

Carson must never make the user's main worktree collateral damage.

### 3. One story beats clever surfaces

Branch origin, delivery truth, cleanup rules, docs, and output must all describe the same operating model.

## The top priorities now

1. **Close the authority gap in `worktree create`.**
   - Remote authority should fail closed when remote proof is unavailable.

2. **Teach govern to detect remote-only supersedes.**
   - Local branch state is not always enough.

3. **Protect the last local branch ref in missing-directory cleanup.**
   - External deletion should not silently become data loss.

4. **Make Carson-owned recovery language fully Carson-owned.**
   - Stop teaching raw `git` and `gh` where Carson claims ownership.

5. **Keep incident history and current truth separate.**
   - The 2026-03-15 reviews are scar history. They should not become stale source-of-truth docs.

## How to think about Carson now

If you need one mental model, use this:

> Carson is trying to make multiple coding agents safe in one repository by turning branch delivery, worktree isolation, and cleanup truth into explicit, testable behaviour.

That is the centre.

Everything else is support.
