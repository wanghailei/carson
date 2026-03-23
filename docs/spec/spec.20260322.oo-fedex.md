# Carson OO Domain Model — The FedEx Metaphor

Spec date: 2026-03-22
Updated: 2026-03-23

## Origin

Carson's `runtime/deliver.rb` grew to 1311 lines — a monolith with six tangled concerns and no clear domain model. A code review revealed the root cause: procedural thinking dressed in class syntax. No real objects, just methods shuffling data between hashes.

This spec redesigns Carson from first principles using pure OO, guided by:
- 99 Bottles of OOP (Sandi Metz)
- The FedEx delivery service metaphor (co-designed with the user)
- Rails source patterns

## The FedEx Metaphor

Carson is a delivery service company, like FedEx. It delivers committed changes from branches to the remote main registry. Every public class name, method name, and command name uses story language. Git and GitHub terms are hidden inside method bodies and private variables.

```
╔══════════════════════════════════════════════════════════════════╗
║                    FedEx  →  Carson                             ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  FedEx (the company)       →  Carson (the company, the CLI)      ║
║  Courier (robot employee)  →  Carson::Courier                    ║
║                                                                  ║
║  Warehouse (intelligent)   →  Carson::Warehouse                  ║
║  Shelf                     →  Carson::Shelf                      ║
║  Shelf label               →  Carson::Label                     ║
║  Parcel (package)          →  Carson::Parcel                     ║
║  Waybill (shipping doc)    →  Carson::Waybill                    ║
║  Tracking record           →  Carson::Delivery                   ║
║  Sender                    →  The agent (AI or human)            ║
║                                                                  ║
║  Bureau (customs office)   →  GitHub                             ║
║  Customs inspector         →  CI system                          ║
║  Review officer            →  Code reviewer                      ║
║  Registry                  →  Remote main branch                 ║
║  Client standard           →  Registry state (what rebase checks)║
║                                                                  ║
║  Ship                      →  git push (hidden inside)           ║
║  File waybill              →  gh pr create (hidden inside)       ║
║  Customs inspection        →  CI checks + code review            ║
║  Accept into registry      →  gh pr merge (hidden inside)        ║
║  Proof of delivery         →  Merge proof                        ║
║  Pack                      →  git add + git commit               ║
║  Submit compliance         →  Template sync                      ║
║  Sweep                     →  Worktree/branch cleanup            ║
║  Settle                    →  Push to remote backup (local mode) ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## Architecture — Three Roles

The previous design had four roles (Courier, Cleaner, Dispatcher). Refined to three:

1. **Carson Co.** — the company itself handles dispatch (monitoring, tracking). No separate Dispatcher. In an AI-run company, the company IS the dispatcher.
2. **Courier** — a robot that delivers parcels.
3. **Warehouse** — intelligent and autonomous. Packs parcels, checks compliance, sweeps itself.

```
╔══════════════════════════════════════════════════════════════════╗
║                                                                  ║
║                        CARSON & CO.                              ║
║                    Delivery Services Ltd.                        ║
║                                                                  ║
║  "We deliver your changes. Safely. Every time."                  ║
║                                                                  ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  THE COMPANY (Carson module — CLI + dispatch)                    ║
║  ┌─────────────────────────────────────────────┐                 ║
║  │  Routes commands to employees               │                 ║
║  │  Monitors all deliveries (no Dispatcher)    │                 ║
║  │  Tracks parcel status                       │                 ║
║  │  Manages warehouse portfolio                │                 ║
║  └─────────────────────────────────────────────┘                 ║
║                                                                  ║
║  ROBOT EMPLOYEES                                                 ║
║  ┌────────────┐                                                  ║
║  │  Courier   │  ← delivers parcels to the bureau                ║
║  │  (robot)   │                                                  ║
║  └────────────┘                                                  ║
║                                                                  ║
║  INTELLIGENT WAREHOUSES (self-managing)                           ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           ║
║  │  ~/AI        │  │  ~/Dev/      │  │  ~/Dev/      │  ···     ║
║  │              │  │   nexus      │  │   carson     │           ║
║  │  Packs       │  │              │  │              │           ║
║  │  Sweeps      │  │  Packs       │  │  Packs       │           ║
║  │  Complies    │  │  Sweeps      │  │  Sweeps      │           ║
║  │              │  │  Complies    │  │  Complies    │           ║
║  └──────────────┘  └──────────────┘  └──────────────┘           ║
║                                                                  ║
║  The more clients, the better. Good business.                    ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## The Warehouse — Intelligent and Autonomous

