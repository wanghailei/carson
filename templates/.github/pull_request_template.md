## Shared Scope and Validation

- [ ] `single_business_intent`: this PR is one coherent domain or feature intent.
- [ ] `single_scope_group`: non-doc files stay within one scope group.
- [ ] `cross-boundary_changes_justified`: any cross-boundary change has explicit rationale.
- [ ] `butler audit` before commit.
- [ ] `butler audit` before push.
- [ ] `gh pr list --state open --limit 50` checked at session start (capture competing active PRs).
- [ ] `gh pr list --state open --limit 50` re-checked immediately before merge decision.
- [ ] Required CI checks are passing.
- [ ] At least 60 seconds passed since the last push to allow AI reviewers to post.
- [ ] No unresolved required conversation threads at merge time.
- [ ] `butler review gate` passes with converged snapshots.
- [ ] Every actionable top-level review item has a `Disposition:` disposition (`accepted`, `rejected`, `deferred`) with the target review URL.
