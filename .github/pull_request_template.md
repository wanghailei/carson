<!-- butler:common:start pull-request-template -->
## Shared Scope and Validation

- [ ] `single_business_intent`: this PR is one coherent domain or feature intent.
- [ ] `single_scope_group`: non-doc files stay within one scope group.
- [ ] `cross-boundary_changes_justified`: any cross-boundary change has explicit rationale.
- [ ] `bin/butler audit` before commit.
- [ ] `bin/butler audit` before push.
- [ ] Required CI checks are passing.
- [ ] At least 60 seconds passed since the last push to allow AI reviewers to post.
- [ ] No unresolved required conversation threads at merge time.
- [ ] `bin/butler review gate` passes with converged snapshots.
- [ ] Every actionable top-level review item has a `Codex:` disposition (`accepted`, `rejected`, `deferred`) with the target review URL.
<!-- butler:common:end pull-request-template -->
