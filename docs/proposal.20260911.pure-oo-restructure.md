# Carson: Pure OO Restructure Proposal

**Date:** 2026-09-11  
**Status:** proposed; no production migration started  
**Scope:** replace the transitional Runtime architecture while preserving Carson's local-centred behaviour and optional Bureau delivery.

## Decision

Do a **strangler migration by complete vertical command slice**, not another broad extraction and not an in-place cleanup of `Runtime`.

The target is a small object graph with explicit ownership, typed outcomes, injected ports, and no domain object that knows about `Runtime`, `Open3`, CLI streams, or result hashes. `Runtime` is deleted at the end; it must not be renamed, retained as a service locator, or made into a thinner god object.

The migration order is deliberately local-first:

1. establish a reliable behavioural baseline;
2. make the local Warehouse path correct and self-contained;
3. remove duplicate workbench implementations;
4. isolate Bureau-only behaviour behind its own boundary;
5. move Company/portfolio operations out of Runtime;
6. remove legacy commands and Runtime only when their replacement owns the whole behaviour.

This matches the product decision already recorded in #520: local delivery is the foundation; Bureau is an optional enhancement, not a competing workstyle.

## Research summary

### Current state

`main` is current locally at `fc32986` / v4.4.0. The repository already contains the beginnings of the intended model (`Warehouse`, `Vault`, `Parcel`, `Waybill`, `Courier`) but it is transitional rather than pure OO.

| Evidence | Finding |
|---|---|
| `lib/cli.rb` — 1,176 lines | Parses, resolves portfolio targets, instantiates Runtime, selects local vs Bureau delivery, renders several result shapes, and reaches into Runtime through `send`. It is an application god object. |
| `lib/carson/runtime/` — 7,115 lines | Runtime is still the operational centre. `runtime/deliver.rb` alone is 1,255 lines and contains a second, legacy delivery implementation beneath the OO bridge. |
| `lib/carson/worktree.rb` — 661 lines and `warehouse/workbench.rb` — 440 lines | Two competing implementations own worktree creation, discovery, deletion, process checks, cleanup, output, and Git calls. Their policies have already drifted. |
| `Warehouse` includes `Workbench`, `Seal`, and `Bureau` | One local aggregate is coupled directly to worktree lifecycle, filesystem seals, `gh`, and `Open3`. This violates both the specified Warehouse/Courier boundary and local/Bureau separation. |
| `Runtime` re-exports private methods as public | The closing `public :config, :git_run, :ledger, ...` list is an implicit service-locator API. Domain objects depend on framework plumbing rather than declared collaborators. |
| 129 `status`/`command`/`error`/`outcome` hash literals in `lib/` | Result contracts are informal and duplicated. Status strings and output policy leak across CLI, Runtime, Courier, Worktree, and Warehouse. |
| `Adapters::Git` / `Adapters::GitHub` exist but Warehouse, Courier, Worktree, and Runtime also call `Open3.capture3` | There is no enforced I/O boundary, so deterministic tests require real processes and behaviour is duplicated. |
| `docs/develop.md` names removed paths (`lib/carson/cli.rb`, `runtime/audit.rb`, `runtime/govern.rb`) | The design, code, docs, and command surface have diverged. The OO spec itself still calls for a `workstyle` branch although main has `bureau`. |

### GitHub issue evidence

Open issues independently confirm the same boundaries are wrong:

- **#524:** local cleanup is blocked by Bureau/PR state and `Vault#absorbed?` is semantically wrong after main advances. It explicitly asks for Bureau separation.
- **#520:** the public local-centred surface should collapse to `checkin`, `deliver`, and four portfolio verbs; `sync`, `housekeep`, `prune`, and remote-only commands should not remain competing public workflows.
- **#521:** audit/pre-commit policy is currently mixed between local and Bureau concerns.
- **#523:** `status`, `onboard`, and `offboard` lack a confirmed owner after Runtime removal.
- **#464:** the OO Waybill path omitted review policy, proving that copying a legacy flow into a new object is not sufficient; the delivery policy needs one authoritative model.
- **#481:** workbench creation must not silently branch from a stale main.
- **#484 / #459:** portfolio monitoring and concurrent deliveries need explicit coordination, not a larger Courier or Runtime.
- **#525:** repository validators need a hook dispatcher. This is a host integration concern, not Warehouse or Courier behaviour.

