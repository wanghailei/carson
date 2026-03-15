# Governance Recovery Note

## Related issues

- #335 — governed recovery path for baseline-red governance checks
- #336 — `gh api` semantic bypass in Carson governance enforcement

## Problem

Carson currently has two distinct governance defects.

1. **Workflow defect** — Carson has no legitimate recovery path when a governance-owned baseline check is already red on the default branch. The repair PR is blocked by the very check it is trying to repair.
2. **Enforcement defect** — Carson's command guard blocks shell spellings, not capabilities. Semantic equivalents such as `gh api` can express forbidden GitHub mutations without matching the guard's `gh pr create` and `gh pr merge` patterns.

That produces a predictable causal chain:

baseline-red deadlock → escape hatch → bypass habit → guardrail legitimacy erosion

The system starts with a guard that is meant to protect quality. When the same guard blocks its own repair, users learn a lower-level path. Once the lower-level path becomes normal, Carson's public interface stops being the most trustworthy path through the system.

## Current source surfaces

### `hooks/command-guard`

The hook blocks raw `gh pr create` and `gh pr merge` by shell-text regex. That is sufficient for direct command spellings and insufficient for semantic equivalents expressed through `gh api`.

### `lib/carson/runtime/deliver.rb`

`merge_pr!` owns Carson's current merge operation. `assess_delivery!` and `delivery_assessment` decide whether a delivery is queued or gated. Today those paths have no governed exception for "the baseline check is already red on default branch and this PR repairs it".

### `lib/carson/runtime/govern.rb`

`integrate_delivery!` calls `merge_pr!` through the normal governed merge path. Govern can integrate, revise, or escalate, but it has no recovery mode for a baseline-red governance check that is already failing on the default branch.

### `lib/carson/runtime/audit.rb`

`default_branch_ci_baseline_report` already queries GitHub for the default branch head SHA and its check-runs. This is the key primitive the recovery path needs. The hardest proof requirement — "show that the named governance-owned check is currently red on the default branch" — already exists.

### `lib/carson/adapters/github.rb`

The adapter is Carson's intended `gh` boundary for local runtime flows through `gh_run`. It is a useful place to centralise future GitHub capability checks, but it is not by itself a complete enforcement boundary today.

### `lib/carson/ledger.rb`

The ledger is Carson's existing machine-readable state surface. Recovery should write an explicit audit event here rather than relying on commit-message prose or tribal knowledge.

## Recommended recovery shape

### Use a distinct command surface

Use a separate recovery command with the working name `carson recover`.

Do not hide recovery behind `carson deliver --bootstrap` or another flag on the normal delivery path. Recovery needs higher activation energy than ordinary delivery so that operators consciously choose the exceptional path.

### Verify the baseline failure live

Recovery should call `default_branch_ci_baseline_report` and prove all of the following at merge time:

- the named governance-owned check is red on the default branch
- the proof is tied to the current default-branch SHA
- the PR branch being recovered is the branch Carson is about to merge

Recovery should fail closed when that proof is missing, stale, or names a check outside Carson's governance surface.

### Bypass only one broken governance check

Recovery should bypass only the single broken governance-owned baseline check that is already failing on the default branch.

Every other merge requirement must still pass:

- the rest of the required checks
- the review gate
- any repository-level branch protections that are not part of the named broken governance check

This keeps recovery narrow. The system is not asking "should Carson ignore CI". It is asking "should Carson be allowed to merge the repair for the one governance check that is already broken on the baseline".

### Record a machine-readable audit event

Recovery should record an explicit ledger event containing at least:

- repository
- PR number
- branch
- target check name
- default-branch SHA
- PR SHA
- actor
- timestamp

That record should be queryable after the fact. Recovery is legitimate only if it is auditable.

### Return self-diagnosing refusal messages

When recovery is refused, Carson should explain the exact reason and the next action.

Examples:

- the named check is not red on the default branch
- the named check is not Carson-governed
- another required check is still failing
- the review gate is still blocked
- the proof was collected against an out-of-date default-branch SHA

## Enforcement direction

Do not treat longer regexes as the main fix. That becomes an arms race against shell syntax.

The durable direction is capability-level control so that equivalent GitHub mutations produce the same policy outcome regardless of whether they are expressed as:

- `gh pr merge`
- `gh api`
- any future GitHub CLI surface that can perform the same mutation

The strength order is:

1. **Prevention** — Carson-owned merge primitives and governed interfaces
2. **Detection** — post-action audit or violation recording when a semantic bypass occurs
3. **Credential constraints** — GitHub-side rules that reduce what lower-level calls can do outside Carson

The enforcement defect is separate from the recovery defect. Carson needs both a legitimate recovery path and a stronger capability boundary.

## Non-goals

This design does **not** propose:

- a general bypass for arbitrary product CI failures
- a blessed operator workflow based on `gh api`
- a hidden exemption on `carson deliver`
- a documentation path that teaches agents to step outside Carson first and ask questions later

## Shared test scenarios

These scenarios should appear in the recovery-path issue and the enforcement-gap issue as well.

1. **Allowed** — the default branch has a red governance-owned check, the repair PR fixes it, all other gates are green, and recovery is allowed with an audit record.
2. **Blocked** — the default branch is green, so recovery is refused.
3. **Blocked** — the default branch is red, but the PR is unrelated to the broken governance surface.
4. **Blocked or violation-recorded** — raw `gh pr merge` and equivalent `gh api` merge attempts do not produce different policy outcomes.
5. **Documentation guard** — no Carson artefact presents `gh api` as the normal operator path.
