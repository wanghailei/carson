# Butler Technical Guide

## Purpose

Butler is an outsider governance runtime for repository hygiene and merge-readiness controls.

Its design goal is operational discipline with minimal host-repository footprint.

Audience: Butler contributors and advanced operators who need technical behaviour details.

Common-user operations belong in `docs/butler_user_guide.md`.

==Butler carries its own runtime assets and does not rely on Butler-owned files inside host repositories.==

## Scope and Boundaries

In scope:

- local governance commands (`audit`, `sync`, `prune`, `hook`, `check`, `init`, `offboard`, `template`, `review`)
- deterministic review gating and scheduled late-review sweeps through GitHub CLI
- whole-file management of selected GitHub-native files (`.github/*`)
- global hook installation under Butler runtime home
- exact exit-status contract for automation use

Out of scope:

- replacing GitHub as merge authority
- host-repository business logic policy
- merge execution or force merge decisions
- host-repository Butler-specific configuration files

Boundary rules:

- host repository must not contain Butler-owned artefacts (`.butler.yml`, `bin/butler`, `.tools/butler/*`)
- host repository may contain GitHub-native policy files managed by Butler

## Module Relationships

- `exe/butler`: primary executable entrypoint
- `lib/butler/cli.rb`: command parsing and dispatch
- `lib/butler/config.rb`: built-in runtime defaults and environment override handling
- `lib/butler/runtime.rb`: runtime wiring, shared helpers, and concern loading
- `lib/butler/runtime/local_ops.rb`: local repository operations and hook/template/runtime boundary helpers
- `lib/butler/runtime/audit_ops.rb`: audit reporting, PR/check monitor report generation, and scope integrity guard
- `lib/butler/runtime/review_ops.rb`: review gate/review sweep orchestration and GitHub review data mapping
- `lib/butler/adapters/git.rb`: git process adapter
- `lib/butler/adapters/github.rb`: GitHub CLI process adapter
- `templates/.github/*`: canonical managed GitHub-native files
- `assets/hooks/*`: canonical hook assets
- `script/bootstrap_repo_defaults.sh`: branch-protection and secret bootstrap helper

`*_ops.rb` purpose:

- keep `Runtime` as the single orchestration object
- group methods by workflow ownership (`local`, `audit`, `review`)
- keep command dispatch in `CLI` while placing command logic in runtime concerns

Current line count reality:

- `local_ops.rb`: multi-workflow local governance and hook/template helpers
- `audit_ops.rb`: audit state and monitor report writing
- `review_ops.rb`: gate/sweep with substantial GitHub response normalisation logic

Rails-derived split rule used by Butler:

- split by behaviour ownership, not arbitrary line count
- keep one primary responsibility per file
- keep thin entrypoints (`CLI`) and move behaviour into concern files
- avoid no-op wrapper files that only forward one call
- split further when a file mixes unrelated helper clusters or integrations

## Core Flow

1. For new repositories, run `butler init [repo_path]` to apply baseline setup in one command.
2. Run `butler audit` to evaluate local policy state.
3. If required, run `butler hook` then `butler check`.
4. Keep local `main` aligned using `butler sync`.
5. Remove stale local branches using `butler prune`.
6. Keep managed `.github/*` files aligned using `butler template check` and `butler template apply`.
7. Before merge recommendation, run `gh pr list --state open --limit 50` and `butler review gate`.
8. Scheduled automation runs `butler review sweep` for late actionable review activity.
9. If retiring Butler from a repository, run `butler offboard [repo_path]`.

Exit status contract:

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Feature: Outsider Boundary Enforcement

Mechanism:

- Runtime checks host repository for forbidden Butler fingerprints.
- Violations are reported as hard blocks before governance execution proceeds.

Blocked host artefacts:

- `.butler.yml`
- `bin/butler`
- `.tools/butler/*`
- legacy marker artefacts from older template strategy

Key code segments:

- `block_if_outsider_fingerprints!` in `lib/butler/runtime/local_ops.rb`
- `outsider_fingerprint_violations` in `lib/butler/runtime/local_ops.rb`
- `legacy_marker_violations` in `lib/butler/runtime/local_ops.rb`

Boundary:

- Butler repository itself is exempt from this check so Butler can evolve its own codebase.

## Feature: Global Hook Runtime

Mechanism:

- Hook assets are read from `assets/hooks/*`.
- Hooks are installed to `~/.butler/hooks/<version>/`.
- Repository `core.hooksPath` is set to that global path.

Key code segments:

- `hook!` in `lib/butler/runtime/local_ops.rb`
- `hooks_dir` in `lib/butler/runtime/local_ops.rb`
- `hook_template_path` in `lib/butler/runtime/local_ops.rb`
- `hooks_health_report` in `lib/butler/runtime/local_ops.rb`

Boundary:

- Butler does not create `.githooks/*` inside host repositories.

## Feature: One-command initialisation (`init`)

Mechanism:

- `init` verifies the target path is a git repository.
- It ensures Butler remote naming by using `github` when present or renaming `origin` to `github`.
- It then executes baseline setup sequence: `hook`, `template apply`, `audit`.

Key code segments:

- `init!` in `lib/butler/runtime/local_ops.rb`
- `align_remote_name_for_butler!` in `lib/butler/runtime/local_ops.rb`

Boundary:

- `init` does not commit changes in the host repository.
- Merge authority and required checks remain GitHub controls.

## Feature: Repository retirement (`offboard`)

Mechanism:

- `offboard` verifies the target path is a git repository.
- It unsets `core.hooksPath` only when the configured value points to Butler-managed hooks base path.
- It removes Butler-managed template files and known Butler-specific legacy artefacts in the host repository.

Key code segments:

- `offboard!` in `lib/butler/runtime/local_ops.rb`
- `disable_butler_hooks_path!` in `lib/butler/runtime/local_ops.rb`
- `offboard_cleanup_targets` in `lib/butler/runtime/local_ops.rb`

Boundary:

- `offboard` does not remove user-owned hook configurations that are not Butler-managed.

## Feature: GitHub Template Management

Mechanism:

- Template sources live in `templates/.github/*`.
- Drift checks compare full file content (normalised line endings).
- Apply writes full managed file content.

Managed files:

- `.github/copilot-instructions.md`
- `.github/pull_request_template.md`

Workflow:

1. Run `butler template check` to detect drift.
2. Run `butler template apply` to write canonical content.

Drift reasons:

- `missing_file`: target file does not exist.
- `content_mismatch`: target file content differs from canonical content.

Key code segments:

- `template_results` in `lib/butler/runtime/local_ops.rb`
- `template_result_for_file` in `lib/butler/runtime/local_ops.rb`
- `template_check!` in `lib/butler/runtime/local_ops.rb`
- `template_apply!` in `lib/butler/runtime/local_ops.rb`

Boundary:

- Managed files are GitHub-native host files.
- Butler-specific marker syntax is not used.

## Feature: Review Gate and Review Sweep

Mechanism:

- `review gate` waits for warm-up, polls for convergence, and blocks on unresolved actionable findings.
- Actionable findings include unresolved threads, non-author `CHANGES_REQUESTED`, and risk-keyword top-level comments/reviews.
- `review sweep` scans recent open/closed pull requests and upserts one rolling tracking issue.

Key code segments:

- `review_gate!` in `lib/butler/runtime/review_ops.rb`
- `review_gate_snapshot` in `lib/butler/runtime/review_ops.rb`
- `review_sweep!` in `lib/butler/runtime/review_ops.rb`
- `upsert_review_sweep_tracking_issue` in `lib/butler/runtime/review_ops.rb`

Boundary:

- Butler provides deterministic governance signals.
- Merge authority remains GitHub plus human judgement.

## Feature: Branch Hygiene and Main Sync

Mechanism:

- `sync` requires clean tree and fast-forwards local `main` from configured remote.
- `prune` targets only local branches tracking deleted upstream refs.
- Force-delete path is gated by merged-PR evidence for exact branch tip.

Key code segments:

- `sync!` in `lib/butler/runtime/local_ops.rb`
- `prune!` in `lib/butler/runtime/local_ops.rb`
- `stale_local_branches` in `lib/butler/runtime/local_ops.rb`
- `force_delete_evidence_for_stale_branch` in `lib/butler/runtime/local_ops.rb`

Insight:

==Prune targets only branches whose tracked upstream ref is gone; untracked local branches are intentionally excluded.==

## Feature: Runtime Configuration

Mechanism:

- Runtime uses built-in defaults from `lib/butler/config.rb`.
- Report output precedence is global `~/.cache/butler`, then `TMPDIR/butler` when `HOME` is invalid and `TMPDIR` is absolute, then `/tmp/butler`.
- Environment overrides exist for hooks path (`BUTLER_HOOKS_BASE_PATH`), review timing, and sweep window/states.
- Host repository configuration file loading is intentionally disabled.

Key code segments:

- `Butler::Config.default_data` in `lib/butler/config.rb`
- `Butler::Config.apply_env_overrides` in `lib/butler/config.rb`
- `Butler::Config#validate!` in `lib/butler/config.rb`

Boundary:

- Customisation remains centralised in Butler runtime, not in host repositories.

## Feature: FAQ

Q: Why keep Butler outside host repositories?  
A: It keeps host repositories clean and avoids Butler-specific operational drift.

Q: Why still write `.github/*` files in host repositories?  
A: Those files are GitHub-native policy inputs required by GitHub workflows and review tooling.

Q: Why does Butler block on `.butler.yml` now?  
A: Outsider mode forbids host Butler configuration artefacts to preserve boundary clarity.

Q: Why install hooks globally instead of inside each repository?  
A: It keeps Butler-owned hook assets outside host repositories while still enforcing local protections.

Q: Can Butler still support deterministic CI behaviour?  
A: Yes. CI pins exact Butler version and runs the same exit-status contract.

## References

- `README.md`
- `RELEASE.md`
- `VERSION`
- `butler.gemspec`
- `lib/butler/cli.rb`
- `lib/butler/config.rb`
- `lib/butler/runtime.rb`
- `lib/butler/runtime/local_ops.rb`
- `lib/butler/runtime/audit_ops.rb`
- `lib/butler/runtime/review_ops.rb`
- `assets/hooks/pre-push`
- `assets/hooks/pre-merge-commit`
- `assets/hooks/prepare-commit-msg`
