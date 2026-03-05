# Carson Release Notes

Release-note scope rule:

- `RELEASE.md` records only version deltas, breaking changes, and migration actions.
- Operational usage guides live in `MANUAL.md` and `API.md`.

## 2.25.0 — Onboard/Offboard UX Improvements

### What changed

- **`carson offboard` now asks for TTY confirmation** before removing files. In non-TTY environments (CI, scripts), offboard proceeds without prompting, preserving backwards compatibility.
- **Offboard prints post-removal guidance** ("commit the removals and push to finalise offboarding") so users know what to do next.
- **Non-TTY `carson onboard` now shows a govern registration hint** ("to register for portfolio governance: carson onboard in a TTY") instead of silently skipping the prompt.
- **`carson setup` shows current values** for workflow style and merge method when re-running, and pre-selects the current choice as the default. Previously only canonical template showed its current value.

## 2.24.0 — Remove Scope Integrity Guard

### What changed

- **Scope integrity guard removed from `carson audit`.** The guard classified changed files into path groups (tool, ui, test, domain, docs) and flagged commits crossing multiple groups. This required maintaining an explicit `scope.path_groups` list in `~/.carson/config.json` that went stale whenever a repository's directory structure changed. The maintenance burden outweighed the value.

### Migration

- The `scope.path_groups` config key is now ignored. Existing configs with this key will not cause errors — the data is silently unused.
- The `path_groups` attribute has been removed from `Carson::Config`. Code referencing `config.path_groups` will raise `NoMethodError`.
- PR template no longer includes `single_scope_group` and `cross-boundary_changes_justified` checklist items. The `single_business_intent` check remains — that is a human-level focus check, not mechanical path classification.

## 2.23.0 — Warm Onboard Welcome Guide

### What changed

- **`carson onboard` closing block rewritten as a warm next-step guide.** Replaces the terse "Carson is ready" message with a concierge-style welcome that explains what Carson placed in `.github/`, why it matters, and what to do before the first push.

## 2.22.0 — Setup Prompts for Canonical Templates

### What changed

- **`carson setup` now prompts for canonical template directory.** The interactive setup flow includes a new prompt to configure `template.canonical`, the directory of `.github/` files synced across governed repos. Shows the current value when one is already set.
- **Audit hints when canonical templates are not configured.** `carson audit` now emits a hint when `template.canonical` is unset, guiding users to run `carson setup`.

## 2.21.0 — Review Sweep Skips Bot Authors

### What changed

- **Review sweep now skips bot-authored findings.** The sweep uses the same `bot_username?` guard as the review gate — comments, reviews, and review thread comments from configured bot usernames are excluded from sweep findings.
- **Default bot usernames populated.** `review.bot_usernames` now ships with `gemini-code-assist[bot]`, `github-actions[bot]`, and `dependabot[bot]`. Previously empty, requiring manual configuration. Override via `CARSON_REVIEW_BOT_USERNAMES` or `~/.carson/config.json`.

## 2.20.0 — Prune Orphan Branches

### What changed

- **`carson prune` now detects orphan branches.** Local branches with no upstream tracking are pruned when GitHub confirms a merged PR matching the exact branch name and tip SHA. Previously, only branches with `[gone]` upstream tracking were detected — branches that were never pushed with `-u` or lost tracking would linger indefinitely.
- Orphan deletions count towards the same "Pruned N stale branches." total in concise output. Verbose output uses distinct `deleted_orphan_branch:` / `skip_orphan_branch:` log lines.
- Carson's own `carson/template-sync` branch and protected branches are excluded from orphan detection.

## 2.19.1 — Remove Dependabot References

### What changed

- Replaced all Dependabot example references in documentation and tests with `labeler.yml`. Carson never had a Dependabot feature — these were illustrative filenames for the canonical template system.

## 2.19.0 — Canonical Templates, Lint Removed

### What changed

- **Lint templates removed from Carson.** `carson-lint.yml` and `.mega-linter.yml` are no longer managed by Carson. Both are now superseded — `carson refresh` will delete them from governed repos automatically. Lint is a personal decision, not a governance decision.
- **New `template.canonical` config key.** Point Carson at a directory of your canonical `.github/` files and Carson syncs them to all governed repos alongside its own governance files. You control the content; Carson handles the delivery.

### Migration

1. Run `carson refresh` in each governed repo. Carson will remove the old lint files automatically.
2. If you want lint, create your own workflow files and set `template.canonical` in `~/.carson/config.json`:

```json
{
  "template": {
    "canonical": "~/AI/LINT"
  }
}
```

That directory mirrors `.github/` structure — for example, `workflows/lint.yml` deploys to `.github/workflows/lint.yml`.

3. Run `carson refresh` again to deploy your canonical files.

## 2.18.0 — Audit Attention Detail

### What changed

- `carson audit` now enumerates what needs attention in concise (non-verbose) output. Previously the user saw only "Audit: attention" with no detail; now each attention source prints a specific line explaining the problem and next step.
- Covers all attention sources: main sync errors, PR/check failures and pending, default branch CI baseline (critical and advisory), and scope integrity warnings.
- Block-level baseline problems also surface concise detail (previously silent in non-verbose mode).

### No migration required

No configuration or workflow changes needed.

## 2.17.3 — Disable DevSkim

### What changed

- Disabled `REPOSITORY_DEVSKIM` in MegaLinter config. DevSkim floods Rails apps with false-positive security warnings (78 warnings on a fresh Rails 8 scaffold).

### No migration required

Run `carson refresh` — the updated template propagates automatically.

## 2.17.2 — Lint Code, Not Prose

### What changed

- Disabled entire `MARKDOWN`, `RST`, and `SPELL` descriptors in MegaLinter config. Carson governs code quality — prose linting is out of scope and creates noise on documentation-heavy repos.
- Removed now-redundant `SPELL_CSPELL` from `DISABLE_LINTERS` (covered by the descriptor-level `SPELL` disable).

### No migration required

Run `carson refresh` — the updated template propagates automatically.

## 2.17.1 — Disable IaC Security Scanners

### What changed

- Disabled `REPOSITORY_CHECKOV` and `REPOSITORY_KICS` in the MegaLinter config template. Both are IaC security scanners that flag Carson's own workflow permissions (`issues: write`, `pull-requests: write`) as overly permissive — but MegaLinter needs these to post PR comments. Same false positive in every governed repo.

### No migration required

Run `carson refresh` — the updated template propagates automatically.

## 2.17.0 — MegaLinter Configuration Template

### What changed

- Added `.mega-linter.yml` as a Carson-managed template, deployed to `.github/.mega-linter.yml` in governed repositories. Previously MegaLinter ran with its own defaults, ignoring project-level configs and producing thousands of false positives.
- **Project configs first**: `LINTER_RULES_PATH: "."` tells MegaLinter to use project-root config files (`.rubocop.yml`, `.eslintrc`, etc.) instead of built-in defaults. Fixes the RuboCop indentation mismatch.
- **Vendor exclusions**: `FILTER_REGEX_EXCLUDE` skips `vendor/`, `node_modules/`, `public/packs`, `public/assets`, `tmp/`, `log/`, and `coverage/`.
- **Noisy linters disabled**: `SPELL_CSPELL` (needs per-project dictionary), `COPYPASTE_JSCPD` (false positives on generated code), `HTML_DJLINT` (designed for Jinja, not ERB).
- Updated `carson-lint.yml` workflow with `MEGALINTER_CONFIG: .github/.mega-linter.yml` to point MegaLinter at the non-default config location.

### Migration

Run `carson refresh` — the new template is applied automatically and propagated to governed repos.

## 2.16.1 — Template Propagation Cleanup Fix

