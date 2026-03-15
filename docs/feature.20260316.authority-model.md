# Carson authority implementation plan

## Status

Implementation plan for restoring a single explicit authority model to Carson.

This plan assumes the immediate goal is not to ship both remote authority and local authority at once. The immediate goal is to remove Carson's current hybrid path and make one authority model true end to end.

## Problem

Current Carson mixes local and remote roles inside one workflow.

Today the path is effectively:

1. sync local `main` from remote
2. branch from local `main`
3. land through remote `main`
4. sync local `main` again

That is `local → remote → local`.

This leaves Carson between two clean models instead of inside one:

- **remote-centred** — remote is authority, local is backup
- **local-centred** — local is authority, remote is backup

The old authority docs were trying to prevent exactly this middle state.

## Core rule

For any governed repository:

- one side is **authority**
- the other side is **backup**

Authority decides:

1. where agents branch from
2. where completed work lands
3. which side defines shared truth

Backup may mirror or preserve state, but backup does not define branch origin or landing semantics.

Neither side may do both jobs.

## Recommendation

### Ship remote authority first

Implement one pure model now:

- **supported now:** remote authority
- **deferred:** local authority

This keeps scope small while fixing the architectural defect.

### Remote-authority contract

Under remote authority:

- agents branch from a proved remote baseline
- completed work lands through remote `main`
- PR review and govern flows remain the governed path
- local `main` is backup only

Any local update after merge is a sync or mirror step, not part of the authority chain.

## Evidence to preserve

The implementation should preserve the design insight from the deleted Carson 4 authority spec:

- remote authority branches from remote-governed baseline and lands through remote primary branch
- local authority branches from local primary branch and lands through local primary branch, with remote as backup

Primary references:

- `docs/carson-4.0.md` in commit `84bd3695b6fce58ff2cd0c5a4557bebe78588e6f`
- `MANUAL.md` in commit `83d677ebc85f4487a0f1022b86db5f2bce81827a`

Current contradiction to remove:

- `MANUAL.md` lines 120–121 and 149–160 describe remote-centred behaviour
- `lib/carson/worktree.rb` lines 79–95 still branch from local `main`
- `lib/carson/runtime/deliver.rb` lines 388–397 still present local `main` sync as part of the successful delivery story

## Scope

This plan covers:

- worktree creation semantics
- delivery semantics
- sync semantics
- status language
- configuration and domain model shape
- documentation alignment
- regression tests

This plan does not cover:

- full local-authority implementation
- merge-method redesign
- broader govern redesign beyond authority alignment

## Phase 1 — restore the product model

### Goal

Make Carson's docs and internal architecture describe one explicit authority model again.

### Changes

1. Restore authority as a first-class concept in internal docs.
2. Define remote authority explicitly as the only supported live mode.
3. Define local authority explicitly as deferred, not removed.
4. Replace vague baseline wording with authority/backup wording.

### File targets

- `README.md`
- `MANUAL.md`
- `API.md`
- `docs/develop.md`
- optional deferred-design note under `docs/`

### Acceptance

- Carson docs no longer describe a hybrid model.
- The words **authority** and **backup** have stable meanings.
- Remote-only support is stated plainly.

## Phase 2 — make branch origin pure

### Goal

Ensure `carson worktree create` follows remote authority semantically, not local-main authority.

### Required behaviour

- prove the remote baseline
- branch from remote authority semantically
- fail clearly when the remote authority baseline cannot be proved

### Important constraint

The implementation must not quietly redefine “remote baseline” to mean “whatever local main became after a pull”.

That is the ambiguity to remove.

### Candidate implementation directions

#### Option A — branch directly from `remote/main`

Create the worktree branch from `origin/main` or the configured remote tracking ref after fetch.

Pros:

- cleanest authority semantics
- easiest to explain

Risk:

- requires careful handling when the local branch and tracking branch differ in shape or availability

#### Option B — update a dedicated local tracking baseline first, then branch from that recorded authority snapshot

Use a clearly named internal baseline step that proves it is a mirror of remote authority, then branch from that proved snapshot.

Pros:

- may fit current implementation structure more easily

Risk:

- language and code can drift back into “local is authority” if the boundary is not explicit

### Recommendation

Prefer the implementation that gives the clearest proof that branch origin came from remote authority.

### File targets

- `lib/carson/worktree.rb`
- any supporting config or adapter files
- worktree tests

### Acceptance

- `worktree create` no longer uses local `main` as the decision surface for branch origin
- failure to prove remote authority blocks creation with exact recovery guidance
- tests cover happy path, unreachable remote, and stale/diverged cases

## Phase 3 — make landing path pure

### Goal