The warehouse manages itself. It packs parcels, checks its own compliance, and sweeps up. No separate Cleaner employee needed.

```
╔═══════════════════════════════════════════════════╗
║          Carson::Warehouse                        ║
║      (intelligent, self-managing)                 ║
║                                                   ║
║  knows:                                           ║
║    path, current_label, current_head              ║
║    main_label, bureau_address                     ║
║    shelves, labels                                ║
║                                                   ║
║  can:                                             ║
║    pack!( message: )        — prepare a parcel    ║
║    submit_compliance!       — ensure templates ok ║
║    sweep!                   — clean shelves/labels║
║    ship( parcel )           — send to bureau      ║
║    fetch_latest             — get registry state  ║
║    based_on_latest?( parcel ) — production check  ║
║    update_standard!         — rebase to latest    ║
║    settle!                  — push to backup      ║
║    label_absorbed?( name )  — merged into main?   ║
║                                                   ║
╚═══════════════════════════════════════════════════╝
```

### Production Standard

A parcel's content is produced based on the **client's standard** (the registry state). Before shipping, the courier checks whether the parcel was **based on the latest standard**.

```ruby
warehouse.based_on_latest?( parcel )  # produced to latest client standard?
```

This is verified at two points:
1. **Before shipping** — the courier checks. If not based on latest, blocked.
2. **After client refusal** — the warehouse updates its production standard:

```ruby
warehouse.update_standard!  # rebase onto latest registry state
```

## The Bureau and Its Registry

The bureau (GitHub) has two functions: customs inspection and the official registry. The registry IS remote main — where all accepted parcels are filed permanently.

```
  The Bureau (GitHub)
  ┌──────────────────────────────────────────────┐
  │                                              │
  │  Customs Window                              │
  │  ┌─────────────┐  ┌──────────────────┐       │
  │  │ Inspector   │  │ Review Officer   │       │
  │  │ (CI)        │  │ (code review)    │       │
  │  └──────┬──────┘  └────────┬─────────┘       │
  │         │                  │                  │
  │         └──────┬───────────┘                  │
  │                ▼                              │
  │  ┌──────────────────────────────────┐         │
  │  │         Registry (main)          │         │
  │  │                                  │         │
  │  │  All accepted parcels live here  │         │
  │  │  This is what production sees    │         │
  │  │  This IS the client standard     │         │
  │  └──────────────────────────────────┘         │
  │                                              │
  └──────────────────────────────────────────────┘
```

## The Courier — A Robot

The courier is a robot employee. Assigned to a warehouse. Delivers parcels to the bureau.

```
╔═══════════════════════════════════════════════════╗
║             Carson::Courier                       ║
║           (the delivery robot)                    ║
║                                                   ║
║  assigned to: a warehouse                         ║
║  uses:        warehouse methods + waybill          ║
║                                                   ║
║  can:                                             ║
║    deliver( parcel )  — ship parcel to registry   ║
║    return( parcel )   — return to sender           ║
║    salvage( parcel )  — rescue stuck parcel        ║
║                                                   ║
╚═══════════════════════════════════════════════════╝
```

### Situations the Courier Encounters

Every situation is numbered. The number appears as a code comment on the method that handles it.