### What changed

- Template propagation now deletes the local `carson/template-sync` branch after worktree cleanup. Previously, the worktree was removed but the local branch it created was left behind in the governed repository, polluting the user's branch list.

### No migration required

Run `carson refresh` — the fix takes effect immediately. Stale `carson/template-sync` branches in governed repos can be removed with `git branch -D carson/template-sync`.

## 2.16.0 — Auto-propagate Template Changes

### What changed

- `carson refresh` now auto-propagates template updates to the remote. When template drift is detected and applied locally, Carson creates a git worktree, writes the updated templates, commits, and pushes — no manual git workflow required.
- **Branch workflow** (default): pushes to `carson/template-sync` and creates (or updates) a PR. Re-running refresh force-pushes updates to the same branch.
- **Trunk workflow**: pushes template changes directly to main.
- The worktree approach ensures zero disturbance to the user's working tree and current branch.
- `carson refresh --all` now surfaces PR URLs and push refs in the per-repo summary line.
- New public `template_sync_result` accessor on `Runtime` for cross-module access to propagation outcomes.

### Migration

No configuration changes needed. Run `carson refresh` — template updates are now automatically pushed upstream.

## 2.15.4 — Lint Workflow Fix

### What changed

- Removed explicit `LINTER_RULES_PATH: .github/linters` from the Carson Lint workflow template. MegaLinter v8 crashes with `ValueError` when the directory does not exist. The path is already MegaLinter's default — omitting it lets MegaLinter use `.github/linters/` when present and silently skip when absent.

### Migration

Run `carson refresh` in governed repositories to pick up the updated workflow.

## 2.15.3 — Initial Commit Guard

### What changed

- `carson audit` and `carson check` now return success in repositories with no commits (HEAD does not exist). Previously, the pre-commit hook called `git rev-parse --abbrev-ref HEAD` which crashed, creating a chicken-and-egg problem that blocked the very first commit.
- Shell hooks (`prepare-commit-msg`, `pre-merge-commit`) now exit cleanly when HEAD is absent, allowing the initial commit without `--no-verify`.

### No migration required

Run `carson prepare` in existing repositories to refresh hooks. No configuration changes needed.

## 2.15.2 — Release Guard

### What changed

- `release.yml` now fails with a clear error if `RELEASE.md` is missing an entry for the version being released. Previously it silently fell back to `"Release $version"`, creating GitHub Releases with no content.
- Recovery path: add the missing `RELEASE.md` entry in a commit, then re-dispatch the release workflow manually via `workflow_dispatch`.

### No migration required

No configuration or workflow changes needed.

## 2.15.1 — Codex Review Fixes

### What changed

- `carson check` now correctly exits 2 for cancelled, errored, or timed-out CI checks. Previously, only `fail`-bucketed checks were treated as failing — all other non-passing states (cancelled, error) fell through to "all passing".
- Pre-push auto-commit now aborts the in-flight push and prints "Push again to include them." Previously the commit was created locally but not included in the push that triggered it.
- `--push-prep` now stages and commits untracked managed files. Previously, new managed files introduced by a gem upgrade were silently omitted.
- `API.md`: `merge.authority` default corrected from `false` to `true` to match the implementation.
- `API.md`: `carson check` added to the Info commands table.
- `docs/develop.md`: Architecture rationale updated — `govern.rb` acknowledged as a known exception to the adapter shell-out rule.
- Test coverage added for `check` bucket classification, `managed_dirty_paths` untracked handling, and CLI dispatch.

### No migration required

No configuration or workflow changes needed.

## 2.15.0 — JIT Auto-Commit on Pre-Push + `carson check`

### What changed

- Pre-push hook now calls `carson template apply --push-prep` automatically. Any uncommitted changes to Carson-managed template files or `.github/linters/` are committed before the push reaches GitHub — no manual `git add` / `git commit` needed after a gem upgrade or `lint policy` run.
- `--push-prep` flag scopes the behaviour to pre-push only; interactive `carson template apply` is unchanged.
- `carson check` command added: wraps `gh pr checks --required`, exits 0 for pending or passing and 2 for failing. Useful for callers that need a clean CI status signal without `gh`'s confusing "Error: Exit code 8" for pending runs.
- CI smoke tests guarded against live audit exit codes with `|| true` so a pending or failing CI run on the default branch does not cause false test failures.

### No migration required

Run `carson prepare` in each governed repo to pick up the updated pre-push hook.

## 2.14.2 — Docs Enrichment

### What changed

- `docs/design.md` enriched with signal system, output design, prompt principles, and vocabulary guide.
- `docs/develop.md` enriched with architecture rationale, new-command walkthrough, and testing approach.

### No migration required

Documentation only. No behavioural changes.

## 2.14.1 — Auto-Refresh on Install

### What changed

- `install.sh` now runs `carson refresh --all` automatically after linking the executable. Template changes (including superseded-file removal) are propagated to all governed repos the moment Carson is upgraded — no manual intervention required.
- If any repo reports issues, a warning is printed; the install itself does not fail.

## 2.14.0 — Superseded File Cleanup on Template Apply

### What changed

- `carson template apply` now automatically removes files that Carson previously managed but has since renamed or replaced. Running `carson template apply` in a governed repo after upgrading to 2.14.0 will delete `.github/carson-instructions.md` without any manual intervention.
- `carson template check` reports superseded files present in the repo as stale, listed with a `— superseded` annotation. Exit code `2` (BLOCK) if any stale files are detected.
- `offboard` also removes superseded files as part of full Carson cleanup.
- `carson.md` updated to reflect the new `template apply` behaviour.

### No migration required

No manual steps needed. Run `carson template apply` — Carson handles the rest.

## 2.13.3 — Rename carson-instructions.md to carson.md

### What changed

- Renamed `.github/carson-instructions.md` → `.github/carson.md` in both the template set and the Carson repo itself. Shorter name, consistent with Carson's naming conventions.
- Enriched `carson.md` content: added Commands section (before committing, before merge, housekeeping), exit codes table, and clearer headings. Governance rules are unchanged.
- Updated agent pointer files: `CLAUDE.md` and `copilot-instructions.md` now point to `AGENTS.md`; `AGENTS.md` points to `carson.md`. One extra level of indirection, zero new files to maintain.

### Migration

In each governed repository, run:

```bash
git rm .github/carson-instructions.md
carson template apply
```

`carson template apply` writes the new `carson.md` and updates the pointer files. The old `carson-instructions.md` must be removed manually — Carson will not delete it automatically.

## 2.13.2 — Docs Refresh

### What changed

- Updated `docs/define.md`: added missing in-scope commands (`govern`, `housekeep`, `refresh --all`, `lint policy`); corrected out-of-scope merge authority statement.
- Updated `docs/plan.md`: corrected test counts, added `prompt.rb` and `runtime_refresh_all_test.rb` to file structure, added `--loop SECONDS` and `refresh --all` to CLI section, updated delivery status.
- Updated `API.md`: added `govern` config schema and environment overrides.

## 2.13.1 — Guided Governance Registration

### What changed

- After `carson onboard`, Carson now prompts to register the repo for portfolio governance (`govern.repos`). Accept to include it in `carson refresh --all` and `carson govern`; decline to skip.
- Improved `refresh --all` guidance when no repos are configured — now directs users to `carson onboard`.

## 2.13.0 — Refresh All + Strip Local Lint Execution

### What changed