### Dogfood incident

During the Pi amber delivery on this machine, Carson had stale portfolio entries after directories were renamed (`~/pi` → `~/Pi`, `~/oma` → `~/OS`). `carson Pi deliver` resolved the stale case-insensitive basename before the valid registration, and delivery could not proceed until the registry was repaired.

This is not merely an edge case. A portfolio is persistent identity, not an array of path strings. The target design must distinguish a repository identity from its current local location, reject ambiguous selectors, and diagnose missing registrations without requiring a hand edit to `~/.carson/config.json`.

### Test baseline

With Ruby 3.4.10 and the ambient global Git configuration inherited, the complete suite reports **645 runs, 1,857 assertions, 1 failure, 25 skips**. The remaining failure is the other-process-CWD detection test (`RuntimeWorktreeLifecycleTest#test_worktree_remove_blocks_when_other_process_holds_cwd`), a timing/process-observation defect.

Without `GIT_CONFIG_GLOBAL=/home/whl/.gitconfig`, the same suite has **84 failures and 52 errors**, overwhelmingly because temporary repositories have no Git identity. Tests must install an explicit test identity; they must not depend on a developer's global config. This is a prerequisite for trusting a rewrite.

## Target architecture

### 1. Four layers, dependencies inward

```text
CLI adapters / hook adapters / scheduler adapter
                 |
            Application services
                 |
        Domain aggregates and value objects
                 |
Ports (Git, Bureau API, filesystem, clock, process inspector, stores)
                 |
Open3/GitHub CLI/JSON/filesystem implementations
```

- **Adapters** translate arguments, hooks, scheduler events, and output. They never contain policy.
- **Application services** assemble one use case, open a repository, invoke objects, and return a typed outcome. They are the only place that knows the command names.
- **Domain** contains behaviour and invariants. It receives collaborators through constructors/interfaces, never a Runtime.
- **Infrastructure** implements ports. `Open3.capture3`, `gh`, JSON files, `lsof`, `sleep`, `FileUtils`, and environment lookup are contained here.

Ruby has no compiler-enforced interfaces, so ports are small duck-typed protocols with contract tests. No global singleton is introduced.

### 2. Object ownership

```text
Carson::Company
  owns Portfolio
  owns RepositoryFactory
  starts portfolio-level operations only

Portfolio
  owns RepositoryRegistration records and registration persistence
  resolves a selector unambiguously; diagnoses missing/moved repositories

Repository
  owns RepositoryId, RepositoryLocation, Warehouse, optional Bureau

Warehouse (aggregate root; local only)
  owns Vault and WorkbenchCollection
  opens/checks in a workbench, prepares a parcel, accepts it into vault,
  receives the standard, and sweeps local state

Vault
  owns local-main acceptance and absorbed-content proof

Workbench (entity/value object)
  knows path, branch, cleanliness, occupancy and seal state;
  does not create/delete itself and does not render output

Parcel (immutable value)
  identifies source branch, head, base/head relation and content proof

Courier
  performs exactly one outbound delivery of an accepted parcel
  has no prep, rebase, worktree, or CLI output responsibility

Bureau (optional external boundary)
  files/observes/merges a Waybill, evaluates CI and review policy

Waybill / Delivery / Revision
  immutable or narrowly mutable domain records; no GitHub calls

DeliveryLedger
  persistence port/repository, not a domain object that manages JSON itself
```

This gives the ambiguous items in #523 an owner:

| Capability | Owner | Reason |
|---|---|---|
| onboarding / offboarding / list | `Company` + `Portfolio` | Client relationship and persistent portfolio membership are company concerns, not repository-local Warehouse work. |
| status | `RepositoryStatus` query service composed from `Warehouse` plus optional `Bureau` | It is an observation, not a mutating domain verb. Local status never calls Bureau when `bureau: false`. |
| checkin | `Warehouse#check_in` | Creating a fresh local workbench from a verified standard is warehouse custody. |
| delivery preparation and local acceptance | `Warehouse#prepare` then `Vault#accept` | These are inside-repository operations. |
| remote sync / PR lifecycle | `Courier` with a `Bureau` collaborator | The outbound delivery worker owns the external errand. |
| automatic portfolio cycle | `Company#cycle` | Cross-repository scheduling belongs to Company, while it delegates one repository at a time. |

### 3. One delivery state machine

There must be one authoritative delivery lifecycle, shared by local and Bureau delivery. Do not retain the current Courier path plus `Runtime::Deliver` path.

```text
prepared -> accepted -> synced
                         |
                         +-- bureau disabled --> delivered
                         |
                         +-- bureau enabled --> filed -> observing
                                                    |-> held
                                                    |-> rejected
                                                    |-> integrated
```

`DeliveryOutcome` is a closed family of objects (or frozen value records), not arbitrary hashes:

```ruby
DeliveryOutcome::Delivered.new( parcel:, synced: )
DeliveryOutcome::Held.new( parcel:, reason:, recovery: )
DeliveryOutcome::Blocked.new( reason:, recovery: )
DeliveryOutcome::Failed.new( error: )
```

A renderer maps those outcomes to JSON or text. The Courier never prints, sleeps by itself, or knows `$stdout`. A `Clock`/`Waiter` port controls polling in Bureau mode.

Review is a first-class `ReviewDecision` supplied by Bureau observation. It is part of `Waybill#ready?`, fixing #464 structurally rather than adding one more conditional.

### 4. Ports

Minimum contracts:

| Port | Used by | Responsibility |
|---|---|---|
| `GitRepository` | Warehouse, Vault, WorkbenchCollection | branch/head/status/worktree/merge/rebase/fetch/push primitives; returns typed Git results or raises narrow infrastructure errors. |
| `BureauGateway` | Bureau | file/find PR, observe checks/review/mergeability, merge. |
| `PortfolioStore` | Portfolio | atomic registration CRUD; supports aliases and moved-location repair. |
| `DeliveryStore` | DeliveryLedger | persist/query delivery records. |
| `FileStore` | SealStore, config | atomic files and paths. |
| `ProcessInspector` | Workbench | CWD occupation query; test fake avoids `lsof` timing. |
| `Clock` / `Sleeper` | Bureau observer/cycle | deterministic polling and timeouts. |
| `HookInstaller` | Company onboarding | install Carson-managed hooks and dispatcher without leaking it into Warehouse. |

The production `GitCli`, `GitHubCli`, `JsonPortfolioStore`, and `JsonDeliveryStore` can continue to use command-line tools and JSON. Pure OO does **not** require replacing proven external mechanisms; it requires isolating them.

### 5. Public surface

Adopt #520's local-centred six-command surface after migration:

```text
Agent:      carson checkin <name>
            carson deliver [--commit MESSAGE]

Portfolio:  carson onboard <path>
            carson offboard <path>
            carson list
            carson version
```

`checkout`, `sync`, `worktree`, `prune`, and `housekeep` become transitional compatibility aliases first, then disappear after `checkin`/Warehouse sweep covers their safe use cases. Bureau operations are invoked only by the optional Bureau policy and Company cycle; they are not a second everyday agent workflow.

Keep a machine-readable observation command internally/API-first if agents need it, but do not let it recreate a public Runtime command family. Compatibility aliases must be thin adapter calls, emit a deprecation warning, and have a removal release.

## File layout after migration