```
01. Parcel on main          — cannot deliver from the destination
02. Parcel behind standard  — not based on client's latest standard
03. Shipping fails          — warehouse couldn't push to bureau
04. Waybill filing fails    — bureau rejected the paperwork
05. Inspector pending       — customs inspection (CI) still running
06. Inspector fails         — customs inspection (CI) failed
07. Review officer pending  — review still in progress
08. Review changes requested — officer wants corrections
09. Merge conflict          — parcel conflicts with registry contents
10. Behind standard (post)  — standard changed since shipping
11. Policy block            — bureau regulation prevents acceptance
12. Draft waybill           — form not finalised
13. Mergeability pending    — bureau still processing eligibility
14. Acceptance succeeds     — parcel enters registry. Delivered.
15. Acceptance fails        — classify why, retry or hold
16. Bureau unreachable      — cannot contact the bureau
17. Already delivered       — parcel already in registry
18. Waybill closed          — cancelled externally
19. Watch window expires    — end of shift. Deferred.
```

## Commands — All Story Language

| Command | Who handles | Meaning |
|---|---|---|
| `carson deliver` | Courier | Ship parcel to the registry |
| `carson return` | Courier | Return parcel to sender |
| `carson salvage` | Courier | Rescue a stuck parcel |
| `carson monitor` | Carson Co. | Watch over all parcels continuously |
| `carson track` | Carson Co. | Where is everything right now? |
| `carson sweep` | Warehouse | Clean shelves and stale labels |

## Every Concept Is an Object

| Object | What it IS | What it knows | What it does |
|---|---|---|---|
| **Carson** | The company | Portfolio of warehouses | Routes commands, dispatches, monitors |
| **Courier** | Delivery robot | Its warehouse | Delivers, returns, salvages parcels |
| **Warehouse** | Intelligent repo | Path, config, shelves, labels | Packs, ships, sweeps, checks compliance |
| **Parcel** | Committed changes | Label, head, shelf | The thing being delivered |
| **Waybill** | Shipping document | Tracking number, bureau response | Filed with bureau, tracks approval |
| **Delivery** | Tracking record | Status, cause, proof | Records the parcel's journey |
| **Shelf** | A worktree | Path, label, occupant | Holds parcels, can be removed |
| **Label** | A branch name | Name, absorbed status | Identifies a shelf |
| **Bureau** | GitHub | Bureaucrats, registry | Inspects, accepts/rejects parcels |
| **Inspector** | CI system | Test results | Inspects parcel quality |
| **Review Officer** | Code reviewer | Review decision | Reviews parcel contents |
| **Registry** | Remote main | All accepted parcels | The client standard |

## The Delivery Flow

```
  Agent                    Courier                  Bureau (GitHub)
    │                        │                        │
    │  "deliver this parcel" │                        │
    ├───────────────────────►│                        │
    │                        │                        │
    │                        │── check: parcel        │
    │                        │   based on latest      │
    │                        │   client standard?     │
    │                        │                        │
    │                        │── ship ───────────────►│
    │                        │                        │
    │                        │── file Waybill ───────►│
    │                        │         ┌──────────────┤
    │                        │         │ tracking #42 │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── check customs ──────►│
    │                        │          Inspector     │
    │                        │          Review Officer │
    │                        │         ┌──────────────┤
    │                        │         │ cleared      │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── please accept ──────►│
    │                        │              ┌─────────┤
    │                        │              │ Parcel  │
    │                        │              │ entered │
    │                        │              │ Registry│
    │                        │         ┌────┘         │
    │                        │         │ accepted     │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── collect proof        │
    │                        │── write Delivery       │
    │                        │                        │
    │  "delivered, receipt:" │                        │
    │◄───────────────────────┤                        │
    │                        │                        │
```

## Destination Modes (Future)

Currently Carson operates in **remote-centred** mode: parcels are shipped to the bureau, inspected, and accepted into the registry (remote main). The local main is synced from the registry after acceptance.

