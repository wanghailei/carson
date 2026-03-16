# Carson authority model spec

## Status

Active product spec for Carson's authority model.

This spec defines the target truth for authority and backup in governed repositories. It does not define implementation sequencing.

## Problem

Carson must not sit in the middle between a local-centred model and a remote-centred model.

A governed repository needs one clear answer to two questions:

1. Where do agents branch from?
2. Where does completed work land?

If those answers point to different sides, Carson is hybrid. Hybrid authority is a defect.

## Core definitions

### Authority

The side whose primary branch defines:

- branch origin for new work
- landing path for completed work
- shared truth for the repository

### Backup

The side that mirrors, preserves, or caches the authority side.

Backup does not define branch origin or landing semantics.

### Hybrid authority

A mixed model where:

- one side supplies branch origin and the other supplies landing path, or
- local and remote alternate as shared truth inside one governed workflow

Hybrid authority is forbidden.

## Core law

For every governed repository:

- exactly one side is **authority**
- the other side is **backup**

Authority chooses both:

1. where agents branch from
2. where completed work lands

Neither side may do both authority and backup jobs at the same time.

## Supported authority modes

### Remote authority

Remote authority means the remote primary branch is authority.

Under remote authority:

- agents branch from a proved remote baseline
- completed work lands through remote `main`
- PR review and govern flows remain the governed landing path
- local `main` is backup only

Any local update after landing is a sync or mirror step, not part of the authority chain.

### Local authority

Local authority means the local primary branch is authority.

Under local authority:

- agents branch from local `main`
- completed work lands into local `main`
- remote receives backup pushes only
- PR-based review and govern flows are not the governed landing path

### Current support boundary

Carson supports **remote authority** now.

Local authority is **deferred**. It remains a valid design mode, but it is not active product behaviour until Carson can honour it end to end.

## Repository invariants

### Invariant 1 — one authority only

A governed repository has one authority at a time.

### Invariant 2 — branch origin follows authority

`carson worktree create` must use the repository's authority side as the semantic source of the new branch.

### Invariant 3 — landing path follows authority

`carson deliver` must land through the repository's authority side.

### Invariant 4 — backup is secondary

Backup refresh, drift, or failure may affect operator confidence and recovery flow, but it does not redefine authority.

### Invariant 5 — surfaces must tell the same story

Docs, human output, JSON output, and runtime behaviour must describe the same authority model.

## Remote-authority command contract

### `carson onboard`

When Carson onboards a governed repository, the default authority is remote.

### `carson worktree create`

In remote authority:

- Carson must prove the remote baseline before branching
- Carson must branch from remote authority semantically, not from local `main` as a decision surface
- Carson must block with exact recovery guidance if the remote authority baseline cannot be proved

It is not sufficient to say "synced remote baseline" if the actual decision surface is local authority.

### `carson deliver`

In remote authority:

- Carson must land through remote `main`
- PR creation, review gating, CI gating, and merge remain part of the governed landing path
- any later local update is backup refresh only

### `carson sync`

In remote authority:

- `sync` refreshes local backup state from remote authority
- `sync` does not change who is authority

### `carson status`

In remote authority:

- status must show that remote is authority
- status must show local state separately as backup state

## Surface language contract

Carson must use authority language consistently.

### Required meanings

- **authority** = branch origin plus landing truth
- **backup** = mirror or preservation only
- **sync** = refresh backup state or align local copy, not redefine authority

### Forbidden ambiguity

Carson must not describe a workflow in a way that implies:

- remote is authority for landing but local is authority for branching, or
- local becomes authority because it was refreshed from remote, or
- local post-merge sync is part of remote-authority integration truth

## Deferred local-authority contract

When Carson later supports local authority, it must do so fully.

Minimum contract:

- branch from local `main`
- land into local `main`
- push remote as backup when possible
- do not use PR flow as the governed landing path
- block clearly when remote policy makes the backup contract impossible

Local authority must not ship as a partial flag or advisory mode.

## Out of scope

This spec does not define:

- merge-method policy beyond authority semantics
- implementation phases
- migration sequencing
- portfolio features unrelated to authority and backup

## Acceptance criteria

This spec is satisfied when all of the following are true.

### Product truth

- Every governed repository has one explicit authority.
- The non-authority side is explicit backup.
- No governed workflow is hybrid.

### Runtime truth

- `worktree create` follows authority for branch origin.
- `deliver` follows authority for landing path.
- `sync` is backup refresh in remote mode.

### Surface truth

- README, MANUAL, API, status output, and runtime messages all use the same authority meanings.
- Operators can tell who is authority and who is backup without reading source code.

## Relationship to the idea and plan

- Idea capture: GitHub issue `#339`
- Implementation sequencing: `docs/feature.20260316.authority-model.md`

The issue keeps the original idea in the backlog.
This spec defines the target truth.
The feature document defines the work sequence to reach it.
