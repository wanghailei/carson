# GitHub Repository Settings — Carson Working Agreement

Research compiled 2026-03-23, updated 2026-03-24. Sources: GitHub official documentation (docs.github.com), GitHub Community discussions, live API inspection of `wanghailei/carson` and `wanghailei/ai`. All changes implemented and verified (PIW PR #840).

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

### Current State (verified 2026-03-24)

Both rulesets updated via API. Confirmed by `gh api repos/{owner}/{repo}/rulesets/{id}`.

**wanghailei/ai** — Ruleset ID `13610710`:

| Rule / Parameter | Value | Status |
|-----------------|-------|--------|
| pull_request | ON | ✓ |
| required_approving_review_count | 0 | ✓ |
| required_review_thread_resolution | true | ✓ |
| allowed_merge_methods | squash | ✓ |
| required_linear_history | ON | ✓ |
| deletion (restrict deletions) | ON | ✓ |
| non_fast_forward (block force pushes) | ON | ✓ |

**wanghailei/carson** — Ruleset ID `13610721`:

| Rule / Parameter | Value | Status |
|-----------------|-------|--------|
| pull_request | ON | ✓ |
| required_approving_review_count | 0 | ✓ |
| required_review_thread_resolution | true | ✓ |
| allowed_merge_methods | squash | ✓ |
| required_linear_history | ON | ✓ |
| deletion (restrict deletions) | ON | ✓ |
| non_fast_forward (block force pushes) | ON | ✓ |

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

### Resolution (implemented 2026-03-24)

Both repos now have meaningful CI checks required via classic branch protection. Auto-merge is functional.

**wanghailei/ai** — TAI CI workflow (`.github/workflows/ci.yml`) with 3 jobs:
- `Shellcheck hooks` — all 14 enforcement hooks at error severity
- `Validate configs` — YAML/JSON syntax on lint configs and bundle data
- `Reference integrity` — cross-file reference checks in core/ and skills/ markdown

**wanghailei/carson** — existing CI (`ci.yml`) already had 4 PR jobs:
- `Carson governance` — audit and review gate
- `Lint and guards` — Ruby syntax, indentation, naming guards
- `Unit tests` — full test suite
- `PR canary smoke` — smoke tests

**Classic branch protection** now requires these checks on both repos. Auto-merge waits for CI, then merges automatically. Verified with PIW PR #840 on `wanghailei/ai`: auto-merge armed, 3 checks passed, GitHub merged automatically.

**Caveat**: old PRs created before CI existed have no check runs. GitHub does not retroactively enforce required status checks when no checks have been reported — those PRs can merge without waiting. Only fresh PRs (where CI triggers) are gated.

**Bot reviewers (Copilot, Gemini) cannot trigger auto-merge.** They leave "Comment" reviews, never "Approve" reviews. Bot reviews do not count toward required approvals [3].

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

### Current State (verified 2026-03-24)

**wanghailei/carson** — classic branch protection:

| Rule | Value | Status |
|------|-------|--------|
| Enforce admins | ON | ✓ |
| Required status checks | `Carson governance`, `Lint and guards`, `Unit tests`, `PR canary smoke` | ✓ |
| Require linear history | OFF (migrated to ruleset) | ✓ |
| Allow force pushes | OFF | ✓ |
| Allow deletions | OFF | ✓ |

**wanghailei/ai** — classic branch protection (created 2026-03-24):

| Rule | Value | Status |
|------|-------|--------|
| Enforce admins | ON | ✓ |
| Required status checks | `Shellcheck hooks`, `Validate configs`, `Reference integrity` | ✓ |
| Allow force pushes | OFF | ✓ |
| Allow deletions | OFF | ✓ |

### Migration Status

Rulesets are the primary protection mechanism. Classic branch protection is kept only for:
- `enforce_admins` (not available in rulesets)
- `required_status_checks` (auto-merge requires classic protection, not rulesets — see § 3)

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

## 9. Implementation Status

All changes implemented and verified 2026-03-24.

| Change | Scope | Status |
|--------|-------|--------|
| Rulesets: thread resolution, squash-only, linear history | Both repos | ✓ Done |
| Classic branch protection: required status checks | Both repos | ✓ Done |
| AI repo: TAI CI workflow created | wanghailei/ai | ✓ Done (PR #839) |
| Auto-merge: functional | Both repos | ✓ Verified (PIW PR #840) |

### Remaining

| Change | Scope | Status |
|--------|-------|--------|
| `allow_forking` → `false` | Both repos | Pending |

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
