## Shared Governance Baseline

- GitHub rulesets and required checks are merge authority.
- Local Butler is a thin local orchestrator for hook health, main sync, scope integrity, and gh visibility.
- Before commit and before push, run `bin/butler audit`.
- Before merge recommendation, run unresolved-thread convergence checks and require zero unresolved required threads.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
