# GitHub Repository Settings — Carson Working Agreement

Research compiled 2026-03-23. Sources: GitHub official documentation (docs.github.com), live API inspection of `wanghailei/carson` and `wanghailei/ai`.

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
| **Allow auto-merge** | ON | Carson's delivery loop polls for merge readiness. Auto-merge lets GitHub merge as soon as checks pass, reducing poll cycles [3] | `allow_auto_merge: true` |
| **Automatically delete head branches** | ON | Prevents stale branch accumulation. Carson's workflow is branch → PR → merge → done. The branch has no purpose after merge. Without this, remote branches accumulate and degrade tooling (Zed, housekeep, refresh) [4] | `delete_branch_on_merge: true` |
| **Allow update branch** | ON | Agents should be able to update PR branches when behind main, without rebasing locally [5] | `allow_update_branch: true` |

**Current state** (both repos): all correct except `allow_update_branch` was not inspectable via the API field used.

## 2. Branch Protection — Ruleset on `main`

Settings → Rules → Rulesets → `protect-main` (targeting `refs/heads/main`).

| Rule | Carson value | Why | Current state |
|------|-------------|-----|---------------|
| **Require pull request before merging** | ON, 0 approvals | Core governance: no direct pushes to main. All changes go through PRs. Zero approvals because agents are the primary committers and cannot approve their own PRs [6] | ON, 0 approvals ✓ |
| **Required review thread resolution** | **ON** (change needed) | INTEGRATION.md: "Unresolved review threads are blocking." Carson's review sweep enforces this — GitHub should too [7] | OFF ✗ |
| **Require linear history** | **ON** (add to ruleset) | Carson requires linear main. Currently enforced via branch protection rule, not the ruleset. Should be in the ruleset for consistency [6] | In branch protection only |
| **Block force pushes** | ON (default) | INTEGRATION.md bans `git push --force` [6] | ON ✓ (via branch protection) |
| **Restrict deletions** | ON (default) | Main must never be deleted [6] | ON ✓ (default) |
| **Allowed merge methods** | `squash` only | Current ruleset allows all three (`merge`, `squash`, `rebase`). Should restrict to `squash` to match Carson config and prevent agents from accidentally using the wrong method [1] | `merge, squash, rebase` ✗ |
| **Dismiss stale reviews on push** | OFF | Not needed with 0 required approvals. Would add friction without value [6] | OFF ✓ |
| **Require code owner review** | OFF | No CODEOWNERS in use. Would block all PRs [6] | OFF ✓ |
| **Bypass actors** | None | INTEGRATION.md: "Do not allow bypassing the above settings." Even the admin should go through PRs [7] | None ✓ |

**Current state**: ruleset exists but is minimal — only requires PR with 0 approvals. Needs thread resolution and squash-only merge method added.

## 3. Branch Protection Rule on `main`

Settings → Branches → Branch protection rules (legacy, separate from rulesets).

| Rule | Carson value | Current state |
|------|-------------|---------------|
| **Enforce admins** | ON | ON ✓ |
| **Require linear history** | ON | ON ✓ |
| **Allow force pushes** | OFF | OFF ✓ |
| **Allow deletions** | OFF | OFF ✓ |
| **Required conversation resolution** | OFF (use ruleset instead) | OFF |
| **Lock branch** | OFF | OFF ✓ |

**Note**: The branch protection rule and the ruleset overlap. GitHub applies the most restrictive combination. The linear history requirement is currently in the branch protection rule; it should also be in the ruleset for a single source of truth. Consider migrating fully to rulesets (GitHub's recommended approach [6]).

## 4. Repository Features

Settings → General → Features section.

| Feature | Carson value | Why |
|---------|-------------|-----|
| **Issues** | ON | Issues are Carson's source of truth for work (INTEGRATION.md § Issues) |
| **Projects** | OFF | Not used. Reduces UI noise |
| **Wiki** | OFF | Documentation lives in the repo (`docs/`, `MANUAL.md`, `README.md`) |
| **Discussions** | OFF | Not used |
| **Pages** | Per repo | AI repo uses Pages for diary site. Carson does not |

**Current state**: both repos correct.

## 5. Security and Analysis

Settings → Code security → Security settings.

| Setting | Carson value | Why |
|---------|-------------|-----|
| **Dependabot alerts** | ON | SECURITY.md: "Audit dependencies for known vulnerabilities" |
| **Dependabot security updates** | ON | Auto-creates PRs for vulnerable dependencies |
| **Secret scanning** | ON | SECURITY.md: "Never commit .env, credentials, API keys, tokens" |
| **Push protection** | ON | Prevents secrets from being pushed in the first place |
| **Dependency graph** | ON | Permanently enabled for all repos; shows dependency tree |

## 6. Actions

Settings → Actions → General.

| Setting | Carson value | Why |
|---------|-------------|-----|
| **Actions permissions** | Allow all | CI workflows and release automation need full Actions access |
| **Fork pull request workflows** | Require approval for first-time contributors | Prevents untrusted code from running CI |

## 7. General Settings

| Setting | Carson value | Why | API field |
|---------|-------------|-----|-----------|
| **Default branch** | `main` | INTEGRATION.md: "Always use main as the default branch name" | `default_branch` |
| **Visibility** | Private (or as needed) | Per repo decision | `visibility` |
| **Allow forking** | OFF for private repos | Prevent uncontrolled forks of governed repos | `allow_forking` |

**Current state**: both repos have `allow_forking: true` — should be OFF for private governed repos.

---

## Summary: Changes Needed

### Both repos — repository settings (API: `PATCH /repos/{owner}/{repo}`)

| Setting | Current | Target |
|---------|---------|--------|
| `allow_forking` | `true` | `false` |

### Both repos — ruleset update (API: `PUT /repos/{owner}/{repo}/rulesets/{id}`)

| Rule | Current | Target |
|------|---------|--------|
| `required_review_thread_resolution` | `false` | `true` |
| `allowed_merge_methods` | `["merge","squash","rebase"]` | `["squash"]` |

### Both repos — ruleset addition

| Rule | Current | Target |
|------|---------|--------|
| `require_linear_history` | not in ruleset | add to ruleset |

### Migration consideration

Consolidate branch protection rules into rulesets. Rulesets are GitHub's recommended approach and support more granular control. The current dual setup (branch protection + ruleset) creates maintenance overhead.

---

## Carson Automation

These settings should be configured automatically by `carson onboard` or `carson refresh` via the GitHub API:

1. **`PATCH /repos/{owner}/{repo}`** — set merge methods, auto-delete, auto-merge, squash commit format, forking
2. **`PUT /repos/{owner}/{repo}/rulesets/{id}`** (or `POST` to create) — set PR requirement, thread resolution, linear history, allowed merge methods, block force pushes
3. **Verify on `carson audit`** — report drift if any setting doesn't match the expected state

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