- **`carson refresh --all`** refreshes every governed repository in a single command. Iterates `govern.repos`, runs hooks + templates + audit on each, prints a per-repo summary line, and returns non-zero if any repo fails. Verbose mode streams full diagnostics per repo.
- **Removed `lint.command` and `lint.enforcement` config keys.** Local lint execution during `carson audit` has been removed. MegaLinter runs in CI and `carson govern` gates on CI check status — local lint execution was redundant. Carson now focuses on what makes it unique: **policy distribution** via `carson lint policy`. The `lint.policy_source` config key and `carson lint policy --source` command are unchanged.
- **Removed `CARSON_LINT_COMMAND` and `CARSON_LINT_ENFORCEMENT` environment overrides.**
- **Removed lint command and enforcement prompts from `carson setup`.**

### Migration

1. Remove `lint.command` and `lint.enforcement` from `~/.carson/config.json` if present — they are now ignored.
2. Remove `CARSON_LINT_COMMAND` and `CARSON_LINT_ENFORCEMENT` from any CI or shell configuration.
3. If you relied on local lint during audit, run your lint tool directly (e.g. `make lint`, `trunk check`) or let MegaLinter handle it in CI.

## 2.12.0 — Language-Agnostic Lint Policy Distribution + MegaLinter

### What changed

- **Lint policy distribution is now language-agnostic.** `carson lint policy --source <path-or-git-url>` copies all files from the source repo root into the governed repo's `.github/linters/` directory, where MegaLinter auto-discovers them. Works for any linter config: rubocop.yml, biome.json, ruff.toml, .erb-lint.yml, etc.
- **New `lint.command` config key.** Local audit lint is now a single user-configured command (e.g. `"make lint"`, `"trunk check"`, `["ruff", "check"]`). Replaces the old per-language `lint.languages` system entirely.
- **New `lint.enforcement` config key.** `"strict"` (default) blocks on lint failure; `"advisory"` warns but does not block.
- **New `lint.policy_source` config key.** Default: `wanghailei/lint.git`. Sets the default source for lint policy distribution.
- **MegaLinter CI workflow template.** `carson onboard` now installs `.github/workflows/carson-lint.yml`, which runs MegaLinter on PRs and pushes to main.
- **Interactive setup prompts.** `carson setup` now asks for lint command and enforcement mode.
- **Removed `lint.languages`** — all per-language lint configuration, Ruby-specific lint runners, and hardcoded language definitions are gone.
- **Removed `lint setup` subcommand alias** — use `carson lint policy` instead.
- **Removed `--legacy` flag** from `carson lint policy`.
- **Source repo layout simplified** — lint config files live at the source repo root; no `CODING/` subdirectory required.

### Breaking changes

- `lint.languages` config key no longer exists. If your config references it, remove it.
- `carson lint setup` no longer works. Use `carson lint policy --source <path-or-git-url>`.
- Lint policy files are now written to `<repo>/.github/linters/` (not `~/.carson/lint/`).

### What users must do now

1. Upgrade Carson to `2.12.0` and run `carson refresh`.
2. Remove any `lint.languages` entries from your Carson config.
3. Set `lint.command` in your config if you want local lint during audit (e.g. `"make lint"`).
4. Run `carson lint policy --source <your-policy-repo>` to distribute linter configs to `.github/linters/`.

## 2.11.3 — Refine RubyGems Description Tone

### What changed

- **Gemspec** — rewrote summary and description with engineer-professional tone. Factual, concrete, no slogans.

### What users must do now

Nothing. Metadata only.

## 2.11.2 — Improve RubyGems Summary and Description

### What changed

- **Gemspec** — rewrote `summary` and `description` to explain what Carson actually does instead of abstract jargon. Summary: "You write the code, Carson manages everything from commit to merge." Description covers the full loop: lint, review gates, PR triage, agent dispatch, merge, cleanup.

### What users must do now

Nothing. Metadata only.

## 2.11.1 — Document Philosophy, Opinions, and Configurable Defaults

### What changed

- **README.md** — added "Opinions" section stating Carson's five iron-rule principles (outsider boundary, centralised lint, active review, self-diagnosing output, transparent governance).
- **MANUAL.md** — added "Defaults and Why" section: principles recap plus comprehensive reference for all ten configurable defaults with options, rationale, and how to change each one.
- Fixed stale Ruby prerequisite in both files: `>= 4.0` → `>= 3.4`.

### What users must do now

Nothing. Documentation only.

## 2.11.0 — Self-Diagnosing Audit and Duplicate-Remote Prevention

### What changed

- **Audit concise output now names the remote and suggests recovery actions.** "Main sync (origin): ahead by 1 — git fetch origin, or carson setup to switch remote." instead of the opaque "Main sync: ahead by 1 — reset local drift." The remote name is visible; the fix is embedded.
- **Setup warns when multiple remotes share the same URL.** Interactive mode annotates duplicates with `[duplicate]` and prints a warning. Silent mode logs a `duplicate_remotes:` verbose line. URL normalisation treats SSH and HTTPS variants as equal (`git@github.com:user/repo.git` matches `https://github.com/user/repo`).

### What users must do now

1. Upgrade Carson to `2.11.0`.
2. If you have duplicate remotes (e.g. both `origin` and `github` pointing to the same URL), remove the stale one with `git remote remove <name>`.

## 2.10.0 — Lower Ruby Requirement to 3.4

### What changed

- **Minimum Ruby version lowered from 4.0 to 3.4.** Carson uses no Ruby 4.0-specific features. Lowering to 3.4 widens compatibility to the current stable Ruby series while enabling the `it` implicit block parameter.
- **Removed `# frozen_string_literal: true` pragma** from the one file that had it (`lib/carson/policy/ruby/lint.rb`). Ruby 4.0 freezes strings by default; the pragma is unnecessary.
- **Default workflow style now actually `branch` in code.** The 2.9.0 release notes documented this change, but the hooks and config default were not updated. Now fixed: hooks fall back to `branch`, config default is `branch`, and `CARSON_WORKFLOW_STYLE` env override is documented.

### What users must do now

1. Upgrade Carson to `2.10.0`.
2. Ruby 3.4 or later is now sufficient — Ruby 4.0 is no longer required.

## 2.9.0 — Concise UX for All Commands

### What changed

- **Concise output by default.** Every Carson command now prints clean, minimal output — what happened, what needs attention, what to do next. Diagnostic key-value lines are suppressed unless `--verbose` is passed.
- **`--verbose` flag.** Global flag available on all commands. Restores full diagnostic output (same as pre-2.9.0 behaviour). The pre-commit hook runs `carson audit` (no flags) so it automatically gets clean output.
- **Audit concise output.** A healthy audit prints one line (`Audit: ok`). Problems print only actionable summaries (e.g. `Hooks: mismatch — run carson prepare.`).
- **Refresh concise output.** Prints ~5 lines: hooks installed, templates in sync, audit result, done.
- **All other commands.** `prepare`, `inspect`, `offboard`, `template check/apply`, `prune`, `review gate/sweep`, `govern`, `lint setup`, `setup`, and `housekeep` all follow the same concise/verbose pattern.
- **Default workflow style changed from `trunk` to `branch`.** All governed repositories now enforce PR-only merges by default. Direct commits, merge commits, and pushes to protected branches (`main`/`master`) are blocked by hooks unless explicitly opted out.

### What users must do now

1. Upgrade Carson to `2.9.0`.
2. Use `--verbose` when you need full diagnostics (debugging, CI troubleshooting).
3. If you rely on direct commits to main, re-run `carson setup` and choose `trunk`, or set `CARSON_WORKFLOW_STYLE=trunk` in your environment.

### Breaking or removed behaviour

