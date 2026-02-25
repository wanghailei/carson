# Carson Product Definition

## Product statement
Carson is an outsider governance runtime that keeps repository governance consistent without embedding Carson-owned runtime artefacts inside client repositories.

## Problem statement
Repository controls degrade when local workflows diverge, review handling is inconsistent, or policy checks are treated as optional. Teams need a repeatable governance layer that is strict enough for enterprise stability while remaining operationally practical.

## Target outcomes
- Deterministic governance checks for local and CI operation.
- Clear hard-stop behaviour when policy is violated.
- Minimal host-repository footprint with explicit outsider boundaries.
- Predictable onboarding and daily operation for repository maintainers.

## In-scope capabilities
- Local governance commands (`init`, `audit`, `sync`, `prune`, `hook`, `check`, `template`, `review`, `offboard`).
- Review governance via `review gate` and `review sweep`.
- Whole-file management of selected GitHub-native policy files under `.github/*`.
- Strict exit status contract suitable for automation.

## Out-of-scope capabilities
- Replacing GitHub as merge authority.
- Deciding business-domain policy for host repositories.
- Executing force merges or bypassing required checks.
- Persisting Carson-specific configuration inside host repositories.

## Primary users
- Repository maintainers responsible for policy enforcement.
- Internal platform teams operating governance at scale.
- CI owners needing deterministic pass/fail policy signals.

## Success criteria
- New repository can reach governed baseline through one command (`carson init`).
- Daily governance cadence is short and repeatable.
- Policy failures are actionable and deterministic.
- Host repositories remain free of Carson-owned runtime fingerprints.
