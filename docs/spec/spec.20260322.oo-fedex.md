# Carson OO Domain Model — The FedEx Metaphor

Spec date: 2026-03-22

## Origin

Carson's `runtime/deliver.rb` grew to 1311 lines — a monolith with six tangled concerns and no clear domain model. A code review revealed the root cause: procedural thinking dressed in class syntax. No real objects, just methods shuffling data between hashes.

This spec redesigns Carson from first principles using pure OO, guided by:
- 99 Bottles of OOP (Sandi Metz)
- The FedEx delivery service metaphor (co-designed with the user)
- Rails source patterns

## The FedEx Metaphor

Carson is a delivery service company, like FedEx. It delivers committed changes from branches to remote main. The metaphor maps precisely:

```
╔══════════════════════════════════════════════════════════════════╗
║                    FedEx  →  Carson                             ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  FedEx (the company)       →  Carson (the service)               ║
║  Courier (employee)        →  Delivery person (one per task)     ║
║  Cleaner (employee)        →  Warehouse cleaner                  ║
║  Dispatcher (employee)     →  Delivery monitor                   ║
║                                                                  ║
║  Warehouse                 →  Repository                         ║
║  Shelf                     →  Worktree                           ║
║  Shelf label               →  Branch name                        ║
║  Parcel (package)          →  Committed changes on a branch      ║
║  Sender                    →  The agent (AI or human)            ║
║                                                                  ║
║  Ship to sorting facility  →  git push                           ║
║  Customs paperwork         →  Pull Request (filed with GitHub)   ║
║  Customs inspection        →  CI checks + code review            ║
║  Customs inspector         →  CI system                          ║
║  Review officer            →  Code reviewer                      ║
║  Customs clearance         →  Checks pass, review approved       ║
║  Delivery attempt          →  Merge attempt                      ║
║  Registry (accepted files) →  Remote main branch                 ║
║  Recipient signs           →  GitHub confirms merge              ║
║  Proof of delivery         →  Merge proof                        ║
║  Tracking record           →  Delivery record in ledger          ║
║  Tracking number           →  PR number (#42)                    ║
║                                                                  ║
║  Dispatch center           →  carson govern                      ║
║  Package tracking          →  carson status                      ║
║  Return to sender          →  carson abandon                     ║
║  Warehouse cleanup         →  carson housekeep                   ║
║  Salvage                   →  carson recover                     ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## Carson — The Company

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
║  EMPLOYEES (Carson's people — each a role, each a class)         ║
║  ┌────────────┐  ┌────────────┐  ┌────────────┐                 ║
║  │  Courier   │  │  Cleaner   │  │ Dispatcher  │                ║
║  │  delivers  │  │  tidies    │  │  monitors   │                ║
║  │  parcels   │  │  warehouse │  │  deliveries │                ║
║  └────────────┘  └────────────┘  └────────────┘                 ║
║                                                                  ║
║  Clients (governed repos):                                       ║
║                                                                  ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           ║
║  │  ~/AI        │  │  ~/Dev/      │  │  ~/Dev/      │  ···     ║
║  │  warehouse   │  │   nexus      │  │   carson     │           ║
║  │              │  │  warehouse   │  │  warehouse   │           ║
║  │  Courier A ──┤  │              │  │              │           ║
║  │  Courier B ──┤  │  Courier C ──┤  │  Courier D ──┤           ║
║  │              │  │              │  │              │           ║
║  └──────────────┘  └──────────────┘  └──────────────┘           ║
║                                                                  ║
║  The more clients, the better. Good business.                    ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

Carson is the company. It:
- Manages a portfolio of client warehouses (governed repos)
- Assigns employees (Courier, Cleaner, Dispatcher) to warehouses
- Provides company policies (governance rules, merge methods, review gates)
- Onboards and offboards clients

## The Warehouse (Repository)

```
  Repository: ~/Dev/nexus
  ═══════════════════════════════════════════════════

  Shelves (worktrees), each with a label (branch):

  ┌─────────────────────────────────┐
  │  main                           │  ← the local reference
  │                                 │
  └─────────────────────────────────┘

  ┌─────────────────────────────────┐
  │  feature/login                  │  ← shelf label (branch)
  │                                 │
  │    Parcel                       │  ← committed changes
  │    (3 commits, ready to ship)   │
  │                                 │
  │    Courier A is here            │  ← courier working this shelf
  └─────────────────────────────────┘

  ┌─────────────────────────────────┐
  │  fix/payment-bug                │
  │                                 │
  │    Parcel                       │
  │    (1 commit, ready to ship)    │
  │                                 │
  │    Courier B is here            │
  └─────────────────────────────────┘
