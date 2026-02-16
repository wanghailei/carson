## Shared Governance Baseline

- GitHub rulesets and required checks are merge authority.
- Local Butler is a thin local orchestrator for hook health, main sync, scope integrity, and gh visibility.
- Before commit and before push, run `bin/butler audit`.
- Before merge recommendation, wait at least 60 seconds for AI reviewers to post, then verify unresolved-thread convergence and require zero unresolved required threads.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