Ensure successful delivery is described and implemented as landing through remote authority only.

### Required behaviour

- `carson deliver` lands through remote `main`
- any later local update is described as sync or backup only
- delivery success language does not imply that local `main` is part of integration authority

### Changes

1. Audit delivery output wording.
2. Separate **integration success** from **local mirror refresh** in result payloads.
3. Make JSON output expose these as distinct states when both exist.

### File targets

- `lib/carson/runtime/deliver.rb`
- status/report payload builders
- deliver tests

### Acceptance

- successful delivery can be described in one sentence without mentioning local authority
- local sync success or failure is secondary state, not landing truth

## Phase 4 — align sync semantics

### Goal

Make `carson sync` explicitly a backup-refresh command in remote mode.

### Required behaviour

- remote remains authority
- local `main` becomes a mirror of remote authority
- sync output and docs describe this as backup refresh, not authority refresh

### File targets

- `lib/carson/runtime/local/sync.rb`
- `MANUAL.md`
- `API.md`
- sync tests

### Acceptance

- sync semantics match remote-authority language everywhere
- local ahead/diverged states are reported as backup problems, not split authority

## Phase 5 — status and API clarity

### Goal

Make authority visible in user-facing and machine-facing surfaces.

### Changes

1. Add explicit authority reporting to status output.
2. Distinguish authority state from backup state.
3. Stop using overloaded words such as “baseline” where authority is the real concept.

### Suggested payload shape

Without committing to final field names yet, the output should expose separate concepts for:

- authority mode
- authority branch status
- backup branch status
- landing path

### File targets

- `lib/carson/runtime/status.rb`
- `API.md`
- status tests

### Acceptance

- status makes it obvious who is authority and who is backup
- JSON output can be consumed without inferring authority from side effects

## Phase 6 — optional deferred local-authority note

### Goal

Keep local authority alive as a future feature without contaminating current code paths.

### Changes

1. Preserve a deferred design note.
2. Record the minimum local-authority contract.
3. State the hard boundary: local authority is not partial, advisory, or mixed.

### Minimum future contract

- branch from local `main`
- land into local `main`
- push remote as backup when possible
- do not use PR flow as the governed landing path
- block clearly when remote policy makes backup impossible

### Acceptance

- Carson retains the design memory
- current code does not carry speculative local-authority behaviour

## Testing plan

### Unit and runtime coverage

Add or update tests for:

1. worktree creation from proved remote authority baseline
2. worktree creation blocked when remote authority cannot be proved
3. delivery success through remote authority
4. local sync reported as backup refresh only
5. status output separates authority from backup state

### Behavioural proof

Before claiming completion, prove:

1. a new worktree branches from the chosen authority path
2. a delivered branch lands through the chosen authority path
3. local post-merge state is reported as backup state only

## Risks

### Risk 1 — semantic fix without implementation fix

Docs may be cleaned up while the code still branches from local authority.

Mitigation:

- do not merge documentation-only authority claims without matching runtime proof

### Risk 2 — implementation fix without surface clarity

Code may become purer while outputs still describe the old hybrid story.

Mitigation:

- treat wording updates as part of the same change

### Risk 3 — accidental reintroduction of hybrid behaviour

Future convenience changes may pull Carson back toward “local → remote → local”.

Mitigation:

- add regression tests that fail when branch origin and landing path belong to different authorities

## Delivery slices

### Slice A — docs and status language

Smallest useful first slice:

- restore authority wording
- label remote as active authority
- label local as backup
- make status output authority-aware

### Slice B — worktree origin fix

Next slice:

- change `worktree create`
- add proof and tests for remote-authority branch origin

### Slice C — delivery output and payload fix

Next slice:

- separate landing truth from local backup refresh
- update deliver outputs and tests

### Slice D — deferred local-authority note

Final slice:

- preserve future contract without enabling speculative runtime paths

## Acceptance criteria

This implementation plan is complete when all of the following are true:

### Product

- Every governed repository has one explicit authority.
- The non-authority side is explicitly backup.
- Carson no longer documents or performs a hybrid authority flow.

### Runtime

- `worktree create` uses remote authority semantically in remote mode.
- `deliver` lands through remote authority only.
- local refresh is treated as backup state only.

### Surface

- README, MANUAL, API, and status output use the same authority model.
- operators can tell who is authority and who is backup without reading source code.

### Proof

- tests cover branch origin, landing path, and backup-state reporting
- at least one observable end-to-end run proves the authority path works as designed

## Next action

Implement **Slice A** and **Slice B** together if possible.

That gives Carson the highest-value correction first:

- the model becomes explicit again
- the branch origin stops contradicting the stated authority
