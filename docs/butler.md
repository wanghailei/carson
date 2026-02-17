# Butler

## Purpose

Butler is a shared local governance tool for repository hygiene and merge-readiness support.

Its purpose is to keep local workflows safe, deterministic, and lightweight by:

- enforcing local hard protections before unsafe Git actions can happen,
- keeping local `main` aligned with `github/main`,
- surfacing practical scope-integrity signals for branch hygiene,
- checking and applying shared `.github` template blocks,
- exposing deterministic command outcomes through stable exit statuses.

==Butler blocks unsafe local actions; GitHub remains the merge authority.==

## Scope and Boundaries

In scope:

- local hook installation and health checks,
- local `main` synchronisation and stale branch pruning,
- scope-integrity checks based on branch lane plus changed path groups,
- merge-readiness review gate and scheduled late-review sweep through `gh`,
- shared marker-block template drift detection and application,
- optional repository override loading from `.butler.yml`.

Out of scope:

- replacing GitHub branch protection, rulesets, or required checks,
- deciding merge approval policy on behalf of maintainers,
- auto-merging pull requests,
- broad CI orchestration, retry logic, or network diagnostics,
- repository-specific business policy outside configured local rules.

==`main` is pull-only from GitHub and must not drift through local direct commits.==

## Module Relationships

- `bin/butler`: main runtime, command parser, and all core command implementations.
- `templates/hooks/*`: canonical local hard-protection hooks installed by `bin/butler hook`.
- `templates/common/*`: canonical managed template blocks for `.github` files.
- `templates/project/bin/butler`: consumer-repository bootstrap wrapper, with optional `BUTLER_REF`.
- `script/bootstrap_repo_defaults.sh`: day-0 bootstrap helper for new repositories.
- `script/ci_smoke.sh`: smoke tests for command behaviour and exit-code contract.
- `.github/workflows/review-sweep.yml`: scheduled review sweep every 8 hours.
- `VERSION`: canonical Butler version source.
- `RELEASE.md`: release history and noteworthy changes.
- `docs/common_templates.md`: dedicated template-block behaviour reference.

## Core Flow

1. Bootstrap local protections with `bin/butler hook`.
2. Verify local hard guards with `bin/butler check`.
3. Keep local `main` current using `bin/butler sync`.
4. Remove stale local branches with `bin/butler prune`.
5. Run `bin/butler audit` for local policy status, scope guard, and thin PR/check visibility.
6. Use `bin/butler template check` and `bin/butler template apply` for shared `.github` marker blocks.
7. Run `bin/butler review gate` before merge recommendation.
8. Let scheduled workflow run `bin/butler review sweep` for late actionable review activity.

Exit status contract:

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Feature: Local Hard Protection

Mechanism:

- `hook` copies canonical hooks into `.githooks`, sets executable bit, and writes `core.hooksPath`.
- `check` validates configured hooks path, required hook files, and executable status.
- Symlinked hook files are treated as a hard block.

Key code segments:

- `Butler#hook!` in `bin/butler` writes hook files from `templates/hooks`.
- `Butler#hooks_health_report` in `bin/butler` verifies path, missing hooks, symlinks, and executability.
- `templates/hooks/prepare-commit-msg`, `templates/hooks/pre-merge-commit`, and `templates/hooks/pre-push` implement local branch protections for `main`/`master`.

Boundary:

- Butler prevents unsafe local commit/merge/push paths.
- GitHub remains responsible for server-side protection and merge policy.

## Feature: Main Synchronisation and Branch Hygiene

Mechanism:

- `sync` requires a clean working tree, fetches from remote, fast-forwards local `main`, and checks divergence.
- `prune` fetches with prune, finds local branches whose upstream refs are gone, and attempts safe delete with `git branch -d`.

Key code segments:

- `Butler#sync!` and `Butler#main_sync_counts` in `bin/butler`.
- `Butler#prune!` and `Butler#stale_local_branches` in `bin/butler`.

Boundary:

- Butler performs local maintenance only.
- It does not bypass protected branches and does not force-delete local branches.

## Feature: Scope Integrity Guard

Mechanism:

- Scope is inferred from branch lane (`codex/<lane>/<slug>`) plus changed path groups.
- Docs-only changes pass.
- Mixed non-doc groups, unknown lane, or mismatched lane/group raises attention and split guidance.

Key code segments:

- `ButlerConfig.default_data` in `bin/butler` defines lane-to-group map and path groups.
- `Butler#print_scope_integrity_guard` and `Butler#scope_integrity_status` in `bin/butler` enforce guard behaviour.

Insight:

==Scope integrity is intent- and boundary-based (lane plus path groups), not file-count or line-count based.==

## Feature: PR Visibility, Review Gate, and Scheduled Sweep

Mechanism:

- `audit` calls `gh pr view` and `gh pr checks --required`.
- Reports are written to `tmp/butler/pr_report_latest.md` and `tmp/butler/pr_report_latest.json`.
- If GitHub data is unavailable, Butler marks monitor results as skipped/attention without pretending checks are green.
- `review gate` waits for configured warm-up, polls snapshots until convergence, then blocks on unresolved review threads or missing `Codex:` dispositions for actionable top-level comments/reviews.
- Actionable findings are defined as unresolved threads, any non-author `CHANGES_REQUESTED` review, or non-author comments/reviews with configured risk keywords (`bug`, `security`, `incorrect`, `block`, `fail`, `regression`).
- `review sweep` scans recent open/closed PRs (default 3 days), records late actionable findings, and upserts one rolling tracking issue.
- Review reports are written to `tmp/butler/review_gate_latest.{md,json}` and `tmp/butler/review_sweep_latest.{md,json}`.

Key code segments:

- `Butler#pr_and_check_report`
- `Butler#write_pr_monitor_report`
- `Butler#render_pr_monitor_markdown`
- `Butler#review_gate!`
- `Butler#review_sweep!`
- `Butler#upsert_review_sweep_tracking_issue`

Boundary:

- Butler offers deterministic local governance signals and artefacts.
- Final merge readiness remains a GitHub and human judgement concern.

## Feature: Shared Template Synchronisation

Mechanism:

- Managed `.github` files are synced via explicit marker blocks.
- `template check` reports drift only.
- `template apply` updates managed marker content while preserving repository-specific addendum outside markers.
- Compatibility aliases remain available through `common check` and `common apply`.

Key code segments:

- `Butler#common_result_for_file`
- `Butler#template_check!`
- `Butler#template_apply!`

Related reference:

- `docs/common_templates.md`

## Feature: Configuration Model

Mechanism:

- `.butler.yml` is optional.
- If absent, Butler runs on built-in defaults.
- If present, overrides are deep-merged on top of defaults.
- Configuration keys are validated, with clear configuration errors for missing/blank/invalid structures.
- `review.*` keys control warm-up/poll cadence, sweep window/states, risk keywords, disposition prefix, and rolling issue title/label.

Key code segments:

- `ButlerConfig.load`
- `ButlerConfig.default_data`
- `ButlerConfig.deep_merge`
- `ButlerConfig#validate!`

Boundary:

- Butler supports local override needs.
- It does not require repository-specific configuration to function.

## Feature: Versioning and Release

Mechanism:

- `VERSION` is the canonical version source.
- `bin/butler version` and `bin/butler --version` print the current version.
- Smoke tests verify CLI version output against `VERSION`.
- `RELEASE.md` records release history.

Key code segments:

- `parse_args` in `bin/butler` handles `version` command and flags.
- `read_butler_version!` in `bin/butler` reads and validates `VERSION`.
- version assertions in `script/ci_smoke.sh`.

## Feature: Operational Insights

1. Butler should stay thin and local-first; GitHub is merge authority.
2. Local hard protection is mandatory for `main`/`master` commit, merge, and push paths.
3. `main` update policy is pull-only from GitHub.
4. Branch hygiene is first-class, including stale-branch prune.
5. Scope integrity should trigger split decisions, not arbitrary numeric thresholds.
6. Exit status texts must stay stable and explicit.
7. Runtime baseline is `rbenv` Ruby `>= 4.0`.
8. Template command naming (`template check/apply`) is primary, with `common` aliases kept for compatibility.
9. Review convergence is deterministic and URL-linked dispositions are mandatory for actionable top-level findings.
10. Scheduled sweep catches late review activity after PR close/merge.

## Feature: FAQ

Q: Why enforce local hooks if GitHub already protects `main`?  
A: GitHub protects server-side merges, while hooks prevent unsafe local actions before they become remote issues.

Q: Why does Butler keep `common` aliases if `template` is preferred?  
A: Aliases preserve backward compatibility while consumers migrate to primary `template` commands.

Q: Why can `audit` show attention even when no hard block exists?  
A: Attention indicates non-blocking follow-up (for example scope clarification, lagging `main`, or incomplete `gh` visibility), while hard block remains reserved for policy stops.

Q: What counts as an actionable review finding for `review gate` and `review sweep`?  
A: Unresolved review threads, any non-author `CHANGES_REQUESTED` review, plus non-author comments/reviews containing configured risk keywords.

Q: What must a valid `Codex:` disposition include?  
A: Prefix `Codex:`, one disposition token (`accepted`, `rejected`, `deferred`), and the target review URL.

Q: Why does sweep use one rolling issue instead of one issue per finding?  
A: It keeps follow-up noise low while preserving all current findings in a single tracked place.

Q: Where should repository-specific behaviour be customised?  
A: In optional `.butler.yml` overrides; default operation works without local configuration.

Q: What does exit code `2` mean in practice?  
A: A policy hard stop. Resolve the blocker before commit/push workflows continue.

Q: Where should shared governance defaults be introduced first?  
A: In Butler templates/scripts, then rolled out to consumer repositories through bootstrap/template sync.

## References

- `README.md`
- `RELEASE.md`
- `VERSION`
- `bin/butler`
- `script/bootstrap_repo_defaults.sh`
- `script/ci_smoke.sh`
- `docs/common_templates.md`
- `templates/project/bin/butler`
- `templates/hooks/prepare-commit-msg`
- `templates/hooks/pre-merge-commit`
- `templates/hooks/pre-push`
