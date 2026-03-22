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
║  Parcel (package)          →  Committed changes on a branch      ║
║  Sender                    →  The agent (AI or human)            ║
║  FedEx (the company)       →  Carson (the service)               ║
║  Warehouse                 →  Repository                         ║
║  Shelf                     →  Worktree                           ║
║  Shelf label               →  Branch name                        ║
║  Courier (employee)        →  The delivery person (one per task) ║
║  Ship to sorting facility  →  git push                           ║
║  Customs paperwork         →  Pull Request (filed with GitHub)   ║
║  Customs inspection        →  CI checks + code review            ║
║  Customs clearance         →  Checks pass, review approved       ║
║  Delivery attempt          →  Merge attempt                      ║
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

## Core Insight: What Are the Real Objects?

Through iterative design, we stripped away procedural thinking to find the essential domain concepts:

### What IS and what ISN'T a domain object

| Concept | Is it an object? | What it actually is |
|---------|-----------------|---------------------|
| **Parcel** | YES — the protagonist | The committed changes being delivered |
| **Carson** | YES — the company | The delivery service |
| **Courier** | YES — the employee | The delivery person assigned to a warehouse |
| **Delivery** | YES — the receipt | Carson's internal tracking record |
| Branch | NO — a label | A shelf label in the warehouse |
| Worktree | NO — a shelf | The physical space where agents work |
| PullRequest | NO — paperwork | A request paper filed with the GitHub bureau |
| Git | NO — a tool | A tool the courier uses, like a hand truck |
| GitHub | NO — a bureau | The external customs authority |
| Assessment | NO — not a concept | The courier reading the bureau's response |
| Freshness | NO — not a concept | A precondition check, not a domain concept |
| Runtime | NO — meaningless | Was the courier all along |

### Key design decisions and why

**PullRequest is not a domain object.** A PR is the request paper Carson files with the GitHub bureau. It's paperwork — a tracking number and a URL. GitHub requires it as part of THEIR process. It's not Carson's domain concept. The PR number is data that Carson tracks, not an object with behaviour.

**Branch is not an object.** A branch is a label on a shelf. Like a sticky note. It identifies where a parcel sits, but it has no behaviour of its own.

**Assessment is not an object.** Earlier designs tried to create Assessment as a standalone class that receives extracted data and computes readiness. That's procedural thinking — a function disguised as a class. The courier reads the bureau's response and decides what to do next. There's no "Assessment" in the FedEx world.

**Freshness is not a concept.** The "is the branch up to date with main?" check is a precondition — a guard clause in the delivery process. Post-push, GitHub reports the same thing as `mergeStateStatus: BEHIND`. It's part of the courier's customs check, not a standalone concept.

**Runtime IS the Courier.** The current `Runtime` class has no clear identity — it's a god object. But it's actually a courier assigned to a warehouse. It has a repo (the warehouse it serves), a worktree (the shelf it works at), and tools (git, gh). It picks up parcels and delivers them.

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
- Assigns couriers to warehouses
- Provides company policies (governance rules, merge methods, review gates)
- Onboards and offboards clients

## The Warehouse (a governed repo)