```text
lib/carson.rb                         # composition root + public Company factory
lib/cli.rb                            # parse -> application service -> renderer only

lib/carson/application/
  check_in.rb
  deliver.rb
  repository_status.rb
  onboard.rb
  offboard.rb
  list_portfolio.rb
  cycle.rb

lib/carson/domain/
  company.rb
  portfolio.rb
  repository.rb
  repository_id.rb
  repository_location.rb
  warehouse.rb
  vault.rb
  workbench.rb
  workbench_collection.rb
  parcel.rb
  courier.rb
  delivery.rb
  delivery_outcome.rb
  waybill.rb
  bureau.rb
  review_decision.rb

lib/carson/ports/
  git_repository.rb
  bureau_gateway.rb
  portfolio_store.rb
  delivery_store.rb
  process_inspector.rb
  clock.rb
  hook_installer.rb

lib/carson/infrastructure/
  git_cli.rb
  github_cli.rb
  json_portfolio_store.rb
  json_delivery_store.rb
  file_seal_store.rb
  lsof_process_inspector.rb
  system_clock.rb
  managed_hook_installer.rb

lib/carson/presentation/
  text_renderer.rb
  json_renderer.rb
```

There is intentionally no `runtime/`, no `warehouse/bureau.rb` mixin, no second `worktree.rb`, and no module included merely to split a god object by file.

## Migration plan

### Phase 0 — establish truth (one small PR)

1. Make the test helper configure `user.name` and `user.email` in every test repository or pass an explicit test Git config through the Git port.
2. Replace the CWD-holder race with a deterministic process fixture/handshake and a fake `ProcessInspector` unit test.
3. Record the full suite as the baseline; make the 25 skips explicit tracked work, not invisible debt.
4. Add contract tests for the current CLI JSON/text and Git safety outcomes that must remain stable through migration.

**Exit:** the suite passes without ambient global Git configuration; all process tests are deterministic.

### Phase 1 — repair local custody before moving code (two small PRs)