- Default output is now concise. Scripts that parse Carson's key-value diagnostic lines must add `--verbose`.
- Removed `@concise` internal flag (replaced by `--verbose` opt-in pattern).
- Default `workflow.style` changed from `trunk` to `branch`. Repositories that previously relied on the implicit `trunk` default will now block direct commits to protected branches. Escape hatches: run `carson setup` to choose `trunk`, or set `CARSON_WORKFLOW_STYLE=trunk`.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
```

## 2.8.1 — Onboard UX and Install Cleanup

### What changed

- **Concise onboard output.** `carson onboard` now prints a clean 8-line summary instead of verbose internal state (hook paths, template statuses, config lines). Tells users what happened, what needs attention, and what to do next.
- **Graceful handling of fresh repos.** Onboard no longer fails with a fatal error on repositories with no commits yet.
- **Suppressed RubyGems PATH warning.** The misleading `WARNING: You don't have ... in your PATH, gem executables will not run` message from `gem install --user-install` is now suppressed during installation. Carson symlinks the executable to `~/.carson/bin`, making the gem bin directory irrelevant.

### What users must do now

1. Upgrade Carson to `2.8.1`.

### Breaking or removed behaviour

- None.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
```

### Engineering Appendix

#### Modified components

- `lib/carson/runtime.rb` — added `concise?` flag and `with_captured_output` helper for suppressing sub-command detail during onboard.
- `lib/carson/runtime/local.rb` — rewrote `onboard!` to use concise orchestration (`onboard_apply!`), added `onboard_report_remote!` and `onboard_run_audit!` helpers, added `unless concise?` guards to `prepare!` and `template_apply!`.
- `install.sh` — capture `gem install` stderr and filter out RubyGems PATH warning.
- `script/install_global_carson.sh` — same PATH warning suppression.
- `test/runtime_govern_test.rb` — updated onboard output assertions.

#### Public interface and config changes

- No new CLI commands or config keys.
- Exit status contract unchanged.

---

## 2.8.0 — Interactive Setup and Remote Detection

### What changed

- **`carson setup` command.** An interactive quiz that detects git remotes, main branch, workflow style, and merge method. Writes answers to `~/.carson/config.json`. In non-TTY environments, Carson auto-detects settings silently.
- **Auto-triggered on first onboard.** `carson onboard` now launches the setup quiz when no `~/.carson/config.json` exists. Existing users are not affected.
- **Remote renaming removed.** Carson no longer renames `origin` to `github` during onboard. Instead, it detects the existing remote and adapts. This respects the user's repository layout.
- **Default remote changed from `github` to `origin`.** The built-in default `git.remote` is now `origin`, matching the convention of most git hosting providers. Users who previously relied on the `github` default should run `carson setup` or set `git.remote` in config.
- **Post-install message.** `gem install carson` now displays a getting-started guide pointing to `carson onboard`.
- **CI lint fallback simplified.** `lint_target_files_for_pull_request` uses `config.git_remote` directly with a minimal fallback to `origin`.

### What users must do now

1. Upgrade Carson to `2.8.0`.
2. If you relied on the `github` remote default, either rename your remote to `origin` or run `carson setup` to configure `git.remote`.

### Breaking or removed behaviour

- `git.remote` default changed from `github` to `origin`.
- `carson onboard` no longer renames `origin` to `github`.
- The `align_remote_name_for_carson!` method has been removed.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson setup
```

### Engineering Appendix

#### New files

- `lib/carson/runtime/setup.rb` — interactive quiz, remote/branch detection, config persistence.
- `test/runtime_setup_test.rb` — quiz, detection, and config merge tests.

#### Modified components

- `lib/carson/config.rb` — default `git.remote` changed from `"github"` to `"origin"`, added `attr_accessor :git_remote`.
- `lib/carson/runtime.rb` — added `in_stream:` parameter and `@in` attribute.
- `lib/carson/cli.rb` — added `"setup"` command dispatch, updated banner.
- `lib/carson/runtime/local.rb` — replaced `align_remote_name_for_carson!` with `report_detected_remote!`, updated `onboard!` to auto-trigger setup, updated `print_onboarding_guidance`.
- `lib/carson/runtime/audit.rb` — simplified `lint_target_files_for_pull_request` CI fallback.
- `test/runtime_govern_test.rb` — removed `origin` → `github` rename.
- `test/runtime_audit_lint_test.rb` — updated remote name from `github` to `origin`.
- `carson.gemspec` — added `spec.post_install_message`.
- `MANUAL.md` — documented `carson setup`, updated remote default.
- `API.md` — added `setup` command entry.

#### Public interface and config changes

- Added CLI command: `carson setup`.
- Default `git.remote` changed from `"github"` to `"origin"`.
- Runtime constructor accepts `in_stream:` keyword argument.
- Exit status contract unchanged.

---

## 2.7.0 — Documentation and Test Fixes

### What changed

- **Stale command reference fixed.** README.md referenced the pre-2.3.0 command name `carson init` instead of `carson onboard`.
- **Linear history guidance corrected.** API.md and MANUAL.md incorrectly stated that GitHub's "Require linear history" only accepts rebase merges. Both squash and rebase are accepted — only merge commits are rejected.
- **Release notes separated.** The combined 2.6.0 entry has been split into distinct 2.5.0 (agent discovery) and 2.6.0 (squash default) entries.
- **Config default test made hermetic.** `test_config_govern_defaults` now isolates HOME to a temp directory, preventing the developer's local `~/.carson/config.json` from affecting test results.

### What users must do now

1. Upgrade Carson to `2.7.0`.

### Breaking or removed behaviour

- None.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
```

---

## 2.6.0 — Default Squash Merge

### What changed

- **Default merge method changed from `merge` to `squash`.** Squash-to-main keeps history linear: one PR = one commit on main. Every commit on main corresponds to a reviewed, CI-passing unit of work and is individually revertable. This aligns Carson's built-in default with how most teams should run.

### What users must do now

1. Upgrade Carson to `2.6.0`.
2. If you previously set `govern.merge.method` to `"merge"` explicitly in `~/.carson/config.json`, review whether `"squash"` (now the default) is the right choice.

### Breaking or removed behaviour

- `govern.merge.method` default changed from `merge` to `squash`. If your GitHub repository only allows merge commits, set `"govern": { "merge": { "method": "merge" } }` in `~/.carson/config.json`.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
```

### Engineering Appendix

#### Modified components

- `lib/carson/config.rb` — `govern.merge.method` default changed from `"merge"` to `"squash"`.
- `test/runtime_govern_test.rb` — unit test updated for squash default.

#### Verification evidence

- CI passes on PR #78.

---

## 2.5.0 — Agent Discovery Templates

### What changed

- **Agent discovery via managed templates.** Interactive agents (Claude Code, Codex, Copilot) working in Carson-governed repos now discover Carson automatically. A new source-of-truth file `.github/carson-instructions.md` contains the full governance baseline. Agent-specific files (`.github/CLAUDE.md`, `.github/AGENTS.md`, `.github/copilot-instructions.md`) are one-line pointers to it. Zero drift risk — one file to maintain, all agents follow the same reference.
- **Managed template set expanded.** `carson template apply` now writes five files: `carson-instructions.md`, `copilot-instructions.md`, `CLAUDE.md`, `AGENTS.md`, and `pull_request_template.md`.

### What users must do now

1. Upgrade Carson to `2.5.0`.
2. Run `carson prepare` in each governed repository.
3. Run `carson template apply` to write the new managed files.
4. Commit the new `.github/*` files.

### Breaking or removed behaviour