A future **local-centred** mode merges parcels locally — the remote is a synced backup for future settlement, like a client storing parcels in Carson's warehouse for futures trading.

```
Remote-centred (current):
  ship → waybill → customs → registry → sync local main

Local-centred (future):
  merge locally → settle! (push to remote backup for settlement)
```

The Warehouse and Courier must be designed so the destination mode is injectable, not baked in.

## Runtime Is Not Needed

Once the employees and domain objects absorb Runtime's responsibilities, Runtime dissolves:

| Runtime provides | Who takes over |
|---|---|
| `git_run` | Warehouse (wraps git internally) |
| `gh_run` | Waybill (wraps gh internally) |
| Config | Warehouse loads it |
| Ledger | Delivery hides it |
| Output streams | Carson handles rendering |
| Template management | Warehouse compliance |
| Review gate | Injected into Waybill |
| Exit codes | Defined on each employee |

## File Layout

```
lib/carson/
  carson.rb              ← the company (entry point, routing, dispatch)
  courier.rb             ← the delivery robot
  warehouse.rb           ← the intelligent repository
  parcel.rb              ← the committed changes
  waybill.rb             ← the shipping document
  delivery.rb            ← the tracking record
  shelf.rb               ← the worktree
  label.rb               ← the branch
  config.rb              ← warehouse configuration
  ledger.rb              ← filing cabinet (hidden behind Delivery)
```

## Implementation Status

### Phase 1 — Foundation (done)

| Class | Lines | Tests | Status |
|---|---|---|---|
| Carson::Parcel | 24 | 7 tests, 8 assertions | Merged |
| Carson::Warehouse | 105 | 22 tests, 33 assertions | Merged |
| Carson::Waybill | 196 | 16 tests, 29 assertions | Merged |
| Carson::Courier | 160 | 3 tests, 8 assertions | Merged |
| Wiring (carson.rb) | +3 | — | Merged |

All 531 tests pass. New classes work alongside existing code.

### Phase 2 — Make it live (next)

1. Rename `includes_latest?` → `based_on_latest?`
2. Add `update_standard!` (rebase onto latest registry)
3. Add `warehouse.pack!` (absorb commit preparation)
4. Add `warehouse.submit_compliance!` (absorb template sync)
5. Add `warehouse.sweep!` (absorb housekeep)
6. Add `settle!` (local-centred backup push)
7. Mature Courier to handle all 19 situations with ledger integration
8. Make `deliver!` delegate to Courier
9. Carson Co. absorbs `monitor` and `track` (no Dispatcher)
10. Rename commands: govern→monitor, housekeep→sweep, abandon→return, recover→salvage, status→track
11. Remove Runtime — absorbed by domain objects

## Design Principles

1. **Everything is an object.** Warehouses, shelves, labels, waybills, the bureau, inspectors — all objects with identity, state, and behaviour.
2. **One set of concepts.** Story language everywhere in public interfaces. Git and GitHub hidden inside.
3. **The warehouse manages itself.** Packs, sweeps, checks compliance. No separate Cleaner.
4. **Carson dispatches directly.** No separate Dispatcher. The company IS the dispatcher.
5. **The courier is a robot.** Every employee is automated.
6. **Objects hold their own state.** No data extraction between objects.
7. **Production standard.** Parcels must be based on the client's latest standard before shipping.
8. **Destination mode is injectable.** Remote-centred now, local-centred later.
9. **Runtime dissolves.** Its responsibilities are absorbed by the objects they belong to.
10. **Numbered situations.** Every courier situation has a code number in the comments.

## References

- 99 Bottles of OOP (Sandi Metz, Katrina Owen, TJ Stankus)
- Rails source patterns (github.com/rails/rails)
- ~/AI/core/CODING/RUBY.md § Pure OO Design
- ~/AI/docs/study/ruby-pure-oo.md