1. Move the correct absorbed-content algorithm from `runtime/local/prune.rb` behind `Vault#absorbed?`; cover fast-forward, squash, rebase, cherry-pick, and later-main commits (#524).
2. Make `Warehouse#receive_latest!` and checkin a hard, explicit standard policy. A failed fetch blocks checkin; it never silently branches from stale main (#481).
3. Build `WorkbenchCollection` and migrate `checkin`, removal, sweep, and occupancy behind it.
4. Delete the duplicate behaviour in `Carson::Worktree`; retain only a compatibility adapter until command aliases are removed.
5. Put seals behind `SealStore`; a local delivery has no Bureau seal behaviour.

**Exit:** a local repo can check in, deliver, and sweep without `Runtime`, GitHub CLI, ledger, or PR queries.

### Phase 2 — one local delivery slice (two to three PRs)

1. Introduce immutable `Parcel`, `Delivery`, and `DeliveryOutcome` contracts.
2. Implement `Application::Deliver` as `Warehouse#prepare` -> `Vault#accept` -> `Courier#sync`.
3. Move local rendering to `Presentation`; delete `CLI#dispatch_deliver_locally` policy and all local `Runtime::Deliver` bridges.
4. Compare legacy and new contract tests, then route `carson deliver` exclusively through the new slice.

**Exit:** local delivery contains no `if bureau`, no result hash protocol, no Runtime access, and no output from domain classes.

### Phase 3 — make Bureau a real optional boundary (three to four PRs)

1. Create `Domain::Bureau` and `Ports::BureauGateway`; move PR/check/review/merge observation out of Warehouse.
2. Build a single `Waybill` readiness policy from CI, review, draft, mergeability, and branch freshness. Close #464 with contract tests.
3. Move remote-only delivery, receive/recover/abandon/review code out of `runtime/` into Bureau application services. Delete duplicate legacy flow as each behaviour moves.
4. Move all PR-dependent cleanup decisions out of local sweep (#524). Local sweep asks only local objects whether content is absorbed, clean, unoccupied, and unsealed.
5. Introduce `Company#cycle` as the sole coordinator for optional Bureau monitoring (#484). It takes a scheduler/clock port and processes repositories independently, allowing one Courier per delivery (#459) without a shared mutable Courier pool.

**Exit:** `bureau: false` loads neither `gh` behaviour nor PR policy; `bureau: true` uses exactly one delivery state machine.

### Phase 4 — Company and portfolio (two PRs)

1. Replace the JSON array of paths with `PortfolioRegistration` records: stable ID (canonical remote URL when available), current location, aliases/move history, and last verification.
2. `Portfolio#resolve` prefers exact path/ID, rejects ambiguous case-insensitive basenames, and reports stale/moved entries with an explicit `carson onboard <new-path>` repair path.
3. Move onboard/offboard/list, hook installation, and the repository validator dispatcher (#525) to Company application services.
4. Implement `RepositoryStatus` as a query composition, not a Runtime method.

**Exit:** the Pi/OS rename incident is covered by acceptance tests; no domain class reads global config directly.

### Phase 5 — delete transitional architecture (one focused removal PR)

1. Delete `Runtime` and `runtime/` only after no callers remain.
2. Delete legacy `Worktree` lifecycle and old command implementations.
3. Remove public `Runtime` escape hatches and `send` calls from CLI.
4. Remove obsolete docs, stale command names, and duplicate diagrams; generate the class diagram from the target layout.
5. Retire compatibility aliases in the next major version.

**Exit:** `rg 'Runtime|Open3.capture3' lib/carson/domain lib/carson/application` is empty; only infrastructure invokes processes; full suite and scenario tests pass.

## Non-negotiable guardrails

- No module extraction that still shares `Runtime` and calls private Runtime methods. That is file-level refactoring, not OO.
- No broad “replace all” migration. Each PR changes one vertical behaviour and proves it.
- No result hashes crossing domain boundaries. Use value objects/outcomes.
- No `Open3`, `gh`, `File`, `ENV`, `sleep`, or `$stdout` in domain/application classes.
- No local path string as portfolio identity.
- No Bureau query in a `bureau: false` cleanup/checkin/deliver path.
- No automatic destructive sweep without the existing clean, occupancy, and content-absorption proof.
- Preserve outsider boundary: Carson stores its own state outside client repositories; hook dispatchers may execute client-owned scripts but do not make Carson a client-repo runtime dependency.

## Suggested delivery order and issue mapping

| PR | Work | Existing issues |
|---|---|---|
| 1 | Hermetic test identity + deterministic occupancy test | new test-infrastructure issue / baseline |
| 2 | `Vault#absorbed?` and local sweep correctness | #524, #467 |
| 3 | `WorkbenchCollection` replaces duplicate lifecycle | #462, #498 |
| 4 | Local `Application::Deliver` + typed outcomes | #462, #520 |
| 5 | Bureau gateway + unified Waybill review policy | #464, #521 |
| 6 | Company/Portfolio registration and status query | #523 |
| 7 | Company cycle and independent couriers | #484, #459 |
| 8 | Hook validator dispatcher | #525 |
| 9 | Runtime/legacy command removal + docs/release | #462, #520, #510 |

## Acceptance criteria for the finished restructure

1. A local-only repository can `checkin` and `deliver` with no GitHub CLI invocation.
2. A Bureau repository cannot merge while CI, review, draft, freshness, or policy state is not clear.
3. A workbench merged by any supported merge style is swept after main advances.
4. Concurrent workbenches do not share mutable Runtime state; each delivery has an independent Courier and outcome.
5. Moving a governed repository never silently selects a stale path; ambiguous names are refused.
6. Every command is a thin adapter over one application service; no command calls a private method via `send`.
7. All external effects are behind ports with fake-backed unit tests and real Git/GitHub contract tests.
8. The full suite passes on a clean machine without a user-level Git configuration.
9. The public docs, class diagram, CLI help, and code describe the same architecture.