```
  Repository: ~/Dev/nexus
  ═══════════════════════════════════════════════════

  Shelves (worktrees), each with a label (branch):

  ┌─────────────────────────────────┐
  │  main                           │  ← the destination counter
  │ (customers collect from here)   │     (remote main at GitHub)
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
- A destination counter (main branch + remote)
- Shelves (worktrees) with labels (branches)
- Parcels on shelves (committed changes)
- Couriers working at shelves

## The Courier (currently Runtime)

The courier is the Carson employee who does the actual work. They are assigned to one warehouse and work at one shelf at a time.

```
╔═══════════════════════════════════════════════════╗
║               Carson::Courier                     ║
║            (the delivery person)                  ║
║                                                   ║
║  assigned to: a repository (the warehouse)        ║
║  works at:    a worktree/branch (a shelf)         ║
║  uses:        git, gh (tools of the trade)        ║
║                                                   ║
║  can:                                             ║
║    deliver( parcel )   — ship it to main          ║
║    monitor             — watch in-transit parcels ║
║    housekeep           — clean the warehouse      ║
║    abandon( parcel )   — return to sender         ║
║    status              — check all parcels        ║
║                                                   ║
║  knows:                                           ║
║    the warehouse config                           ║
║    which shelf they're at                         ║
║    the tracking ledger                            ║
╚═══════════════════════════════════════════════════╝
```

The courier maps to the current code:

| Current code | FedEx meaning |
|---|---|
| `Runtime.new( repo_root: )` | Assign a courier to a warehouse |
| `runtime.deliver!` | Courier delivers a parcel |
| `runtime.govern!` | Courier monitors the dispatch board |
| `runtime.housekeep!` | Courier cleans the warehouse |
| Multiple `Runtime` instances, same repo | Multiple couriers at one warehouse |
| Worktree isolation (CONCURRENCY.md) | Each courier works at their own shelf |
| Scope ownership, conflict protocol | Couriers coordinate so they don't collide |

## The Parcel (committed changes)

The parcel is the protagonist — the thing being delivered. Without a parcel, there's no delivery. Everything else exists to serve it.

```
╔═══════════════════════════════════════════════════╗
║                 Carson::Parcel                    ║
║           (the committed changes)                 ║
║                                                   ║
║  knows:                                           ║
║    branch    — the shelf label it sits on         ║
║    head      — the tip of its changes             ║
║    worktree  — the shelf it sits on               ║
║                                                   ║
║  is: the thing being delivered                    ║
║  does NOT deliver itself — the courier does that  ║
╚═══════════════════════════════════════════════════╝
```

A parcel:
- Is created by agents who commit changes onto a branch
- Sits on a shelf (worktree) with a label (branch name)
- Has concrete contents: the commits between merge-base and HEAD
- Is the INPUT to a delivery — the courier picks it up and delivers it

## The Delivery (tracking record / receipt)

The delivery is Carson's internal tracking record. It's the receipt. It records the parcel's journey through the delivery process.

```
╔═══════════════════════════════════════════════════╗
║                Carson::Delivery                   ║
║             (the tracking record)                 ║
║                                                   ║
║  knows:                                           ║
║    parcel        — what was delivered              ║
║    tracking_no   — PR number (#42)                ║
║    status        — where in the journey           ║
║    cause         — why it's held (if gated)       ║
║    summary       — human-readable state           ║
║    proof         — proof of delivery              ║
║                                                   ║
║  is: Carson's internal receipt                    ║
║  updated BY the courier, not self-updating        ║
╚═══════════════════════════════════════════════════╝
```

## The Delivery Flow

```
  Agent                    Courier                  GitHub
    │                        │                        │
    │  "deliver this parcel" │                        │
    ├───────────────────────►│                        │
    │                        │                        │
    │                        │── pick up parcel       │
    │                        │   (read branch state)  │
    │                        │                        │
    │                        │── ship it ────────────►│
    │                        │   (git push)           │
    │                        │                        │
    │                        │── file customs paper ─►│
    │                        │   (gh pr create)       │
    │                        │         ┌──────────────┤
    │                        │         │ tracking #42 │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── check customs ──────►│
    │                        │   (gh pr checks)       │
    │                        │         ┌──────────────┤
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
    │                        │── deliver please ─────►│
    │                        │   (gh pr merge)        │
    │                        │         ┌──────────────┤
    │                        │         │ accepted     │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── collect proof        │
    │                        │── write receipt        │
    │                        │                        │
    │  "delivered, receipt:"  │                        │
    │◄───────────────────────┤                        │
    │                        │                        │
```

## Delivery Status Flow (the parcel's journey)

The delivery record tracks where the parcel is in its journey:

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
                               │          │ │  failed) │
                               └──────────┘ └──────────┘
```

## All Carson Services

Every Carson command maps to a FedEx operation:

```
deliver    = Ship a parcel to main
             The core service. Pick up, ship, file paperwork,
             wait for customs, deliver, write receipt.

govern     = Dispatch center
             Monitor all in-transit parcels. When customs clears,
             attempt delivery. Reconcile tracking records.

status     = Package tracking
             "Where is my parcel?" Report the state of all
             parcels and the warehouse.

abandon    = Return to sender
             Cancel the shipment. Close the customs paperwork.
             Clean up the shelf.

housekeep  = Warehouse cleanup
             Clear delivered parcels off shelves. Remove empty
             shelves (worktrees). Sweep old labels (branches).

recover    = Salvage
             Rescue a stuck or lost parcel. Re-enter the
             delivery process from a recovery point.
```

## The Complete Domain Model

```
Carson (the company)
  │
  ├── manages many warehouses (governed repos)
  │
  └── assigns Couriers to warehouses
       │
       Courier (the delivery person — currently Runtime)
       ├── assigned to one warehouse (repo)
       ├── works at one shelf (worktree/branch)
       ├── picks up Parcels (committed changes)
       ├── delivers them:
       │     ship (push) → file paperwork (PR) →
       │     wait for customs (CI/review) → deliver (merge)
       ├── writes Delivery receipts (ledger records)
       └── uses tools: git, gh
```

Three domain classes:

```
Carson::Parcel    — the committed changes (the thing being delivered)
Carson::Courier   — the delivery person (currently Runtime)
Carson::Delivery  — the tracking record (the receipt)
```

Everything else is either:
- A label (branch name)
- A shelf (worktree)
- A tool (git, gh)
- An external bureau (GitHub)
- Paperwork (PR number, URL)

## What Pure OO Means Here

Lessons from 99 Bottles of OOP that shaped this design:

1. **Objects hold their own state.** The Parcel knows its contents. The Courier knows their warehouse. The Delivery knows its status. No data extraction between objects.

2. **No primitives where objects belong.** The six incompatible assessment hashes in the old code were primitive obsession. The courier reads the bureau's response and acts — no intermediate "Assessment" object needed.

3. **The orchestrator is thin.** The Courier creates a Parcel, delivers it, writes a Delivery. Like `Bottles` creates `BottleNumber.for(number)` and asks for lyrics. The logic lives in the objects, not the orchestrator.

4. **Dependencies are tools, not objects.** Git and GitHub are tools the courier uses. They're not domain objects. You don't create a "Hammer" class when building a house.

5. **Name from the domain, not the implementation.** Runtime → Courier. deliver.rb → the delivery service. "Assessment" → the courier reading the bureau's response. Every name comes from the FedEx metaphor, not from code structure.

## Design Status

This spec defines the domain model — what the objects ARE, what they know, how they relate. The next step is to design the classes: constructors, methods, messages, and the internal decomposition of the Courier's delivery process.
