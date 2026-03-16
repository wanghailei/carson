# Carson deliver branch freshness spec

## Status

Active product spec for delivery-first branch freshness in `carson deliver`.

This document defines the target freshness truth and rollout slices. It does not define settle timing beyond the freshness gate.

## Spec ownership

This file owns:

- what branch freshness means,
- when freshness blocks delivery,
- how freshness interacts with `govern`,
- what ships in Slice 1, Slice 2, and Slice 3.

`docs/spec.20260316.deliver-settle-loop.md` owns:

- the bounded settle window inside one `deliver` invocation,
- reassessment cadence,
- merge-attempt limits,
- deferred-versus-blocked handoff behaviour when freshness is already satisfied.

If the two specs overlap, use this rule:

- the branch-freshness spec decides **whether** Carson may continue towards merge,
- the settle-loop spec decides **how** Carson waits and retries once continuation is still allowed.

## Problem

Carson already tries to start new work from a fresh baseline.

`carson worktree create` performs a best-effort fast-forward pull on the main worktree before branching. That is the first freshness checkpoint in the lifecycle.

That checkpoint is not enough.

While an agent works on a feature branch, `main` can advance. By the time `carson deliver` runs, the branch may no longer reflect the current base.

The failure is not theoretical. PR #315 added pre-commit freshness blocking and delivery-time auto-rebase, then was reverted the same day. The reverted design mixed too many risky changes at once:

- pre-commit became a network gate,
- freshness and automatic history rewrite shipped together,
- delivery still failed open when freshness could not be proved,
- fetch scope was broader than the check required,
- tests did not prove the key behaviour.

The scar is clear:

1. freshness must be enforced where it matters,
2. unknown freshness must never be treated as safe,
3. the first safe slice must not include automatic history rewrite.

## Goal

Make `carson deliver` the authoritative freshness gate.

Before Carson is allowed to merge, or continue towards merge, it must verify that the branch is fresh against the current remote `main`.

Within that rule, Carson should:

1. keep pre-commit lightweight,
2. tell the truth when freshness is unknown,
3. stop promptly when the branch is behind base,
4. re-check freshness while `deliver` is watching a short settle window,
5. avoid fetching unrelated refs.

## Non-goals

This spec does not define:

- a pre-commit freshness block,
- advisory audit freshness in the first slice,
- automatic rebase or refresh in the first slice,
- a new CLI command,
- a new config key,
- a broad `status` redesign in the first slice.

## Lifecycle model

Carson has two freshness checkpoints:

1. **Worktree creation checkpoint** — best-effort freshness at branch creation time.
2. **Delivery checkpoint** — strict freshness at delivery time.

The new delivery checkpoint closes the gap between:

- “this branch started from a fresh baseline”
- and
- “this branch is still fresh when Carson tries to land it”.

## Core rule

`carson deliver` must not merge, or continue towards merge, unless freshness against the current remote `main` has been verified during the current invocation.

Freshness is a delivery concern, not a commit concern.

## Truth rule

Freshness has three meaningful states:

- **fresh** — Carson proved the branch is current against the fetched remote `main`
- **behind** — Carson proved the remote `main` contains commits not present on the branch
- **unknown** — Carson could not prove either of the above

Only `fresh` is merge-ready.

`behind` and `unknown` are both non-ready.

Unknown is never treated as fresh.

## Slice 1

### Scope

Slice 1 adds the strict gate only.

It does not add automatic branch refresh.

### Deliver contract

After the existing dirty-tree and optional `--commit` flow have produced a clean delivery state, `carson deliver` must:

1. fetch the configured remote `main`,
2. compare the current branch against that fetched base,
3. classify freshness,
4. stop immediately unless freshness is `fresh`.

This gate runs before push, PR creation or refresh, settle-loop entry, or merge.

### Fetch scope

Carson must fetch only what the freshness check needs.

It must not fetch all refs when only remote `main` is required.

### Behind behaviour

If the branch is behind the fetched remote `main`, Carson exits blocked.

It does not push, create or refresh a PR, enter the settle loop, or attempt a merge.

### Unknown behaviour

If Carson cannot verify freshness because fetch or comparison failed, Carson exits blocked.

It does not push, create or refresh a PR, enter the settle loop, or attempt a merge.

### Dirty worktree rule

Slice 1 includes no auto-refresh path.

That removes the risk of rebasing a dirty tree.

The freshness gate runs only after the existing `deliver` flow has established a clean tree for delivery.

## Settle-loop interaction

The settle loop in `docs/spec.20260316.deliver-settle-loop.md` remains active, but freshness changes its readiness rules.

### Reassessment rule

Freshness must be checked:

1. before entering the settle loop,
2. on every reassessment iteration,
3. immediately before any merge attempt.

### Base movement during settle

If `main` advances during the settle window, the delivery becomes freshness-blocked mid-invocation.

This is a hard block, not a deferred timeout state, because it will not self-resolve without a branch refresh.

### Mergeability interaction

`mergeStateStatus = BEHIND` is not merge-eligible in Carson once this spec is active.

Even if squash integration could technically succeed, Carson treats `BEHIND` as a freshness block and stops.

## Human output contract

Carson must use Carson-written freshness messages.

It must not surface raw Git conflict text as the primary operator message for freshness failures.

### Fresh

Use:

- `Verified freshness against github/main.`

### Behind

Use:

- `Merge blocked — branch is behind github/main.`

Recovery should tell the operator to refresh the branch and rerun `carson deliver`.

### Unknown

Use:

- `Merge blocked — Carson could not verify freshness against github/main.`

Recovery should tell the operator to retry `carson deliver` after resolving the underlying connectivity or repository issue.

## JSON contract

Slice 1 must surface freshness explicitly in `deliver` JSON.

Minimum fields:

- `freshness.status`
- `freshness.reason`

This avoids forcing consumers to infer freshness from generic delivery state strings.

## Architecture placement

Freshness policy lives in the runtime layer.

It must not be embedded in passive data holders such as `Branch`, `Delivery`, or `Ledger`.

The implementation should use one shared internal freshness assessor for:

- `deliver`
- `govern`
- later slices that may expose freshness through `status` or `audit`

The assessor consumes live git and GitHub facts and returns a structured verdict.

## Govern rule

`govern` must obey the same freshness rule as `deliver`.

It must never merge a delivery whose freshness is `behind` or `unknown`.

A freshness-blocked delivery is not revision work.

`govern` must surface it as “refresh required”, not dispatch an agent to “fix” it.

## Audit rule

Audit freshness is deferred out of Slice 1.

Reason:

- the authoritative freshness check belongs to `deliver`,
- a local-only advisory can be misread as authoritative,
- Slice 1 should focus on the hard guarantee first.

If a later slice adds audit freshness, the advisory must be explicitly labelled as last-known local state and must not block commit.

## Slice 2

Slice 2 adds persisted freshness evidence.

Minimum delivery evidence fields:

- `freshness_state`
- `freshness_checked_at`
- `freshness_base_sha`
- `freshness_branch_sha`
- `freshness_reason`

The evidence lives on the delivery record, not in a separate parallel state object.

This slice enables `status` and `govern` to render the last assessed freshness truth without recomputing ad hoc on every surface.

## Slice 3

Automatic branch refresh is deferred to a later slice.

It is not part of Slice 1 or Slice 2.

Before Carson may auto-refresh a branch, all of these must be proven:

1. clean worktree is a hard prerequisite,
2. in-progress rebase, merge, or cherry-pick state is absent before refresh begins,
3. fetch scope remains targeted,
4. failure never falls through as success,
5. abort handling is safe and truthful,
6. tests prove ancestry, not just log visibility.

## Documentation contract

When Slice 1 ships, these files must agree:

- `README.md`
- `MANUAL.md`
- `API.md`
- `docs/spec.20260316.deliver-settle-loop.md`

They must all describe the same rule:

- delivery owns freshness,
- behind blocks merge,
- unknown blocks merge,
- no pre-commit freshness enforcement in Slice 1.

## Acceptance criteria

This spec is satisfied when all of the following are true:

1. `carson deliver` blocks when freshness is `behind`.
2. `carson deliver` blocks when freshness is `unknown`.
3. no push or merge attempt occurs after a behind or unknown freshness verdict.
4. `carson deliver` checks only the remote `main` needed for freshness.
5. if `main` advances during the settle loop, the delivery becomes freshness-blocked before merge.
6. `govern` never merges a freshness-blocked delivery.
7. docs describe freshness as a delivery-time gate, not a commit-time gate.

## Verification plan

### Slice 1 proofs

1. fresh branch passes the freshness gate and may continue through settle.
2. behind branch blocks before push or merge.
3. unknown freshness blocks before push or merge.
4. no merge attempt occurs for behind or unknown freshness.
5. `main` advancing during settle flips a once-fresh delivery into freshness-blocked.
6. `mergeStateStatus = BEHIND` is no longer treated as merge-ready.
7. fetch scope is limited to the main branch used for freshness.

### Most important proof

The highest-value proof is the real-git settle test:

1. start with a fresh delivery,
2. enter the settle loop,
3. advance `main`,
4. reassess freshness,
5. verify Carson refuses the merge because the branch is no longer fresh.
