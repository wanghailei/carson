# Carson Agent Policy Boundary Spec

This document defines the implementation boundary for Carson-owned coding-agent policy.

## Problem

Carson workflow policy is leaking into global agent defaults and into repositories that Carson does not govern.

That leakage creates two failures:

- non-governed repositories experience Carson restrictions when they should behave like normal agent environments
- Carson appears to own `~/.claude` and `~/.codex`, which makes Carson feel globally present rather than explicitly scoped

Provider limitations complicate activation, but they do not change the boundary. Activation constraints must not become an excuse for global Carson policy ownership.

## Boundary Rule

Carson-related coding-agent settings belong under `~/.carson`.

Carson must not continuously manage `~/.claude` or `~/.codex` as policy surfaces. Those locations may contain a narrow provider bootstrap where a provider offers no repo-local hook registration, but they are not Carson's canonical home.

Non-governed repositories must experience no Carson workflow enforcement.

Governed repositories are canonical through Carson-generated repo-local files, repo-side enforcement, and a narrow provider bootstrap only where provider limitations require one.

## Non-Governed Repo Contract

In a non-governed repository:

- no Carson branch, edit, main-tree, or Bash-write guards apply
- no Carson raw delivery bans apply
- no Carson-managed workflow restrictions appear through global defaults
- behaviour matches the user's normal agent defaults, as if Carson were not installed

If the user explicitly invokes the `carson` CLI in a non-governed repository, Carson may still respond as a tool. The contract here is about ambient policy enforcement, not about hiding the executable.

## Governed Repo Contract

In a governed repository:

- Carson-generated repo-local instruction stubs are canonical
- repo-side git hooks remain the hard enforcement backstop
- provider bootstrap may consult `~/.carson` only to decide whether Carson policy applies in the current repository
- Carson-managed workflow guards apply only there

Delivery boundary:

- commit creation remains normal `git commit`
- Carson begins at push, PR, and merge in governed repositories
- `carson deliver` transports already-committed changes through the governed delivery path; it does not create commits

## Canonical Asset Model

`~/.carson/agents/` contains the source assets and hook scripts that Carson owns on the workstation.

These assets are workstation-side source material, not repository runtime dependencies.

Governed repositories receive generated repo-local files from `carson onboard` and `carson refresh`. Those generated files may be copies or thin stubs, but repository CI and runtime must not require `~/.carson` to exist.

Only the local agent toolchain may consult `~/.carson` at runtime.

`~/AI`, `~/.claude`, and `~/.codex` are not Carson canonical assets.

## Provider Activation Model

Provider activation follows the provider's constraints without changing Carson's ownership boundary.

### Claude Code

Claude Code does not provide repo-local PreToolUse registration. Carson therefore allows one neutral global bootstrap registration only.

That bootstrap:

- points into `~/.carson`
- checks governed-repo membership before any expensive work
- exits immediately for non-governed repositories
- does not own general user defaults beyond that narrow dispatch role

The bootstrap is an activation shim, not a policy home.

### Codex

Codex must not keep Carson-specific global bans in `~/.codex/rules/default.rules`.

Until Codex exposes a repo-aware hook or rule mechanism, governed-repository hard enforcement comes from repo-side git hooks plus repo-local instruction files rather than from global Carson bans.

### Other providers

Providers should prefer repo-local activation whenever they support it. If they do not, they should follow the same narrow-bootstrap rule: dispatch globally, decide locally, and exit immediately outside governed repositories.

## Guard Dispositions

The following guards are Carson-owned and governed-repository only:

- `command-guard`
- `edit-guard`
- `main-tree-write-guard`
- `bash-write-guard`

`destructive-action-guard` is explicitly outside Carson scope. It remains part of the general agent safety baseline and is not migrated by this spec.

Performance rule:

- governed-repo detection must happen before expensive parsing
- `bash-write-guard` must check governed status before command parsing
- v1 adds no caching; measure first and optimise only if latency becomes observable

`bash-write-guard` also requires the following functional corrections:

- resolve leading `cd <path> && ...` and `cd <path> ; ...`
- resolve relative write targets from the effective working directory
- ignore plain angle-bracket placeholder text that is not shell redirection
- avoid heredoc-driven false positives in commit-message commands

## Migration Plan

Implementation proceeds in phases:

1. Approve this spec.
2. Remove Carson-managed policy entries and claims from `~/AI`, `~/.claude`, and `~/.codex` in separate cross-repo work.
3. Add canonical Carson-owned agent assets under `~/.carson/agents/`.
4. Extend `carson onboard` and `carson refresh` to generate governed-repository entrypoints from those assets.
5. Move Carson-owned guards to governed-only activation and land the `bash-write-guard` corrections.
6. Verify governed and non-governed behaviour against the acceptance criteria in this document.

The cleanup and the Carson implementation should remain separate scoped changes. One Carson PR must not pretend to complete the cross-repo cleanup.

## Cross-Repo Dependencies

`~/AI` documentation and policy cleanup is outside the Carson repository.

`~/.claude` and `~/.codex` cleanup is workstation configuration work, not a Carson repository change.

Carson implementation is not fully complete until those external dependencies are coordinated, but they must be tracked and landed separately from the Carson code and doc changes in this repository.

## Acceptance Criteria

The boundary is correct only when all of the following are true:

- a non-governed repository shows no Carson guard or delivery behaviour
- a governed repository activates Carson through repo-local generation plus governed-aware provider bootstrap only
- Claude Code bootstrap exits cleanly with no effect in a non-governed repository
- Codex no longer depends on generic global Carson bans
- `bash-write-guard` passes regressions for `cd`-into-worktree commands, angle-bracket placeholder text, and heredoc-backed commit-message commands
- Carson-owned agent assets live under `~/.carson`, not as ongoing policy ownership in `~/.claude` or `~/.codex`