```

A warehouse (repository) has:
- Shelves (worktrees) with labels (branches)
- Parcels on shelves (committed changes)
- Employees working at shelves
- A configuration (.carson.yml)

## The Bureau (GitHub) and Its Registry

The bureau is the external authority. It has two functions:

1. **Customs window** — where bureaucrats inspect parcels (CI checks, code review)
2. **Registry** — where accepted parcels are filed permanently (remote main branch)

The registry IS remote main. It's the official record. What production sees. What customers collect from. All accepted parcels live here.

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
  │  └──────────────────────────────────┘         │
  │                                              │
  └──────────────────────────────────────────────┘
```

## Employees — Each Command Has a Role

The current `Runtime` is every employee rolled into one. That's a god object. Each role should be its own class.

| Command | Role | What they do |
|---|---|---|
| `deliver` | **Courier** | Picks up parcel, ships it, files customs form, waits, delivers |
| `housekeep` | **Cleaner** | Removes empty shelves, prunes old labels, sweeps the warehouse |
| `govern` | **Dispatcher** | Monitors dispatch board, re-attempts delivery when customs clears |
| `abandon` | **Courier** | Returns parcel to sender, withdraws customs form |
| `recover` | **Courier** | Salvages a stuck parcel, re-enters the delivery process |
| `status` | **Dispatcher** | Reads the tracking board — where is every parcel? |

### The Courier

The delivery person. Assigned to a warehouse, works at a shelf, delivers parcels.

```
╔═══════════════════════════════════════════════════╗
║               Carson::Courier                     ║
║            (the delivery person)                  ║
║                                                   ║
║  assigned to: a warehouse (repository)            ║
║  works at:    a shelf (worktree/branch)           ║
║  uses:        git, gh (tools of the trade)        ║
║                                                   ║
║  can:                                             ║
║    deliver( parcel )  — ship parcel to registry   ║
║    abandon( parcel )  — return to sender          ║
║    recover( parcel )  — salvage a stuck parcel    ║
║                                                   ║
║  knows:                                           ║
║    the warehouse config                           ║
║    which shelf they're at                         ║
║    the tracking ledger                            ║
╚═══════════════════════════════════════════════════╝
```

### The Cleaner

The warehouse maintainer. Removes empty shelves, prunes stale labels.

```
╔═══════════════════════════════════════════════════╗
║               Carson::Cleaner                     ║
║          (the warehouse cleaner)                  ║
║                                                   ║
║  assigned to: a warehouse (repository)            ║
║                                                   ║
║  can:                                             ║
║    housekeep  — full warehouse sweep              ║
║    reap( shelf )  — remove one empty shelf        ║
║    prune( label ) — remove one stale label        ║
║                                                   ║
║  knows:                                           ║
║    which shelves are empty (merged worktrees)     ║
║    which labels are stale (merged branches)       ║
╚═══════════════════════════════════════════════════╝
```

### The Dispatcher

The delivery monitor. Watches all in-transit parcels, takes action when customs clears.

```
╔═══════════════════════════════════════════════════╗
║              Carson::Dispatcher                   ║
║           (the delivery monitor)                  ║
║                                                   ║
║  assigned to: a warehouse (repository)            ║
║                                                   ║
║  can:                                             ║
║    monitor     — watch all in-transit deliveries  ║
║    reconcile   — update tracking records          ║
║    status      — report the dispatch board        ║
║                                                   ║
║  knows:                                           ║
║    all active tracking records (deliveries)       ║
║    the bureau's current response for each         ║
╚═══════════════════════════════════════════════════╝
```

