## Shared Governance Baseline

- GitHub rulesets and required checks are merge authority.
- Butler runs as an outsider runtime for hook health, main sync, scope integrity, and gh visibility.
- Before commit and before push, run `butler audit`.
- At session start and again immediately before merge recommendation, run `gh pr list --state open --limit 50` and re-confirm active PR priorities.
- Before merge recommendation, run `butler review gate`; it enforces warm-up wait, unresolved-thread convergence, and `Disposition:` dispositions for actionable top-level findings.
- Actionable findings are unresolved review threads, any non-author `CHANGES_REQUESTED` review, or non-author comments/reviews with risk keywords (`bug`, `security`, `incorrect`, `block`, `fail`, `regression`).
- `Disposition:` dispositions must include one token (`accepted`, `rejected`, `deferred`) and the target review URL.
- Scheduled governance runs `butler review sweep` every 8 hours to track late actionable review activity on recent open/closed PRs.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