- `.github/copilot-instructions.md` content replaced with a one-line reference. The governance baseline now lives in `.github/carson-instructions.md`.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson prepare
carson template apply
```

### Engineering Appendix

#### New files

- `templates/.github/carson-instructions.md` — governance baseline source of truth.
- `templates/.github/CLAUDE.md` — one-line reference for Claude Code.
- `templates/.github/AGENTS.md` — one-line reference for Codex.

#### Changed files

- `templates/.github/copilot-instructions.md` — replaced full content with one-line reference.

#### Modified components

- `lib/carson/config.rb` — `template.managed_files` expanded to include `carson-instructions.md`, `CLAUDE.md`, and `AGENTS.md`.
- `script/ci_smoke.sh` — offboard removal check updated for new managed files.

#### Public interface and config changes

- `template.managed_files` default expanded from 2 to 5 files.
- Exit status contract unchanged.

#### Verification evidence

- CI passes on PR #77.

---

## 2.4.0 — Agent Skill Injection + Scope Guard Reform

### What changed

- **SKILL.md injected into agent prompts.** Carson now embeds the full SKILL.md content into every dispatched agent work order. Codex and Claude receive Carson governance knowledge without any files inside the governed repository — the outsider principle holds.
- **SKILL.md added.** A new agent interface document covering commands, exit codes, output interpretation, config, and common scenarios. Ships with the gem.
- **Scope integrity guard is advisory only.** The cross-boundary check no longer blocks commits. Commits should be grouped by feature intent, not file type. The scope guard still prints diagnostics but never prevents a commit.
- **App icon.** Added `icon.svg` (⧓ black bowtie mark) with centered display in README.
- **Hooks moved to repo root.** `assets/hooks/` → `hooks/`. The `assets/` directory is removed.

### What users must do now

1. Upgrade Carson to `2.4.0`.
2. Run `carson prepare` in each governed repository.

### Breaking or removed behaviour

- Scope integrity guard no longer hard-blocks commits with multiple core module groups. If you relied on this as a gate, it is now advisory only.
- `assets/` directory removed. Hook templates now live at `hooks/` in the gem root.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson prepare
carson govern --dry-run
```

### Engineering Appendix

#### Modified components

- `lib/carson/adapters/prompt.rb` — reads SKILL.md at build time and wraps it in `<carson_skill>` XML tags in the agent prompt.
- `lib/carson/runtime/audit.rb` — removed `split_required` hard-block escalation; scope guard status capped at `attention`.
- `lib/carson/runtime/local.rb` — hook template path updated from `assets/hooks` to `hooks`.
- `lib/carson/config.rb` — scope path updated from `assets/hooks/**` to `hooks/**`.
- `carson.gemspec` — glob updated, `SKILL.md` and `icon.svg` added to files list.
- `script/ci_smoke.sh` — scope guard smoke test expects advisory exit instead of block.

#### New files

- `SKILL.md` — agent interface document, shipped with the gem.
- `icon.svg` — app icon.

#### Public interface and config changes

- No new CLI commands or config keys.
- Exit status contract unchanged.

#### Verification evidence

- All CI checks pass across PRs #70–#73.

---

## 2.3.0 — Continuous Govern Loop + Brand Badge

### What changed

- Command renames: `init` → `onboard`, `check` → `inspect`, `hook` → `prepare`.
- Configurable workflow style (`trunk` or `branch`) with hook enforcement.
- Review gate UX improvements: bot-aware filtering, warmup wait, convergence polling.
- `carson govern --loop SECONDS` — run the govern cycle continuously with built-in sleep loop. Per-cycle error isolation keeps the daemon alive through transient failures. `Ctrl-C` exits cleanly with a cycle count summary.

### What users must do now

1. Upgrade Carson to `2.3.0`.
2. Run `carson refresh` in each governed repository to update hooks for the new command names.
3. Optionally use `carson govern --loop 300` for unattended continuous governance.

### Breaking or removed behaviour

- Commands `init`, `check`, and `hook` have been renamed to `onboard`, `inspect`, and `prepare` respectively.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson refresh ~/Dev/your-project
carson govern --dry-run
```

### Engineering Appendix

#### Modified components

- `lib/carson/cli.rb` — added `--loop SECONDS` to govern parser, banner, and dispatch.
- `lib/carson/runtime/govern.rb` — extracted `govern_cycle!`, added `govern_loop!` with per-cycle error isolation and `Interrupt` handling.

#### Public interface and config changes

- Added CLI flag: `--loop SECONDS` for `carson govern`.
- No new config keys. The loop interval is a runtime argument, not a persistent preference.
- Exit status contract unchanged.

#### Verification evidence

- All govern unit tests pass including 4 new loop CLI tests.

---

## 2.1.0 — Enriched Agent Work Orders

### What changed

- Agent work orders now include structured evidence instead of just the PR title. Before dispatching a coding agent, Carson gathers CI failure logs or review comment bodies and includes them in the work order so the agent can act on real context.
- Configurable check wait (`govern.check_wait`, default 30 seconds). When PR checks are still pending and the PR was recently updated, Carson skips it instead of prematurely dispatching a fix — giving GitHub bots and CI time to post results.
- Shared prompt module extracted from Codex/Claude adapters. Both adapters now use `Adapters::Prompt` with structured XML context tags.
- Developer documentation updated with an ASCII flow diagram of the autonomous governance loop.

### Evidence gathering detail

- `fix_ci` objectives: Carson fetches the most recent failed CI run via `gh run list --status failure`, then retrieves failure logs via `gh run view --log-failed`. The tail of the log (up to 8,000 chars) is included in the work order.
- `address_review` objectives: Carson fetches unresolved review threads and actionable top-level findings via GraphQL, and includes each finding's body text (up to 2,000 chars each).
- Re-dispatch: if a prior dispatch for the same PR failed, the previous attempt summary is included so the agent can avoid repeating the same approach.
- Graceful degradation: if evidence gathering fails, the agent receives the PR title and is told to investigate locally.

### What users must do now

1. Upgrade Carson to `2.1.0`.
2. Optionally tune `govern.check_wait` in `~/.carson/config.json` or via `CARSON_GOVERN_CHECK_WAIT`.

### Breaking or removed behaviour

- None. The `context` field on `WorkOrder` is backward compatible — String values are still accepted.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson govern --dry-run
```

### Engineering Appendix

#### New components

- `lib/carson/adapters/prompt.rb` — shared prompt builder module with structured XML context tags.

#### Modified components

- `lib/carson/runtime/govern.rb` — evidence methods (`evidence`, `ci_evidence`, `review_evidence`, `prior_attempt`, `truncate_log`), check wait logic (`within_check_wait?`, `TRIAGE_PENDING`), `updatedAt` added to `gh pr list` fields.
- `lib/carson/config.rb` — added `govern.check_wait` (integer, seconds, default 30).
- `lib/carson/adapters/codex.rb`, `lib/carson/adapters/claude.rb` — now include `Prompt` module, removed duplicate `build_prompt`/`sanitize`.
- `lib/carson/adapters/agent.rb` — updated `context` field documentation for Hash shapes.
- `docs/develop.md` — added autonomous governance loop section with ASCII diagram.

#### Public interface and config changes

- Added config key: `govern.check_wait` (integer, seconds, default 30).
- Added env override: `CARSON_GOVERN_CHECK_WAIT`.
- Exit status contract unchanged.

#### Verification evidence

- 37 govern unit tests pass (18 new, 0 regressions).
- CI smoke tests pass.

---

## 2.0.0 — Autonomous Governance

### Architectural shift

Carson 2.0.0 is an architectural change. Prior versions were a passive governance tool: Carson checked, reported, and blocked — but you still had to triage PRs, dispatch fixes, click merge, and clean up. Across a portfolio of repositories with coding agents producing many PRs, you were the bottleneck.