## Every Concept Is an Object

| Object | What it IS | What it knows | What it does |
|---|---|---|---|
| **Carson** | The company | Portfolio of warehouses | Assigns employees, onboards clients |
| **Courier** | Delivery person | Their warehouse, their shelf | Delivers parcels, files customs forms |
| **Cleaner** | Warehouse cleaner | The warehouse state | Removes shelves, prunes labels |
| **Dispatcher** | Delivery monitor | All tracking records | Watches, reconciles, reports |
| **Warehouse** | The repository | Path, config, shelves | Holds shelves and parcels |
| **Shelf** | A worktree | Path, label, occupant | Holds parcels, can be removed |
| **Label** | A branch name | Name, merged status | Identifies a shelf |
| **Parcel** | Committed changes | Branch, head, commits | The thing being delivered |
| **Customs Form** | A Pull Request | Number, URL, state | Filed with bureau, gets processed |
| **Delivery** | Tracking record | Status, cause, proof | Records the parcel's journey |
| **Bureau** | GitHub | Bureaucrats, registry | Inspects, accepts/rejects parcels |
| **Inspector** | CI system | Test results | Inspects parcel quality |
| **Review Officer** | Code reviewer | Review decision | Reviews parcel contents |
| **Registry** | Remote main | All accepted parcels | The official record — what production sees |

## The Delivery Flow

```
  Agent                    Courier                  Bureau (GitHub)
    │                        │                        │
    │  "deliver this parcel" │                        │
    ├───────────────────────►│                        │
    │                        │                        │
    │                        │── pick up Parcel       │
    │                        │   from Shelf           │
    │                        │                        │
    │                        │── ship it ────────────►│
    │                        │   (git push)           │
    │                        │                        │
    │                        │── file Customs Form ──►│
    │                        │   (gh pr create)       │
    │                        │         ┌──────────────┤
    │                        │         │ tracking #42 │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── check customs ──────►│
    │                        │                  ┌─────┤
    │                        │                  │     │
    │                        │          Inspector     │
    │                        │          checks...     │
    │                        │          Review Officer │
    │                        │          reviews...    │
    │                        │                  │     │
    │                        │         ┌────────┘     │
    │                        │         │ CI running   │
    │                        │◄────────┘              │
    │                        │         ·              │
    │                        │       (wait)           │
    │                        │         ·              │
    │                        │── check customs ──────►│
    │                        │         ┌──────────────┤
    │                        │         │ cleared      │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── please accept ──────►│
    │                        │   (gh pr merge)        │
    │                        │                        │
    │                        │              ┌─────────┤
    │                        │              │ Parcel  │
    │                        │              │ entered │
    │                        │              │ into    │
    │                        │              │ Registry│
    │                        │         ┌────┘         │
    │                        │         │ accepted     │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── collect proof        │
    │                        │── write Delivery       │
    │                        │   record (receipt)     │
    │                        │                        │
    │  "delivered, receipt:" │                        │
    │◄───────────────────────┤                        │
    │                        │                        │
```

## Delivery Status Flow (the parcel's journey)

```
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ Picked   │────►│ Shipped  │────►│  In      │
  │ up       │     │ (pushed) │     │ Customs  │
  └──────────┘     └──────────┘     │ (PR filed)│
                                     └────┬─────┘
                                          │
                              ┌───────────┼───────────┐
                              ▼           ▼           ▼
                        ┌──────────┐ ┌──────────┐ ┌──────────┐
                        │ Held     │ │ Cleared  │ │ Rejected │
                        │ (CI fail,│ │ (ready)  │ │ (closed) │
                        │  review  │ └────┬─────┘ └──────────┘
                        │  pending)│      │
                        └────┬─────┘      ▼
                             │      ┌──────────┐
                             │      │Delivering│
                             │      │(merging) │
                             │      └────┬─────┘
                             │           │
                             │      ┌────┴─────┐
                             │      ▼          ▼
                             │ ┌──────────┐ ┌──────────┐
                             └►│Delivered │ │ Bounced  │
                               │(merged)  │ │ (merge   │
                               │ → entered│ │  failed) │
                               │ Registry │ └──────────┘
                               └──────────┘
```

