## Shared Governance Baseline

- GitHub rulesets and required checks are merge authority.
- Local Butler is a thin local orchestrator for hook health, main sync, scope integrity, and gh visibility.
- Before commit and before push, run `bin/butler audit`.
- Before merge recommendation, run `bin/butler review gate`; it enforces warm-up wait, unresolved-thread convergence, and `Codex:` dispositions for actionable top-level findings.
- Actionable findings are unresolved review threads or non-author comments/reviews with risk keywords (`bug`, `security`, `incorrect`, `block`, `fail`, `regression`).
- `Codex:` dispositions must include one token (`accepted`, `rejected`, `deferred`) and the target review URL.
- Scheduled governance runs `bin/butler review sweep` every 8 hours to track late actionable review activity on recent open/closed PRs.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
