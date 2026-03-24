# GitHub Repository Settings — Carson Working Agreement

Research compiled 2026-03-23, updated 2026-03-24. Sources: GitHub official documentation (docs.github.com), GitHub Community discussions, live API inspection of `wanghailei/carson` and `wanghailei/ai`.

---

## Purpose

When Carson governs a repository, certain GitHub settings must be active for the governance model to work. These settings form a working agreement between Carson and GitHub — Carson assumes they are in place, and `carson onboard` (or `carson refresh`) should configure them automatically via the GitHub API.

---

## 1. Pull Request Merge Settings

Settings → General → Pull Requests section.

| Setting | Carson value | Why | API field |
|---------|-------------|-----|-----------|
| **Allow squash merging** | ON | Carson's configured merge method. One clean commit per PR on main [1] | `allow_squash_merge: true` |
| **Allow merge commits** | OFF | Merge commits create non-linear history. Carson requires linear main [1] | `allow_merge_commit: false` |
| **Allow rebase merging** | ON | INTEGRATION.md defaults to rebase merge. Carson config overrides to squash per repo. Both must be available [1] | `allow_rebase_merge: true` |
| **Squash merge commit title** | `COMMIT_OR_PR_TITLE` | Single-commit PRs use the commit message (preserves author intent); multi-commit PRs use the PR title [2] | `squash_merge_commit_title` |
| **Squash merge commit message** | `COMMIT_MESSAGES` | Preserves individual commit messages in the squash body for traceability [2] | `squash_merge_commit_message` |
| **Allow auto-merge** | ON | See § 3 for full analysis. Enables `gh pr merge --auto` when checks are pending [3] | `allow_auto_merge: true` |
| **Automatically delete head branches** | ON | Prevents stale branch accumulation. Carson's workflow is branch → PR → merge → done. The branch has no purpose after merge. Without this, remote branches accumulate and degrade tooling (Zed, housekeep, refresh) [4] | `delete_branch_on_merge: true` |
| **Allow update branch** | ON | Agents should be able to update PR branches when behind main, without rebasing locally [5] | `allow_update_branch: true` |

**Current state** (both repos): all correct except `allow_update_branch` was not inspectable via the API field used.

---

## 2. Branch Protection — Rulesets

Settings → Rules → Rulesets → `protect-main` (targeting `refs/heads/main`).

### Available Ruleset Rules (complete reference)

GitHub rulesets offer the following rule types for branch targets [6]:

| Rule | Parameters | Carson use |
|------|-----------|------------|
| **Restrict creations** | Pattern matching | Not needed — agents create branches freely |
| **Restrict updates** | Pattern matching | Not needed — agents push to their own branches |
| **Restrict deletions** | Pattern matching | **ON** (default) — main must never be deleted |
| **Require linear history** | Toggle | **ON** — Carson requires linear main |
| **Require deployments to succeed** | Target environments | Not used — no deployment gates |
| **Require signed commits** | Toggle | OFF — not enforced currently |
| **Require a pull request before merging** | See sub-parameters below | **ON** — core governance |
| **Require status checks to pass** | Check names, strict mode | See § 3 (auto-merge analysis) |
| **Block force pushes** | Toggle | **ON** (default) — INTEGRATION.md bans force push |
| **Require code scanning results** | Tool, severity threshold | Not used — no code scanning configured |
| **Require code quality results** | Severity threshold | Not used — Enterprise Cloud only |
| **Restrict file paths** | Path patterns (fnmatch) | Not used |
| **Restrict file path length** | Character limit | Not used |
| **Restrict file extensions** | Extension list | Not used |
| **Restrict file size** | Size limit | Not used |

### Pull Request Rule Sub-Parameters

The "Require a pull request before merging" rule has these parameters [6]:

| Parameter | Carson value | Why |
|-----------|-------------|-----|
| **Required approving review count** | 0 | Agents are primary committers and cannot approve their own PRs. Zero approvals means the PR requirement enforces the branch → PR → merge workflow without blocking on reviews [6] |
| **Dismiss stale reviews on push** | OFF | Not needed with 0 required approvals |
| **Require approval from most recent push** | OFF | Not needed with 0 required approvals |
| **Require code owner review** | OFF | No CODEOWNERS in use |
| **Required review thread resolution** | **ON** | INTEGRATION.md: "Unresolved review threads are blocking." Carson's review sweep enforces this — GitHub should too [7] |
| **Allowed merge methods** | `squash` only | Matches Carson config. Prevents agents from accidentally using the wrong method [1] |
| **Required reviewers** (team-based, file-pattern) | None | Not used |
| **Bypass actors** | None | INTEGRATION.md: "Do not allow bypassing the above settings." Even the admin goes through PRs [7] |

### Recommended Ruleset Configuration

```json
{
	"name": "protect-main",
	"enforcement": "active",
	"target": "branch",
	"conditions": {
		"ref_name": { "include": ["refs/heads/main"], "exclude": [] }
	},
	"bypass_actors": [],
	"rules": [
		{
			"type": "pull_request",
			"parameters": {
				"required_approving_review_count": 0,
				"dismiss_stale_reviews_on_push": false,
				"require_code_owner_review": false,
				"require_last_push_approval": false,
				"required_review_thread_resolution": true,
				"allowed_merge_methods": ["squash"],
				"required_reviewers": []
			}
		},
		{ "type": "required_linear_history" },
		{ "type": "deletion" },
		{ "type": "non_fast_forward" }
	]
}
```

### Current State Audit

**wanghailei/ai** — Ruleset ID `13610710`:

| Rule / Parameter | Current | Target | Status |
|-----------------|---------|--------|--------|
| pull_request | ON | ON | ✓ |
| required_approving_review_count | 0 | 0 | ✓ |
| required_review_thread_resolution | false | true | ✗ change needed |
| allowed_merge_methods | merge, squash, rebase | squash | ✗ change needed |
| required_linear_history | absent | ON | ✗ add |
| deletion (restrict deletions) | ON (default) | ON | ✓ |
| non_fast_forward (block force pushes) | ON (default) | ON | ✓ |

**wanghailei/carson** — Ruleset ID `13610721`:

| Rule / Parameter | Current | Target | Status |
|-----------------|---------|--------|--------|
| pull_request | ON | ON | ✓ |
| required_approving_review_count | 0 | 0 | ✓ |
| required_review_thread_resolution | false | true | ✗ change needed |
| allowed_merge_methods | merge, squash, rebase | squash | ✗ change needed |
| required_linear_history | absent | ON | ✗ add |
| deletion (restrict deletions) | ON (default) | ON | ✓ |
| non_fast_forward (block force pushes) | ON (default) | ON | ✓ |

---

## 3. Auto-Merge Analysis

This section documents the investigation into why PRs on `wanghailei/ai` passed all conditions but did not auto-merge (2026-03-24).

### How Auto-Merge Works

GitHub auto-merge is a per-PR feature that, when enabled, automatically merges the PR once all required conditions are satisfied. It has three layers [3][8]:

1. **Repository setting**: `allow_auto_merge: true` — enables the *capability* for PRs to use auto-merge.
2. **Branch protection**: At least one blocking condition (required review or required status check) must exist — auto-merge needs something to *wait for*.
3. **Per-PR activation**: A user or automation enables auto-merge on a specific PR via the UI button or `gh pr merge --auto`.

### Why It Did Not Work

The "Enable auto-merge" option appears **only on PRs that cannot be merged immediately** [3]. When branch protection enforces required reviews or required status checks, a PR is blocked until those conditions are met — and auto-merge can be armed to fire when they clear.

Both governed repos have:
- `required_approving_review_count: 0` — no reviews needed
- No required status checks configured
- No CI workflows that run on PRs (AI repo) or no required checks in protection rules

**Result**: PRs are immediately mergeable. Auto-merge has nothing to wait for, so the option never appears and `gh pr merge --auto` is a no-op [8][9].

### Rulesets vs Classic Branch Protection (Known Bug)

Even if required checks are added to a *ruleset*, auto-merge may still not work. This is a **known GitHub compatibility issue** [10]:

- Auto-merge logic was built for classic branch protection rules. It reads protection signals that rulesets do not fully surface.
- GitHub engineering is aware but has provided no ETA for a fix [10].
- The issue has persisted since rulesets launched (April 2023) through at least early 2026.
- **Workaround**: Create a classic branch protection rule with the required status check. Rulesets and classic rules stack — GitHub applies the most restrictive combination.

### Recommendation

**For repos without CI** (e.g. `wanghailei/ai`):

Auto-merge is not practical. There are no checks to wait for. Two options:

1. **Accept explicit merge.** Carson's delivery loop already handles merge via `gh pr merge --squash`. Auto-merge is an optimisation Carson does not need — it polls and merges explicitly. This is the simplest path.
2. **Add a trivial CI check.** Create a minimal GitHub Actions workflow that always passes on PRs, then require it in a classic branch protection rule. Auto-merge can then be armed. This adds machinery for marginal benefit.

**Recommended**: option 1. Carson merges explicitly. Auto-merge adds complexity without value when there is nothing to wait for.

**For repos with CI** (e.g. `wanghailei/carson` if CI is added):

1. Add the CI check name as a required status check in a **classic branch protection rule** (not the ruleset, due to the compatibility bug).
2. Carson's delivery loop can then use `gh pr merge --auto --squash` instead of polling.
3. Once GitHub fixes the rulesets compatibility issue, migrate the required check to the ruleset and delete the classic rule.

---

## 4. Legacy Branch Protection

Settings → Branches → Branch protection rules (classic, separate from rulesets).

### Rulesets vs Classic: Which to Use

GitHub recommends rulesets as the successor to classic branch protection [6]. Rulesets offer:
- Layered rules (multiple rulesets on the same branch)
- API-first management
- Bypass actor controls
- More rule types (file restrictions, code scanning)

However, **auto-merge only works reliably with classic branch protection** [10]. This creates a pragmatic split:

| Concern | Mechanism |
|---------|-----------|
| PR requirement, merge methods, thread resolution, linear history | **Ruleset** |
| Required status checks (for auto-merge) | **Classic branch protection** (until GitHub fixes rulesets compatibility) |
| Force push block, deletion block | **Ruleset** (defaults) |

### Current State

**wanghailei/carson** — has classic branch protection:

| Rule | Current | Target | Status |
|------|---------|--------|--------|
| Enforce admins | ON | ON | ✓ |
| Require linear history | ON | Remove (use ruleset) | Migrate |
| Allow force pushes | OFF | Remove (use ruleset) | Migrate |
| Allow deletions | OFF | Remove (use ruleset) | Migrate |
| Required conversation resolution | OFF | Remove (use ruleset) | Migrate |
| Lock branch | OFF | OFF | ✓ |
| Required status checks | None | Add if CI exists | Pending |

**wanghailei/ai** — no classic branch protection (404 from API).

### Migration Plan

1. Configure rulesets fully (thread resolution, squash-only, linear history) — § 2 above.
2. On Carson repo: remove redundant classic rules that overlap with the ruleset (linear history, force push, deletions). Keep only `enforce_admins` and `required_status_checks` if CI exists.
3. On AI repo: no classic rule needed unless CI is added later.

---

## 5. Repository Features

Settings → General → Features section.

| Feature | Carson value | Why |
|---------|-------------|-----|
| **Issues** | ON | Issues are Carson's source of truth for work (INTEGRATION.md § Issues) |
| **Projects** | OFF | Not used. Reduces UI noise |
| **Wiki** | OFF | Documentation lives in the repo (`docs/`, `MANUAL.md`, `README.md`) |
| **Discussions** | OFF | Not used |
| **Pages** | Per repo | AI repo uses Pages for diary site. Carson does not |

**Current state**: both repos correct.

## 6. Security and Analysis

Settings → Code security → Security settings.

| Setting | Carson value | Why |
|---------|-------------|-----|
| **Dependabot alerts** | ON | SECURITY.md: "Audit dependencies for known vulnerabilities" |
| **Dependabot security updates** | ON | Auto-creates PRs for vulnerable dependencies |
| **Secret scanning** | ON | SECURITY.md: "Never commit .env, credentials, API keys, tokens" |
| **Push protection** | ON | Prevents secrets from being pushed in the first place |
| **Dependency graph** | ON | Permanently enabled for all repos; shows dependency tree |