## The Cleaner's Work

```
  Cleaner                    Warehouse
    │                          │
    │── scan for empty ───────►│
    │   shelves                │
    │         ┌────────────────┤
    │         │ 3 empty shelves│
    │◄────────┘                │
    │                          │
    │── remove shelf ─────────►│  (git worktree remove)
    │── remove shelf ─────────►│
    │── remove shelf ─────────►│
    │                          │
    │── scan for stale ───────►│
    │   labels                 │
    │         ┌────────────────┤
    │         │ 5 stale labels │
    │◄────────┘                │
    │                          │
    │── prune label ──────────►│  (git branch -d)
    │── prune label ──────────►│
    │   ···                    │
    │                          │
```

## The Dispatcher's Work

```
  Dispatcher              Delivery Records        Bureau
    │                          │                     │
    │── read dispatch board ──►│                     │
    │         ┌────────────────┤                     │
    │         │ 2 in-transit   │                     │
    │◄────────┘                │                     │
    │                          │                     │
    │── check customs ──────────────────────────────►│
    │   for each parcel        │                     │
    │                          │         ┌───────────┤
    │                          │         │ #42 clear │
    │                          │         │ #43 held  │
    │◄───────────────────────────────────┘           │
    │                          │                     │
    │── update record ────────►│  (#42 → cleared)    │
    │── update record ────────►│  (#43 → still held) │
    │                          │                     │
    │── attempt delivery ──────────────────────────►│
    │   for #42                │                     │
    │                          │         ┌───────────┤
    │                          │         │ accepted  │
    │◄───────────────────────────────────┘           │
    │                          │                     │
    │── update record ────────►│  (#42 → delivered)  │
    │                          │                     │
```

## Why Runtime Was Wrong

Runtime was every employee rolled into one person doing every job. That's not a person — it's a department pretending to be one employee. In OO, each role is its own object with its own identity, its own state, its own responsibilities.

| What Runtime did | Who should do it |
|---|---|
| `deliver!` | **Courier** — delivers parcels |
| `govern!` | **Dispatcher** — monitors deliveries |
| `housekeep!` | **Cleaner** — tidies the warehouse |
| `abandon!` | **Courier** — returns parcel to sender |
| `recover!` | **Courier** — salvages stuck parcels |
| `status` | **Dispatcher** — reads the dispatch board |
| held git_run, gh_run | Tools — each employee uses them |
| held config, ledger | Company resources — shared by employees |

## Design Principles Applied

1. **Everything is an object.** Worktrees, branches, PRs, GitHub, CI, reviewers — all objects with identity, state, and behaviour. Not "just labels" or "just paperwork."

2. **Objects hold their own state.** The Parcel knows its contents. The Customs Form knows its status. The Shelf knows its label. No data extraction between objects.

3. **Each role is its own class.** Courier, Cleaner, Dispatcher — not one god-class doing everything. Each has a clear identity and clear responsibilities.

4. **The orchestrator is thin.** Each employee creates domain objects and sends them messages. The Courier creates a Customs Form and files it. The Cleaner scans Shelves and removes empty ones.

5. **Dependencies are tools, not identity.** Git and gh are tools employees use. They're not domain objects. They're implementation detail inside the employees.

6. **Name from the domain.** Every name comes from the FedEx metaphor. Runtime → Courier/Cleaner/Dispatcher. deliver.rb → the Courier's delivery process. "Assessment" → the Courier reading the bureau's response. "Freshness" → a precondition check, not a concept.

## Design Status

This spec defines the complete domain model:
- What the objects ARE
- What they know
- How they relate
- How they interact (sequence flows)

The next step is to design the classes: constructors, methods, messages, and the mapping from current code to new objects.
