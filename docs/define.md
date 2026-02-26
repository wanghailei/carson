# Carson Product Definition

## Product statement
Carson is an outsider governance runtime that keeps repository governance consistent without embedding Carson-owned runtime artefacts inside client repositories.

Named after Carson the head butler of Downton Abbey, Carson embodies the same role for your repositories: you write the code, Carson manages everything else — from commit-time checks through merge-readiness on GitHub to cleaning up your local workspace afterwards. Like a master butler, Carson runs the household with strict discipline and professional standards, but never oversteps — it prepares everything for the merge decision without making it, and keeps the estate (your repositories) in impeccable order without owning it.

## Problem statement
Repository controls degrade when local workflows diverge, review handling is inconsistent, or policy checks are treated as optional. Developers should focus on writing code, not on manually running lint checks, chasing unresolved review comments, keeping templates in sync, or pruning stale branches. Teams need a repeatable governance layer that is strict enough for enterprise stability while remaining operationally practical — one that takes over the entire housekeeping burden so developers never think about it.

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
