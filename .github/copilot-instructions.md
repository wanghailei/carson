<!-- butler:common:start copilot-instructions -->
## Shared Governance Baseline

- GitHub rulesets and required checks are merge authority.
- Local Butler is a thin local orchestrator for hook health, main sync, scope integrity, and gh visibility.
- Before commit and before push, run `bin/butler audit`.
- Before merge recommendation, wait at least 60 seconds from the last push for AI reviewers to post, then verify unresolved-thread convergence and require zero unresolved required threads.
- Before merge recommendation, review top-level AI review comments (not only threads), record finding disposition (`accepted`, `rejected`, `deferred`), and post `Codex:` acknowledgement where action or rationale is required.
- Do not treat green checks or `mergeStateStatus: CLEAN` as sufficient if unresolved review threads remain.
- Never suggest destructive operations on protected refs (`main`/`master`, local or remote).
<!-- butler:common:end copilot-instructions -->
