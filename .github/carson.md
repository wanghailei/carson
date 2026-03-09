# Carson Governance

This repository is governed by [Carson](https://github.com/wanghailei/carson), an autonomous governance runtime. Carson lives on the maintainer's workstation, not inside this repository.

## What Carson Does Not Do

Carson has no `commit`, `push`, or `pr` commands. Use `git` and `gh` for those. Carson audits and governs; you execute.

## Commands

**Before committing:**
```bash
carson audit           # full governance check — run before every commit
carson template check  # detect drift in .github/* managed files, including stale superseded files
carson template apply  # fix drift and remove superseded files
```

**Before recommending merge:**
```bash
carson review gate     # block until actionable review findings are resolved
```

**Branch housekeeping:**
```bash
carson sync            # fast-forward local main from remote
carson prune           # remove stale branches (safer than git branch -d on squash repos)
```

## Exit Codes

- `0` — success
- `1` — runtime or configuration error
- `2` — policy blocked (hard stop; treat as expected failure in CI)

## Governance Rules

- Before commit and before push, run `carson audit`.
- At session start and again immediately before merge recommendation, run `gh pr list --state open --limit 50` and re-confirm active PR priorities.
- Before merge recommendation, run `carson review gate`; it enforces warm-up wait, unresolved-thread convergence, and `Disposition:` acknowledgements for actionable top-level findings.
- Actionable findings are unresolved review threads, any non-author `CHANGES_REQUESTED` review, or non-author comments/reviews with risk keywords (`bug`, `security`, `incorrect`, `block`, `fail`, `regression`).
- `Disposition:` responses must include one token (`accepted`, `rejected`, `deferred`) and the target review URL.
- Scheduled governance runs `carson review sweep` every 8 hours to track late actionable review activity.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
