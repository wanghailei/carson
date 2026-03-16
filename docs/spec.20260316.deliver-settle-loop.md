# Carson deliver settle-loop spec

## Status

Active product spec for the bounded settle loop in `carson deliver`.

This document defines the target settle behaviour.

Branch freshness truth is defined in `docs/spec.20260316.deliver-branch-freshness.md`.

This document does not define freshness semantics or rollout slices. It defines the bounded wait, reassessment cadence, merge-attempt rules, and handoff contract inside one `deliver` invocation.

## Spec ownership

This file owns:

- the watch budget,
- poll cadence,
- reassessment flow,
- merge-attempt limits,
- deferred-versus-blocked output once freshness still allows continuation.

The branch-freshness spec owns:

- what `fresh`, `behind`, and `unknown` mean,
- when freshness blocks delivery,
- how freshness constrains `govern`,
- what later slices may add.

If the two specs overlap, use this rule:

- this settle-loop spec decides **how** Carson keeps watching and retrying,
- the branch-freshness spec decides **whether** Carson may continue watching or attempting merge at all.

## Problem

`carson deliver` currently creates or refreshes the PR, performs one bounded wait, then makes at most one merge attempt.

That leaves a bad operator experience in the short-settling case:

- the PR is open,
- GitHub is still settling mergeability or checks,
- Carson exits,
- the user often needs a second `carson deliver` even though the branch becomes mergeable moments later.

The human output also hides too much truth. It does not clearly say:

- whether Carson already waited,
- whether Carson attempted a merge,
- why the PR is still open,
- whether Carson is still watching,
- what the best next command is.

## Goal

Make one `carson deliver` invocation own the short merge-settle window.

Within the existing bounded wait budget, Carson should:

1. create or refresh the PR,
2. keep reassessing short-lived delivery readiness,
3. merge in the same invocation if the PR becomes ready in time,
4. exit with explicit handoff only when the branch is truly blocked or the watch window expires.

## Non-goals

This spec does not define:

- a new CLI command,
- a new config key,
- a new persisted delivery state,
- a broad `carson status` redesign,
- a long-running watch mode inside `deliver`,
- changes to governed merge method.

## Core rule

`carson deliver` owns the short settle window after PR creation.

A second manual `carson deliver` must not be required for the normal “GitHub needed a few more seconds” case.

## Timing contract

### Watch budget

Carson uses `govern.check_wait` as the total settle budget.

### Poll interval

Carson uses `review.poll_seconds` as the reassessment interval.

This spec deliberately reuses the existing review poll interval. It does not introduce a delivery-specific poll setting.

### End conditions

The settle loop ends only when one of these becomes true:

- the delivery is integrated,
- the delivery is hard blocked,
- the settle budget expires.

## Delivery contract

### Existing command surface

The command remains:

- `carson deliver`
- `carson deliver --commit "..."`

No new flags are introduced in this spec.

### Ready-to-merge behaviour

If CI and review pass and the PR becomes mergeable within the settle budget, Carson merges in the same invocation.

### Hard-block behaviour

Carson exits immediately as blocked for these cases:

- CI failing,
- review changes requested,
- review gate error,
- branch freshness behind,
- branch freshness unknown,
- draft PR,
- PR closed without integration,
- merge conflict,
- repository policy block.

### Deferred behaviour

Carson exits as deferred when the settle budget expires before integration and there is no hard blocker.

Deferred means:

- the PR remains open,
- Carson has stopped watching,
- the delivery may still become mergeable later.

## Mergeability rules

### Hard-block mergeability

These states are merge-blocked:

- `mergeable = CONFLICTING`
- `mergeStateStatus = DIRTY`
- `mergeStateStatus = CONFLICTING`
- `mergeStateStatus = BLOCKED`

### Merge-eligible states

These states remain eligible for integration if CI and review also pass:

- `mergeStateStatus = CLEAN`

### Freshness-blocked base drift

`mergeStateStatus = BEHIND` is not merge-eligible in Carson once delivery-first freshness is active.

Carson treats `BEHIND` as a freshness block, not as a harmless squash-merge detail.