## 7. Actions

Settings → Actions → General.

| Setting | Carson value | Why |
|---------|-------------|-----|
| **Actions permissions** | Allow all | CI workflows and release automation need full Actions access |
| **Fork pull request workflows** | Require approval for first-time contributors | Prevents untrusted code from running CI |

## 8. General Settings

| Setting | Carson value | Why | API field |
|---------|-------------|-----|-----------|
| **Default branch** | `main` | INTEGRATION.md: "Always use main as the default branch name" | `default_branch` |
| **Visibility** | Private (or as needed) | Per repo decision | `visibility` |
| **Allow forking** | OFF for private repos | Prevent uncontrolled forks of governed repos | `allow_forking` |

**Current state**: both repos have `allow_forking: true` — should be OFF for private governed repos.

---

## 9. Summary: Changes Needed

### Both repos — repository settings (API: `PATCH /repos/{owner}/{repo}`)

| Setting | Current | Target |
|---------|---------|--------|
| `allow_forking` | `true` | `false` |

### Both repos — ruleset update (API: `PUT /repos/{owner}/{repo}/rulesets/{id}`)

| Change | Current | Target |
|--------|---------|--------|
| `required_review_thread_resolution` | `false` | `true` |
| `allowed_merge_methods` | `["merge","squash","rebase"]` | `["squash"]` |
| Add `required_linear_history` rule | absent | present |

API payload for ruleset update:

```json
{
	"rules": [
		{
			"type": "pull_request",
			"parameters": {
				"required_approving_review_count": 0,
				"dismiss_stale_reviews_on_push": false,
				"require_code_owner_review": false,
				"require_last_push_approval": false,
				"required_review_thread_resolution": true,
				"allowed_merge_methods": ["squash"],
				"required_reviewers": []
			}
		},
		{ "type": "required_linear_history" },
		{ "type": "deletion" },
		{ "type": "non_fast_forward" }
	]
}
```

### Carson repo only — legacy branch protection cleanup

After ruleset is configured:
- Remove `required_linear_history` from classic rule (now in ruleset)
- Keep `enforce_admins: true` (not available in rulesets)
- Keep classic rule shell for future `required_status_checks` if CI is added

### Auto-merge

No action needed. Carson merges explicitly via its delivery loop. Auto-merge is not functional without required status checks, and adding a trivial check solely for auto-merge adds complexity without value. Revisit if CI is added to repos.

---

## 10. Carson Automation

These settings should be configured automatically by `carson onboard` or `carson refresh` via the GitHub API:

1. **`PATCH /repos/{owner}/{repo}`** — set merge methods, auto-delete, auto-merge, squash commit format, forking
2. **`PUT /repos/{owner}/{repo}/rulesets/{id}`** (or `POST` to create) — set PR requirement, thread resolution, linear history, allowed merge methods, block force pushes
3. **Verify on `carson audit`** — report drift if any setting does not match the expected state

This makes the GitHub settings a Carson-managed contract, not a manual checklist.

---

## Sources

| # | Source | URL |
|---|--------|-----|
| 1 | About merge methods on GitHub | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/about-merge-methods-on-github |
| 2 | Configuring commit squashing for pull requests | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/configuring-commit-squashing-for-pull-requests |
| 3 | Automatically merging a pull request | https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request |
| 4 | Managing the automatic deletion of branches | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-the-automatic-deletion-of-branches |
| 5 | Configuring pull request merges | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges |
| 6 | Available rules for rulesets | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets |
| 7 | About protected branches | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches |
| 8 | Managing auto-merge for pull requests | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-auto-merge-for-pull-requests-in-your-repository |
| 9 | Community: auto-merging doesn't show up even if enabled | https://github.com/orgs/community/discussions/50327 |
| 10 | Community: auto-merge doesn't work with rulesets | https://github.com/orgs/community/discussions/162623 |
| 11 | About rulesets | https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets |
