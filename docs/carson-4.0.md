# Carson 4.0 Specification

## Status

**Deferred.** The authority model described here was evaluated on 2026-03-15 and deferred. No scar drove local authority — the complexity (per-repo config, dual deliver/govern paths, deferred-backup state) was speculative.

Worktree-first governance (invariant 1) ships as a 3.x feature without the authority model. The authority concept remains as groundwork in config and ledger, but local authority is not implemented or documented as current behaviour.

This spec is retained as a future reference for when a real failure demonstrates the need for local authority.

## Theme

Carson 4 is the strategic governor for multiple agents working in one repository.

The core problem is not GitHub automation. The core problem is concurrent agent work inside one repository: stale bases, inconsistent landing paths, worktree collisions, unsafe clean-up, and drift between what agents believe is true and what the repository actually contains.

Carson 4 solves that single-repo concurrency problem first. Portfolio governance remains important, but it is an extension of the same discipline, not the primary story.

## Objectives

- Make worktree-based work by multiple agents the default operating model in governed repositories.
- Give every governed repository exactly one integration authority at a time.
- Make work start, landing, and clean-up deterministic for the selected authority.
- Keep Carson as the single tool for governed worktree and delivery operations.
- Preserve the outsider boundary: Carson governs repositories without becoming a host-repository runtime dependency.

## Non-goals

- Replacing GitHub rulesets or bypassing required checks.
- Deciding whether a code change is good enough to ship.
- Eliminating plain Git outside Carson-governed repositories.
- Replacing `workflow.style` in Carson 4. Authority and workflow style are separate concerns.

## Definitions

**Governed repository** — a git repository registered under `govern.repos`.

**Root worktree** — the protected primary working tree for the repository.

**Agent worktree** — a Carson-created worktree used for isolated implementation work.

**Primary branch** — the repository's configured long-lived branch, usually `main`.

**Integration authority** — the location whose primary branch is authoritative for where completed work rejoins shared truth.

**Remote authority** — the remote primary branch is authoritative.

**Local authority** — the local primary branch in the root worktree is authoritative.

**Landing path** — the only valid path for completed work to rejoin shared truth for the chosen authority.

## Scope

This spec applies when the current working directory is inside a Carson-governed repository or when Carson is operating on one through an explicit path or `--all`.

This spec covers:
- governed single-repo worktree lifecycle
- authority-aware sync and delivery
- per-repo authority configuration
- authority-aware behaviour for status, audit, review, and govern

This spec does not redefine Carson's branding, release process, or internal code organisation.

## Product Model

Carson 4 has two roles:

- **Git strategist** — Carson decides how new work begins, which baseline it uses, how it lands, and how clean-up happens safely.
- **Repo governor** — Carson enforces the operating contract of the governed repository and reports exact recovery actions when the contract is violated.

The governing idea is simple:

1. Agents do substantive work in Carson worktrees.
2. Each governed repository has exactly one integration authority.
3. Carson owns the valid landing path for that authority.
4. Carson owns the safe clean-up path afterwards.

## Public Configuration Contract

Carson 4 adds per-repo authority to the governed repository registry.

Legacy form:

```json
{
  "govern": {
    "repos": [
      "~/Dev/project-a",
      "~/Dev/project-b"
    ]
  }
}
```

Carson 4 form:

```json
{
  "govern": {
    "repos": [
      { "path": "~/Dev/project-a", "authority": "remote" },
      { "path": "~/Dev/project-b", "authority": "local" }
    ]
  }
}
```

Contract:
- `authority` is stored per governed repository entry.
- Valid authority values are `remote` and `local`.
- Default authority is `remote`.
- Legacy string entries remain valid and mean `authority: "remote"`.
- Carson expands `~` internally for matching, but should prefer `~` in user-facing config when the path is under `$HOME`.

`workflow.style` remains a separate setting. It continues to describe repository workflow style and must not be overloaded to mean authority.

## Public Command Contract

Carson 4 introduces one new authority command:

```bash
carson repo authority <remote|local>
```

Contract:
- The command operates on the current governed repository.
- It changes the repo's configured authority only when Carson can prove the switch is safe.
- Carson may auto-fix safe preconditions first.
- Carson must block unsafe or ambiguous switches and print exact recovery steps.

Carson 4 does not change the names of existing worktree or delivery commands.

## Core Invariants

### 1. Worktree-first

Substantive work must not begin on the root worktree on the configured primary branch in a governed repository.

Substantive work includes:
- file edits and file writes
- `git add`
- `git commit`
- `git push`
- `gh pr create`
- `gh pr merge`
- `carson deliver`
- any other mutating repository command

Read-only inspection is allowed on the root worktree.

### 2. Carson owns governed worktree operations

In governed repositories, Carson owns:
- worktree creation
- worktree removal
- governed clean-up of absorbed work

Raw `git worktree add` and `git worktree remove` are outside the governed path and should be blocked by platform guards where possible.

### 3. Carson owns governed delivery operations

In governed repositories, Carson owns the delivery path.

Raw `git push`, `gh pr create`, and `gh pr merge` are not valid substitutes for Carson's governed delivery path.

### 4. One authority at a time

Every governed repository has exactly one active integration authority.

Authority determines:
- which baseline new work uses
- where completed work rejoins shared truth
- how `sync` behaves
- how `deliver` behaves
- whether PR review and govern features are applicable

### 5. One landing path per authority

For each authority, Carson defines one valid landing path. Agents must not mix authority models inside one repository.

## Authority Models

### Remote Authority

Remote authority means the remote primary branch is the integration authority.

Implications:
- new work starts from a remote-governed baseline
- completed work rejoins through the remote primary branch
- PR-based delivery is the governed path
- review gating and portfolio govern behaviour apply normally

Remote authority is appropriate whenever the repository's source of truth is the remote primary branch, regardless of whether the repository is used by one person or many.

### Local Authority

Local authority means the local primary branch in the root worktree is the integration authority.

Implications:
- new work starts from the local primary branch
- completed work rejoins through the local primary branch
- after local integration, Carson pushes the primary branch to the remote as backup when possible
- PR-based delivery is not the governed path

Local authority is appropriate when the repository's source of truth is the local primary branch, even if a remote exists for backup, sharing, or release.

The distinction is integration authority, not solo versus collaborative use.

## Command Semantics by Authority

### `carson onboard`

Carson 4 onboarding continues to register repositories in `govern.repos`.

Contract:
- if no explicit authority is chosen, onboard stores `authority: "remote"`
- onboard must preserve existing authority when re-run
- onboarding must not require repository-local Carson config

### `carson repo authority <remote|local>`

Authority changes are allowed, but not as a blind config flip.

Switch contract:
- Carson should first auto-fix safe preconditions
- Carson must then verify the repository is in a clean switch state
- only then may Carson write the new authority to config

Minimum clean switch conditions:
- current repo is governed
- root worktree is clean
- root worktree is on the configured primary branch
- no active Carson worktrees remain
- no in-flight local branches remain that would become ambiguous after the switch
- local and remote primary branches are aligned closely enough to prove the switch is not changing the source of truth mid-flight

Carson may tighten these checks during implementation, but it must not allow an authority change that leaves the repo in an ambiguous landing state.

### `carson sync`

`sync` becomes authority-aware.

### Remote authority sync

Remote authority `sync` must:
- require a clean root worktree
- fetch from the configured remote
- update the local primary branch to the remote fast-forward state
- block if the local primary branch is ahead or diverged

Remote authority assumes the remote can be consulted. If the remote cannot be reached, Carson must block rather than guess.

### Local authority sync

Local authority `sync` must:
- require a clean root worktree
- reconcile local and remote when the remote is available
- treat push of the local primary branch as backup, not as the source of truth

Expected behaviour:
- if the local primary branch is behind-only and the remote is reachable, fast-forward pull
- if the local primary branch is ahead-only and the remote is reachable, push the primary branch
- if local and remote diverge, block
- if the remote is unavailable, local authority may continue in a deferred-backup state

### `carson worktree create <name>`

`worktree create` becomes authority-aware.

### Remote authority create

Remote authority worktree creation must:
- run from the root worktree
- prove the root worktree is clean
- fetch and refresh the remote baseline
- create the new worktree from the refreshed remote-governed baseline, not from arbitrary current HEAD

If the remote baseline cannot be proven, Carson must block creation.

### Local authority create

Local authority worktree creation must:
- run from the root worktree
- prove the root worktree is clean
- create the new worktree from the local primary branch

If the remote is available, Carson should reconcile backup state first. If the remote is unavailable, local authority may still create the worktree because backup freshness is not the source of truth.

### `carson deliver`

`deliver` remains the governed delivery entry point, but becomes authority-aware.

### Shared contract

For both authorities:
- `deliver` must not run from the root worktree on the configured primary branch
- `deliver` must operate from an agent worktree
- `deliver` must use Carson's governed landing path, not a raw git or `gh` substitute
- `deliver` must print the exact next clean-up command on success

Carson 4 keeps delivery intent explicit. Plain `deliver` still assumes the change is already committed before delivery begins. `deliver --commit "..."` is the explicit exception: Carson creates one all-dirty delivery commit first, then continues the governed delivery path.

### Remote authority deliver

Remote authority `deliver` must:
- push the work branch
- create or update the PR as required
- apply review and CI gates
- merge through the repository's allowed remote merge path

This is the governed commit → push → PR → merge flow for repositories whose source of truth is the remote primary branch.

### Local authority deliver

Local authority `deliver` must:
- require a clean, committed worktree branch
- integrate the branch into the local primary branch
- use Carson's configured merge method where applicable
- push the local primary branch to the remote as backup when possible

Local authority delivery must not create a PR as part of the governed path.

If the backup push fails because the network is unavailable, local delivery may still succeed with a deferred-backup state.

If the backup push is rejected by remote policy, branch protection, or rulesets, Carson must block and explain that this repository requires remote authority for governed delivery.

### `carson status`

Status must surface repository authority clearly for both single-repo and `--all` output.

### `carson audit`

Audit must evaluate repository health in authority-aware terms.

Expected differences:
- remote authority treats remote-sync failures as blocking repository health issues
- local authority treats deferred backup as attention-worthy but not automatically blocking
- divergence remains blocking in both authorities

### `carson review gate` and `carson review sweep`

Review commands are meaningful only for remote authority's PR-based landing path.

Contract:
- remote authority: fully supported
- local authority: blocked with a clear message that review gates require remote authority

### `carson govern`

`govern` is the portfolio layer for PR-based triage.

Contract:
- remote authority repositories are in scope for normal govern behaviour
- local authority repositories are skipped explicitly, not treated as errors

## Platform Enforcement

Platform hooks, command guards, and adapter policies remain early-warning layers, not the sole source of safety.

The product contract must still hold if a platform-specific guard is absent.

Preferred enforcement:
- block substantive work on the root worktree on the configured primary branch
- redirect worktree lifecycle to Carson commands
- redirect delivery operations to Carson commands

Required backstop:
- Carson commands themselves must refuse invalid authority or worktree states even if no shell hook intercepted the earlier command

## Migration Contract

Carson 4 must migrate existing governance config safely.

Required migration behaviour:
- existing string entries in `govern.repos` remain valid
- legacy entries default to remote authority
- Carson may normalise config to object form when it writes the file
- no repository-local Carson config is introduced as part of authority support

## Acceptance Criteria

Carson 4 is complete only when these behaviours hold.

### Must block

- substantive edits on the root worktree on the configured primary branch in a governed repo
- raw governed delivery operations in a governed repo
- remote authority `worktree create` when the remote baseline cannot be proven
- authority changes that leave active worktrees or ambiguous in-flight state
- local authority delivery when remote rules reject backup push to the primary branch
- review commands in local authority repositories

### Must allow

- read-only inspection on the root worktree
- `carson worktree create <name>` from the root worktree
- governed work inside Carson-created worktrees
- remote authority delivery through Carson
- local authority delivery through Carson
- local authority worktree creation while offline when the root worktree is clean
- `govern` skipping local authority repositories without failing the whole run

### Must explain

Every block must say:
- what condition failed
- why that condition matters
- the exact next command or recovery step

If a user must inspect source code to understand a Carson block, the implementation is incomplete.

## Implementation Notes

The current 4.0 note only covered worktree-first governance. Carson 4 now has a broader target:
- worktree-first remains mandatory
- authority is the new repository-level organising concept
- remote and local authorities are both first-class
- Carson remains the single governed delivery tool

This spec intentionally leads the current implementation. README and MANUAL may describe behaviour that lands incrementally beneath this contract.