The settle loop must stop immediately and report that the branch is behind base.

### Unsettled mergeability

If CI and review pass but GitHub mergeability is still unset, unknown, or transiently not ready, Carson must wait at least one reassessment interval before the first merge attempt.

After one successful reassessment without a hard blocker, Carson must make a probe merge attempt even if mergeability remains unknown, subject to the merge-attempt cap.

## Merge-attempt rules

### Attempt tracking

Carson must track whether a merge was attempted during the current invocation.

### Attempt cap

Carson must make at most 3 merge attempts per invocation, including the first ordinary or probe attempt.

### Retry rule

If a merge attempt fails without a known hard-block reason, Carson reassesses and retries within the same invocation only when both of these are true:

- time remains in the settle budget,
- the merge-attempt cap is not exhausted.

Retries happen on the next reassessment interval. Carson does not spin in a tight merge loop.

### API failure handling

Failures from PR-state, CI, or review queries are transient within the settle budget.

Carson retries them on the next reassessment interval and does not count them as merge attempts.

If no successful reassessment occurs before the settle budget expires, Carson exits as deferred with an explicit assessment-unavailable handoff reason.

Unknown merge-command failures are also treated as transient unless they match a known hard-block reason. They remain subject to the same settle budget and merge-attempt cap.

### No hidden long-running watch

When the settle budget expires, Carson stops. It does not keep watching in the background.

## Human output contract

`carson deliver` must report one of three outcomes:

### Integrated

Use:

- `Merged into main with squash.`
- existing local sync reporting remains

### Deferred

Use:

- `Merge deferred — ...`

Deferred output must state:

- the PR is still open,
- Carson watched for a bounded window and then stopped,
- whether merge was attempted,
- what command to run next.

### Blocked

Use:

- `Merge blocked — ...`

Blocked output must name the blocker directly, for example:

- required checks are failing,
- review changes requested,
- pull request has merge conflicts,
- merge is blocked by repository policy.

### Handoff commands

Deferred and blocked exits must show these next commands in this order:

1. `carson status`
2. `carson deliver`
3. `carson govern --loop 300`

## JSON contract

Keep the existing JSON shape compatible and add these fields:

- `watch_window_seconds`
- `waited_seconds`
- `merge_attempted`
- `handoff.reason`
- `handoff.expectation`
- `handoff.next_steps`

### Field meanings

- `watch_window_seconds`: configured settle budget
- `waited_seconds`: actual elapsed wait during this invocation
- `merge_attempted`: whether this invocation called merge
- `handoff.reason`: machine-readable deferred or blocked reason
- `handoff.expectation`: plain-language explanation of what happens next
- `handoff.next_steps`: ordered command list

The flat fields remain present on every JSON result.

The nested `handoff` object is present only on deferred and blocked exits. It is omitted on integrated exits.

`--json` continues to suppress human output. Human-only watching and retrying status lines do not appear in JSON mode.

## Persistence rule

Do not add a new ledger state for settling.

Settling is runtime behaviour inside one `deliver` invocation, not a persisted delivery lifecycle state.

## Acceptance criteria

This spec is satisfied when all of the following are true:

- one `carson deliver` invocation merges a PR that becomes ready within the configured settle window,
- a second manual `carson deliver` is not needed for the short-settling case,
- branch freshness is rechecked during the settle loop and before merge,
- a PR that becomes `BEHIND` during settle exits as blocked rather than integrating,
- hard blockers still stop promptly and truthfully,
- deferred exits clearly distinguish timeout from hard block,
- draft PRs are treated as blocked, not as settle-wait cases,
- merge attempts never exceed 3 per invocation,
- transient GitHub API failures within the settle budget do not surface as false hard blocks,
- human output states whether merge was attempted,
- JSON output includes bounded-wait and handoff fields,
- docs describe `deliver` as a bounded settle loop rather than a single merge attempt.

## Out of scope

This spec does not require:

- queue-position reporting,
- integrating-duration reporting,
- status-board redesign,
- portfolio-governance redesign.