Carson is now an autonomous governance runtime. `carson govern` is a portfolio-level triage loop that scans every governed repository, classifies each open PR by CI/review/audit status, and acts: merge what's ready, dispatch a coding agent (Codex or Claude) to fix what's failing, and escalate what needs human judgement. After merging, it housekeeps — syncing main and pruning stale branches.

The per-commit governance (audit, lint, review gate, scope integrity) is unchanged. What's new is the layer above: Carson now orchestrates the full lifecycle from PR to merge to cleanup.

### What changed

- `carson govern [--dry-run] [--json]` — portfolio-level PR triage loop.
- `carson housekeep` — standalone sync + prune for post-merge cleanup.
- Agent dispatch adapters for Codex and Claude CLIs, with work-order/result contracts and dispatch state tracking at `~/.carson/govern/dispatch_state.json`.
- `govern` configuration section: repo list, merge authority/method, agent provider selection.
- Merge authority is on by default — Carson merges ready PRs autonomously.
- `.rubocop.yml` removed from repository; lint config now lives at `~/.carson/lint/rubocop.yml` per Carson's own policy.

### What users must do now

1. Upgrade Carson to `2.0.0`.
2. Run `carson refresh` in each governed repository to update hooks.
3. Optionally configure `govern.repos` in `~/.carson/config.json` to enable multi-repo portfolio mode.
4. Run `carson govern --dry-run` to see what Carson would do across your portfolio.

### Breaking or removed behaviour

- `.rubocop.yml` is no longer in the repository. All repos use `~/.carson/lint/rubocop.yml`.

### Upgrade steps

```bash
cd ~/Dev/carson
git pull
bash install.sh
carson version
carson refresh ~/Dev/your-project
carson govern --dry-run
```

### Engineering Appendix

#### New components

- `lib/carson/runtime/govern.rb` — portfolio triage loop, PR classification, merge, housekeep orchestration.
- `lib/carson/adapters/agent.rb` — work-order/result data contracts (`WorkOrder`, `Result`).
- `lib/carson/adapters/codex.rb` — Codex CLI adapter via `Open3.capture3`.
- `lib/carson/adapters/claude.rb` — Claude CLI adapter via `Open3.capture3`.

#### Decision tree

For each open PR in each governed repo: CI green? Review gate pass? Audit pass? All yes → merge + housekeep. CI failing → dispatch agent. Review blocked → dispatch agent. Other → escalate.

#### Public interface and config changes

- Added CLI commands: `govern [--dry-run] [--json]`, `housekeep`.
- Added config section: `govern.repos`, `govern.merge.authority` (default: `true`), `govern.merge.method`, `govern.agent.provider`, `govern.dispatch_state_path`.
- Added env overrides: `CARSON_GOVERN_REPOS`, `CARSON_GOVERN_MERGE_AUTHORITY`, `CARSON_GOVERN_MERGE_METHOD`, `CARSON_GOVERN_AGENT_PROVIDER`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- 87 unit tests pass (19 new govern tests, 0 regressions).
- 60 smoke tests pass (6 new govern/housekeep tests).

---

## 1.1.0

### User Overview

#### What changed

- All Carson home-directory paths consolidated under `~/.carson/`:
  - Lint policy files: `~/AI/CODING/` moved to `~/.carson/lint/`.
  - Audit reports and cache: `~/.cache/carson/` moved to `~/.carson/cache/`.
  - Launcher symlink: `~/.local/bin/carson` moved to `~/.carson/bin/carson`.

#### Why users should care

- Carson now uses a single top-level directory (`~/.carson/`) for all state. Uninstalling is `rm -rf ~/.carson` plus `gem uninstall carson`.
- No more scattered paths across `~/.cache`, `~/.local/bin`, and `~/AI`.

#### What users must do now

1. Upgrade Carson to `1.1.0`.
2. Update PATH: replace `~/.local/bin` with `~/.carson/bin` in your shell profile.
3. Rerun `carson lint setup --source <path-or-git-url> --force` to populate `~/.carson/lint/`.
4. Optionally clean up old paths: `rm -rf ~/.cache/carson ~/AI/CODING ~/.local/bin/carson`.

#### Breaking or removed behaviour

- `~/AI/CODING/` is no longer the default lint policy directory.
- `~/.cache/carson/` is no longer the default report output directory.
- `~/.local/bin/carson` is no longer the default launcher symlink location.
- Users with custom `lint.languages` entries in `~/.carson/config.json` pointing to `~/AI/CODING/` must update those paths.

#### Upgrade steps

```bash
gem install --user-install carson -v 1.1.0
mkdir -p ~/.carson/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.carson/bin/carson
export PATH="$HOME/.carson/bin:$PATH"
$HOME/.carson/bin/carson version
$HOME/.carson/bin/carson lint setup --source /path/to/your-policy-repo --force
```

Add the `PATH` export to your shell profile so it persists across sessions.

---

## 1.0.0 (2026-02-25)

### User Overview

#### What changed

- Ruby lint policy path is now flat: source `CODING/rubocop.yml`, runtime `~/AI/CODING/rubocop.yml`.
- Ruby lint execution now runs through Carson-owned runtime code (`lib/carson/policy/ruby/lint.rb`).
- `carson audit` now hard-blocks outsider repositories that include repo-local `.rubocop.yml`.
- Default non-Ruby lint policy entries remain present but disabled, and use flat file names (`javascript.lint.js`, `css.lint.js`, `html.lint.js`, `erb.lint.rb`).
- Carson governance workflows now install a pinned RuboCop version before audit execution.

#### Why users should care

- Policy ownership is explicit: `~/AI/CODING` stores policy data, while Carson owns execution logic.
- A flat policy layout removes language-subdirectory drift and simplifies setup.
- Repo-local RuboCop policy overrides are now blocked to keep governance deterministic.

#### What users must do now

1. Upgrade Carson to `1.0.0`.
2. Ensure your policy source provides `CODING/rubocop.yml` and rerun `carson lint setup --source <path-or-git-url> --force`.
3. Remove repo-local `.rubocop.yml` files from governed repositories.
4. If you use Carson reusable workflow pins, set `carson_ref: v1.0.0`, `carson_version: 1.0.0`, and `rubocop_version`.

#### Breaking or removed behaviour

- Carson no longer uses `CODING/ruby/rubocop.yml` as the default Ruby policy source path.
- Carson no longer defaults non-Ruby policy paths to language subdirectories under `CODING/`.

#### Upgrade steps

```bash
gem install --user-install carson -v 1.0.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
carson lint setup --source /path/to/ai-policy-repo --force
```

### Engineering Appendix

#### Public interface and config changes

- Default Ruby lint `config_files` path changed to `~/AI/CODING/rubocop.yml`.
- Default Ruby lint `command` now invokes Carson-owned runner code.
- Default non-Ruby lint policy paths now use flat file names under `~/AI/CODING/`.
- `carson audit` now blocks repo-local `.rubocop.yml` in outsider mode.
- Exit status contract remains unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- Ruby unit suite passed on Ruby `4.0.1` (`41 runs, 126 assertions, 0 failures`).
- Carson smoke suite passed on Ruby `4.0.1` (`Carson smoke tests passed.`).

## 0.8.0 (2026-02-25)

### User Overview

#### What changed

- Added config-driven multi-language lint governance via `lint.languages` in `~/.carson/config.json`.
- Added `carson lint setup --source <path-or-git-url> [--ref <git-ref>] [--force]` to seed `~/AI/CODING`.
- `carson audit` now enforces custom lint policy deterministically for staged/local and CI target files.
- Updated CI workflows to bootstrap lint policy from `wanghailei/ai` using `CARSON_READ_TOKEN`.
- Added CI naming guard to block legacy pre-rename token reintroduction outside historical release notes.

#### Why users should care

- Your own lint policy source (`~/AI/CODING`) is now enforced in both local hooks and GitHub checks.
- Drift between developer environments and CI lint behaviour is reduced by explicit setup and policy checks.
- Missing lint tools, missing policy files, or lint violations now stop merge-readiness with deterministic exits.

#### What users must do now

1. Upgrade Carson to `0.8.0`.
2. Run `carson lint setup --source <path-or-git-url>` on each machine that runs Carson locally.
3. Add `CARSON_READ_TOKEN` repository secret where CI calls Carson reusable workflow.
4. Update CI pins to `carson_ref: v0.8.0` and `carson_version: 0.8.0`.

#### Breaking or removed behaviour

- `carson audit` now hard-blocks when configured language lint command/tool is unavailable for targeted files.
- `carson audit` now hard-blocks when configured lint policy files are missing for targeted files.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.8.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
carson lint setup --source /path/to/ai-policy-repo
```

### Engineering Appendix

#### Public interface and config changes

- Added CLI command: `carson lint setup`.
- Added config schema section: `lint.languages`.
- Audit target selection precedence added for local, PR CI, and non-PR CI.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- Added unit coverage for lint config parsing, lint audit policy states, and lint setup source modes.
- Extended smoke coverage for lint setup (`--source` required, local source, git URL source).
- Extended smoke coverage for audit blocks on missing lint policy files and missing lint commands.

## 0.7.0 (2026-02-24)

### User Overview

#### What changed

- Removed marker-token content scanning from outsider boundary checks.
- Outsider boundary checks now target only explicit Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson`).
- Cleaned historical wording from documentation, smoke labels, and test fixtures.
- Clarified `github` as the canonical git remote name in onboarding guidance.
- Updated user-facing install and CI pin examples to `0.7.0`.

#### Why users should care

- Boundary enforcement is simpler and easier to reason about.
- Operational guidance now reflects configurable remote naming via `git.remote`.
- Install/pin examples now match the current Carson baseline.

#### What users must do now

1. Upgrade to `0.7.0` where Carson is pinned.
2. If you use a custom remote name, align Carson `git.remote` with that remote.
3. Update CI `carson_version` and `carson_ref` pins to `0.7.0` / `v0.7.0`.

#### Breaking or removed behaviour

- Marker-token content no longer contributes to outsider boundary policy blocks.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.7.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- Outsider boundary scan now checks explicit artefact paths only.

#### Verification evidence

- PR #44 merged with green required checks (`Carson governance`, `Syntax and smoke tests`).

## 0.6.1 (2026-02-24)

### User Overview

#### What changed

- Removed branch-name scope enforcement from commit-time governance and kept scope integrity path-group based.
- Improved hook-upgrade diagnostics and installer guidance when repositories are still pinned to an older Carson hooks path.
- Fixed scope guard conflict reporting so `violating_files` only lists true cross-core conflicts.
- Updated user-facing install/pin examples to `0.6.1`.

#### Why users should care

- Branch names are now informational only for scope checks, so commits are governed by actual feature/module path boundaries.
- Hook upgrade failure modes are easier to diagnose and fix locally.
- Scope integrity output is less noisy and more actionable.

#### What users must do now

1. Upgrade to `0.6.1` where Carson is pinned.
2. Re-run `carson prepare` in governed repositories after upgrade.
3. Update CI `carson_version` pins to `0.6.1`.

#### Breaking or removed behaviour

- `CARSON_SCOPE_BRANCH_PATTERN` override support has been removed.
- `scope.branch_pattern` and `scope.lane_group_map` config keys are no longer consumed.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.6.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- Scope policy is now strictly changed-path based; branch-pattern controls are removed.
- Review acknowledgement and style overrides remain:
  `CARSON_REVIEW_DISPOSITION_PREFIX`, `CARSON_RUBY_INDENTATION`.

#### Verification evidence

- PR #40 merged with green required checks (`Carson policy`, `Syntax and smoke tests`).
- PR #41 merged with green required checks (`Carson policy`, `Syntax and smoke tests`).

## 0.6.0 (2026-02-23)

### User Overview

#### What changed

- Refactored runtime concerns from `*Ops` naming to neutral modules (`Local`, `Audit`, `Review`), and split review governance internals into dedicated support files.
- Added global user configuration loading from `~/.carson/config.json` with deterministic precedence:
  built-in defaults, then global config file, then environment overrides.
- Removed branch-name scope policy coupling; scope integrity now evaluates changed paths only (via `scope.path_groups`).
- Changed default review acknowledgement prefix from `Codex:` to `Disposition:`.
- Added Ruby stdlib unit tests for deterministic helper logic and integrated them in CI.
- Replaced static indentation regex checks with policy-based guard script (`script/ruby_indentation_guard.rb`).
- Hardened untracked/quoted-path handling.
- Added internal developer documentation for `~/.carson/config.json`.

#### Why users should care

- Carson is now more neutral and less coupled to a single agent naming workflow.
- User-space configuration is now explicit and predictable without adding repo-local Carson files.
- Review governance and helper logic are easier to maintain and reason about.
- CI catches deterministic logic regressions earlier through added unit tests.

#### What users must do now

1. Upgrade to `0.6.0` where you pin Carson explicitly.
2. If you relied on `Codex:` acknowledgement comments, set `CARSON_REVIEW_DISPOSITION_PREFIX=Codex:` (or `review.required_disposition_prefix` in `~/.carson/config.json`).

#### Breaking or removed behaviour

- Branch-name policy matching has been removed; branch names are informational only.
- Default review acknowledgement prefix no longer assumes `Codex:`.
- Internal planning document removed from the repository.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.6.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- CLI command surface unchanged.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.
- New canonical global config path: `~/.carson/config.json`.
- New path override env var: `CARSON_CONFIG_FILE`.
- Added policy env overrides:
  `CARSON_REVIEW_DISPOSITION_PREFIX`, `CARSON_RUBY_INDENTATION`.
- Style policy supports `tabs`, `spaces`, or `either` through configuration.

#### Verification evidence

- PR #37 merged with both CI jobs green (`Carson governance`, `Syntax and smoke tests`).
- Unit tests run in CI via `ruby -Itest -e 'Dir.glob( "test/**/*_test.rb" ).sort.each { |path| require File.expand_path( path ) }'`.

## 0.5.1 (2026-02-22)

### User Overview

#### What changed

- Fixed source installer behaviour so running `./install.sh` no longer leaves `carson-<version>.gem` in the Carson repository root.
- Updated user-facing install and pin examples to `0.5.1`.

#### Why users should care

- Source installation now leaves Carson checkouts clean after install.
- Version guidance in onboarding docs now matches the latest published patch release.

#### What users must do now

1. Upgrade to `0.5.1` where you pin Carson explicitly.
2. No migration is required for existing `0.5.0` runtime/governance behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.5.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- No CLI, config schema, or exit-contract changes.

#### Verification evidence

- Installer behaviour corrected by PR #32 (`install.sh` temporary gem handling).

## 0.5.0 (2026-02-21)

### User Overview

#### What changed

- Added one-command source installer: `./install.sh`.
- Split installation guidance into public user and internal developer tracks.
- Added internal planning document for Carson rollout.
- Stabilised review sweep smoke fixtures with relative timestamps to remove date drift failures.

#### Why users should care

- Source-based onboarding is now a single command.
- Installation paths are clearer for end users versus contributors.
- Governance smoke coverage is more stable over time.

#### What users must do now

1. For source-based onboarding, run `./install.sh`.
2. For gem-based onboarding, pin and install `carson` at `0.5.0`.
3. No migration is required for existing `0.4.0` policy/runtime behaviour.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.5.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- Added `install.sh` as a source-install entrypoint.
- No CLI command-surface changes.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy blocked.

#### Verification evidence

- `script/review_smoke.sh` now uses relative fixture timestamps for sweep-window stability.

## 0.4.0 (2026-02-18)

### User Overview

#### What changed

- Added repository retirement command: `carson offboard [repo_path]`.
- `offboard` now removes Carson-managed host artefacts and Carson-specific files from client repositories.
- `offboard` unsets repo `core.hooksPath` only when it points to Carson-managed global hook paths.

#### Why users should care

- Retiring Carson from a repository is now one command.
- Re-onboarding with a newer Carson release is cleaner after explicit offboarding.

#### What users must do now

1. Use `carson offboard /local/path/of/repo` when removing Carson from a repository.
2. Re-run `carson onboard /local/path/of/repo` when re-onboarding later.

#### Breaking or removed behaviour

- None.

#### Upgrade steps

```bash
gem install carson
carson version
```

### Engineering Appendix

#### Public interface and config changes

- Added command `offboard [repo_path]` to CLI surface.
- Added runtime methods `offboard!`, `disable_carson_hooks_path!`, `offboard_cleanup_targets`, and `remove_empty_offboard_directories!`.

#### Verification evidence

- CI smoke coverage includes `offboard` cleanup and idempotency checks.

## 0.3.2 (2026-02-18)

### User Overview

#### What changed

- Version baseline bumped to `0.3.2` ahead of offboard command implementation.

## 0.3.1 (2026-02-18)

### User Overview

#### What changed

- Renamed Carson gem package from `carson-governance` to `carson` (CLI command remains `carson`).
- Removed an extra CLI alias command.
- Renamed reusable workflow to `.github/workflows/carson_policy.yml`.
- Removed report output environment override `CARSON_REPORT_DIR`.
- Report output is standardised to `~/.cache/carson` when `HOME` is valid.
- Added safe fallback to `/tmp/carson` when `HOME` is missing, empty, non-absolute, or otherwise invalid.
- Reduced duplication in CI smoke helper wiring (`run_carson_with_mock_gh` now delegates to `run_carson`).

#### Why users should care

- Report path behaviour is now deterministic without extra per-run configuration.
- Misconfigured CI/container `HOME` values no longer break report generation.

#### What users must do now

1. Install using gem package name `carson` (not `carson-governance`).
2. Use reusable workflow path `.github/workflows/carson_policy.yml` in client repository CI.
3. Stop setting `CARSON_REPORT_DIR` in local scripts and CI jobs.
4. Read reports from `~/.cache/carson` in normal environments.
5. If running with unusual environment setup, ensure `HOME` is writable and absolute.

#### Breaking or removed behaviour

- `CARSON_REPORT_DIR` is no longer recognised.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.3.1
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If `HOME` is invalid for cache path resolution, Carson falls back to `/tmp/carson`.

### Engineering Appendix

#### Public interface and config changes

- Removed `CARSON_REPORT_DIR` handling from runtime configuration.
- `report_dir_path` now resolves to `~/.cache/carson` and falls back to `/tmp/carson` for invalid `HOME`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Replace any `CARSON_REPORT_DIR=...` usage with `HOME=...` test isolation where needed.

#### Verification evidence

- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).

## 0.3.0 (2026-02-17)

### User Overview

#### What changed

- Added one-command initialisation: `carson onboard [repo_path]` (`hook` + `template apply` + `audit`).
- Default report output moved to `~/.cache/carson`.
- Outsider boundary now hard-blocks Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson/*`).
- Installation/setup guidance now targets standard-user package-consumer flow.

#### Why users should care

- Faster setup for new repositories.
- Clearer outsider boundary between Carson runtime and client repositories.
- More predictable report output location for automation and CI.

#### What users must do now

1. Install Carson as a normal user executable (`carson` in `PATH`).
2. Initialise each repository with `carson onboard /local/path/of/repo`.
3. Remove forbidden Carson-owned artefacts from host repositories if reported.
4. Read reports from `~/.cache/carson`.

#### Breaking or removed behaviour

- Host `.carson.yml` is no longer accepted.
- Host `bin/carson` and `.tools/carson/*` are no longer accepted.
- Carson repository no longer relies on local `bin/carson` shim for normal usage.
- Command `run [repo_path]` has been removed; use `init [repo_path]`.

#### Upgrade steps

```bash
gem install --user-install carson -v 0.3.0
mkdir -p ~/.local/bin
ln -sf "$(ruby -e 'print Gem.user_dir')/bin/carson" ~/.local/bin/carson
carson version

carson onboard /local/path/of/repo
carson audit
```

#### Known limits and safe fallback

- If `gh` metadata is unavailable, audit/review features degrade to skip/attention states.
- If the default cache path is restricted, run Carson with a writable `HOME`.

### Engineering Appendix

#### Architecture changes

- CLI now dispatches directly to runtime behaviour methods; thin `lib/carson/commands/*` wrappers are removed.
- Runtime split into behaviour-owned concern files:
  - `lib/carson/runtime/local_ops.rb`
  - `lib/carson/runtime/audit_ops.rb`
  - `lib/carson/runtime/review_ops.rb`
- `lib/carson/runtime.rb` now focuses on wiring and shared helpers.

#### Public interface and config changes

- Command surface is `audit`, `sync`, `prune`, `prepare`, `inspect`, `onboard`, `template`, `review`, `version`.
- Initialisation command: `init [repo_path]` (no `run` alias).
- Default report output: `~/.cache/carson`.
- Exit status contract unchanged: `0` OK, `1` runtime/configuration error, `2` policy block.

#### Migration notes

- Update automation expecting repo-local `tmp/carson` to `~/.cache/carson`.
- Remove any Carson-owned host artefacts from client repositories.

#### Verification evidence

- Ruby syntax checks pass across Carson Ruby source files.
- Smoke coverage passes via `script/ci_smoke.sh` (including review smoke path).
- Installed-tool dogfooding path verified on local Carson repository clone.

#### Residual risk and follow-up

- `lib/carson/runtime/review_ops.rb` remains large because it contains both orchestration and GitHub response normalisation; further split by helper clusters is possible in later releases.

## 0.2.0 (2026-02-17)

### Added

- Ruby gem scaffolding (`carson.gemspec`, `lib/`, `exe/carson`) for outsider runtime delivery.
- Modular command and adapter structure under `lib/carson/commands/*` and `lib/carson/adapters/*`.
- Reusable policy workflow (current path: `.github/workflows/carson_policy.yml`) with exact version input.
- Outsider boundary enforcement that blocks Carson-owned artefacts in host repositories.

### Changed

- Runtime now uses built-in configuration only; host `.carson.yml` is no longer accepted.
- Hook runtime moved to global path `~/.carson/hooks/<version>/` with repo `core.hooksPath` pointing there.
- Template synchronisation now uses whole-file comparison and full-file apply for managed `.github/*`.
- Canonical template source moved to `templates/.github/*`.
- Hook source assets moved to `assets/hooks/*`.
- `bin/carson` is now a thin developer shim delegating to `exe/carson`.

### Removed

- Alias command family previously mapped to template operations.
- Repository-local Carson wrapper bootstrap path in `script/bootstrap_repo_defaults.sh`.
- Marker-based template model.

## 0.1.0 (2026-02-16)

### Added

- Formal project versioning with canonical root `VERSION` file.
- CLI version command support: `bin/carson version` and `bin/carson --version`.
- Smoke-test coverage that validates CLI version output against `VERSION`.
- Initial release record for Carson `0.1.0`.
