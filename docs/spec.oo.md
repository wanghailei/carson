# Carson OO — A FedEx Metaphor

Spec date: 2026-03-22
Updated: 2026-03-24

## 1. Origin

Carson's `runtime/deliver.rb` grew to 1311 lines — a monolith with six tangled concerns and no clear domain model. A code review revealed the root cause: procedural thinking dressed in class syntax. No real objects, just methods shuffling data between hashes.

This spec redesigns Carson from first principles using pure OO, guided by:
- 99 Bottles of OOP (Sandi Metz, Katrina Owen, TJ Stankus)
- The FedEx delivery service metaphor (co-designed with the user)
- Rails source patterns (github.com/rails/rails)
- `~/AI/core/CODING/RUBY.md` § Pure OO Design
- `~/AI/docs/study/ruby-pure-oo.md`

## 2. The Product Surface

Carson is no longer designed as a thin wrapper around Git nouns.

For an agent working with Carson daily, the public surface is:

| Command | Who handles | Meaning |
|---|---|---|
| `carson checkin` | Carson Co. → Warehouse | Ask the Warehouse to prepare a fresh workbench from the latest standard |
| `carson deliver` | Carson Co. → Courier | Send the current parcel to the Bureau |
| `carson checkout` | Carson Co. → Warehouse | Ask the Warehouse to release the workbench and local custody when safe |

These are the public agent verbs. Worktrees, branches, and stash entries remain real, but they are warehouse machinery behind the surface.

### Why Runtime Was Wrong

Runtime mixed company work, warehouse work, and courier work into one object. The fix is not to make Runtime smaller. The fix is to move each responsibility to the object that actually owns it.

| Concern | Real owner |
|---|---|
| command routing and rendering | **Carson Co.** |
| repo-local state (workbench, branch, stash, cleanliness, occupancy) | **Warehouse** |
| parcel delivery orchestration | **Courier** |
| shipping document state | **Waybill** |
| delivery tracking state | **Delivery** |
| compliance and local standard management | **Warehouse** |

A worktree, a branch, or a stash entry is not a runtime concern but warehouse state.

Runtime disappears when those responsibilities are absorbed by the objects they belong to.

## 3. The FedEx Metaphor

Carson is a delivery service company, like FedEx. It delivers committed changes from branches to the remote main registry. Every public class name, method name, and command name uses story language. Git and GitHub terms are hidden inside method bodies and private variables.

```
╔══════════════════════════════════════════════════════════════════╗
║                    FedEx  →  Carson                              ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  FedEx (the company)       →  Carson Co.                         ║
║  Courier (robot employee)  →  Carson::Courier                    ║
║                                                                  ║
║  Warehouse (intelligent)   →  Carson::Warehouse                  ║
║  Workbench                 →  passive worktree object            ║
║  Workbench label           →  branch name                        ║
║  Parcel (package)          →  Carson::Parcel                     ║
║  Waybill (shipping doc)    →  Carson::Waybill                    ║
║  Tracking record           →  Carson::Delivery                   ║
║  Sender / Client           →  The agent (AI or human)            ║
║                                                                  ║
║  Bureau (registry office)  →  GitHub, including its registry     ║
║  Bureaucrat (CI)           →  CI system                          ║
║  Bureaucrat (review)       →  Code reviewer                      ║
║  Registry                  →  Remote main branch                 ║
║  Production standard       →  Registry state (what rebase checks)║
║                                                                  ║
║  Pack                      →  git add + git commit               ║
║  Submit compliance         →  Template sync                      ║
║  Ship                      →  git push (hidden inside)           ║
║  File waybill              →  gh pr create (hidden inside)       ║
║  Bureau check              →  CI checks + code review            ║
║  Accept into registry      →  gh pr merge (hidden inside)        ║
║  Proof of delivery         →  Merge proof                        ║
║  Sweep                     →  Workbench/branch/stash cleanup     ║
║  Settle                    →  Push to remote backup (local mode) ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

### Two Languages

Carson speaks two languages. Mixing them is a defect.

**Story language** is for Carson's internal domain model — source code, class names, method names, architecture docs, code comments. This is how Carson's developers and maintainers think about the system. Warehouse, Parcel, Courier, Bureau, Workbench.

**Technical language** is for Carson's output — CLI messages, error text, JSON payloads, recovery instructions. This is how Carson's clients (coding agents and humans) understand the system. Branch, PR, CI, merge, main, rebase.

| Surface | Language | Audience |
|---|---|---|
| Source code (class/method names) | Story | Carson developers |
| Code comments | Story | Carson developers |
| Architecture docs (this spec) | Story | Carson developers |
| CLI output | Technical | Agents and humans |
| Error messages | Technical | Agents and humans |
| JSON payloads | Technical | Agents |
| Recovery instructions | Technical | Agents and humans |

**Rationale:** When FedEx tells you your package status, they don't say "the bureaucrat is reviewing your parcel at the registry." They say "your package is at the sorting facility, expected delivery Tuesday." They speak the customer's language, not their internal operational language. Carson's clients are coding agents. They understand "PR #437 — waiting for CI checks", not "held — pending at registry."

**Use case:** A Claude agent runs `carson deliver` and gets back `"branch is behind origin/main"`. It knows exactly what to do — `git rebase origin/main`. If it got "parcel is behind the production standard", it would need to decode the metaphor before acting. The metaphor serves the developer reading source code; the output serves the agent executing commands.

## 4. Design Principles

1. **Everything is an object.** Warehouses, workbenches, parcels, waybills, deliveries, the Bureau, and Couriers all have identity, state, and behaviour.
2. **Two languages, never mixed.** Story language in source code and architecture; technical language in output and recovery guidance.
3. **Carson Co. co-ordinates and monitors.** The company routes commands, monitors filed deliveries, and informs clients when delivery state changes.
4. **The Warehouse owns repo-local custody.** Workbench, branch, stash, cleanliness, occupancy, pruning, and repair all belong there.
5. **The Courier is a robot.** It does one errand, reports back, and waits at the Bureau while the Bureau checks the parcel.
6. **Objects hold their own state.** No data extraction between objects.
7. **Production standard matters.** Parcels must be based on the latest standard before shipping. Query it, fix against it, and receive it after acceptance.
8. **One workbench per parcel.** Workbenches are disposable; the registry is permanent. New work starts on a fresh workbench from the updated standard.
9. **Destination mode is injectable.** Remote-centred now, local-centred later.
10. **Runtime dissolves.** Its responsibilities are absorbed by the objects they belong to.
11. **Numbered situations.** Every courier situation has a code number in the comments.

## 5. The Core Boundary

Carson is organised around three roles:

1. **Carson Co.** — the company and public surface for agents. It routes commands, renders output, monitors parcel delivery states, and co-ordinates work between the Warehouse and the Courier.
2. **Courier** — the delivery worker. It ships parcels to the Bureau, waits while the Bureau checks them, and reports the delivery outcome.
3. **Warehouse** — the local repository authority. It owns workbenches and all other repo-local state, prepares workbenches, packs parcels, checks compliance, and manages cleanup.

| Object | What it is | What it knows | What it does |
|---|---|---|---|
| **Carson Co.** | The company and public surface for agents | command routing, rendering, co-ordination, delivery-state monitoring | routes commands, monitors delivery states, and assigns work |
| **Warehouse** | Local repository authority | workbenches, branches, stash, cleanliness, occupancy, standard | prepares workbenches, packs parcels, checks compliance, repairs and sweeps local state |
| **Workbench** | A passive place in the Warehouse | path, branch, prunable reason | shows state only |
| **Parcel** | Committed changes | branch, head, workbench | the thing being delivered |
| **Waybill** | Shipping document | PR identity and bureau findings | passive data object |
| **Delivery** | Tracking record | status, cause, proof | passive ledger record |
| **Courier** | Delivery worker | warehouse, merge method, poll interval | ships parcels and waits at the Bureau |
| **Bureau** | GitHub, including its registry | review state, CI state, registry state | checks parcels and accepts them into the registry |

**Boundary rule:** anything inside the repository is managed by the Warehouse. Anything about committed parcel delivery is managed by Carson Co. and conducted by Couriers.

The **Registry** is not a peer object in this boundary table. It is the Bureau's registry: remote main, where accepted parcels live and where the production standard is defined.

## 6. Carson Co.

Carson Co. is both the company and the public surface for agents. It is responsible for routing commands, rendering output, monitoring filed deliveries, and informing clients when delivery state changes. It can serve many warehouses at once.

### Bureau Feedback Model

The bureau processes asynchronously — CI runs take minutes, reviews take hours. The courier waits at the registry while bureaucrats check the parcel, polling periodically (up to `MAX_CHECKS_AT_BUREAU = 6` times, with configurable poll interval). If the checks clear, the courier reports the definitive answer. If checks are exhausted, the courier reports "filed" — the parcel is at the Bureau, bureaucrats are still checking. Carson Co. is responsible for follow-up notification when the Bureau's state changes.

```
Bureau state changes (CI passes, review approved, PR merged)
  → Carson Co. receives the feedback
  → Carson Co. informs the client (agent) IMMEDIATELY
  → If work is needed (merge ready), Carson Co. dispatches courier
  → If no work needed (just status), no courier dispatch
```

**The client is the priority, not the courier.** When the registry clears a parcel, the most important thing is telling the sender (agent) that their changes are through. The courier is a tool — it gets dispatched when there's an errand. The client gets informed because they're waiting.

| Event | Who needs to know first | Then what |
|---|---|---|
| CI passes | **Client** — "your PR is green" | Courier dispatched if merge-ready |
| PR merged | **Client** — "your changes are in main" | Warehouse receives latest standard |
| CI fails | **Client** — "CI failed, here's why" | No courier needed |
| Review comments | **Client** — "review comments on your PR" | No courier needed |

**Use case:** An agent runs `carson deliver` at 2pm. CI takes 3 minutes. The courier files the waybill, waits at the Bureau while bureaucrats check (polling periodically). CI passes within the poll window. The courier merges and reports: "Merged. Local main synced." If CI takes longer than the poll window, the courier reports "filed — waiting for CI checks" and the agent continues other work. When CI passes, Carson Co. detects the change, informs the agent: "PR #437 — CI passed, merging."

**Anti-pattern (old design):** The old design had two problems: (a) a 30-second timeout was too short — CI takes minutes, so the courier always timed out, and (b) the recovery action was "re-deliver" (`carson deliver` again) instead of checking the existing parcel. The agent had to manually re-run delivery against a parcel that was already at the Bureau being checked. The fix: the courier waits at the Bureau with enough patience, and if checks are exhausted, reports the parcel as "filed" with the tracking number — not "failed." Carson Co. then owns the follow-up monitoring work.

### Output

Output is for agents by default. Human is the second class.

JSON is the primary output format — agents consume it. Text is secondary. The output concern does not belong on the Courier or any domain object. It belongs at the company level — Carson Co. formats the result for whoever is listening.

```ruby
result = courier.deliver( parcel )
Carson.report( result, format: :json )  # default — agents
Carson.report( result, format: :text )  # secondary — humans
```

The Courier returns a result hash. Carson Co. decides how to render it. Domain objects never know or care about output format.

Output uses **technical language** — the client's language. `Waybill#hold_summary` and `Carson.report` surface hold reasons directly in client language:

| Internal reason | Client sees | Recovery |
|---|---|---|
| `pending_at_bureau` | "Waiting for CI checks." | "No further agent action — Carson Co. monitors filed deliveries." |
| `failed_at_bureau` | "CI checks failed." | "Fix failures, push, and run `carson deliver`." |
| `error_at_bureau` | "Unable to assess CI checks." | "Re-run CI or run `carson deliver`." |
| `merge_conflict` | "Merge conflict with main." | "Rebase on main, resolve conflicts, and re-deliver." |
| `behind_bureau` | "Branch is behind main." | "Run `git rebase origin/main` and re-deliver." |
| `policy_block` | "Blocked by branch protection rules." | "Check branch protection settings." |
| `draft` | "PR is still a draft." | "Mark PR as ready for review." |
| `mergeability_pending` | "GitHub is calculating mergeability." | "No further agent action — Carson Co. monitors filed deliveries." |

### Output Is Commands

Carson's output is for agents. Every **actionable** held or blocked delivery message includes executable recovery commands. When there is no agent action to take, Carson Co. must say so plainly.

```
⧓ CI checks failed.
  → carson deliver

⧓ Merge conflict with origin/main.
  → git rebase origin/main
  → carson deliver

⧓ Parcel filed at the Bureau.
  → no further agent action — Carson Co. monitors delivery state changes.
```

Messages use the configured git remote and main branch so the client sees exact refs, not placeholders.

**Delivery progress** — the courier reports what it's doing during polling:

```
⧓ Carson is delivering committed changes on branch oo/feature to origin/main...
⧓ PR #440  https://github.com/…/pull/440
⧓ waiting for bureaucrats to check (1/6)...
⧓ waiting for bureaucrats to check (2/6)...
⧓ Merged.
```

## 7. The Warehouse Domain

### The Warehouse — Intelligent and Autonomous

The Warehouse manages itself. It packs parcels, checks its own compliance, knows its own cleanliness, and sweeps up. Repo-local state lives here.

```
╔═══════════════════════════════════════════════════╗
║          Carson::Warehouse                        ║
║      (intelligent, self-managing)                 ║
║                                                   ║
║  knows:                                           ║
║    path, current_label, current_head              ║
║    main_label, bureau_address                     ║
║    workbenches, branches, stash                   ║
║                                                   ║
║  can:                                             ║
║    clean?                      — floor clean?     ║
║    pack!( message: )           — prepare a parcel ║
║    submit_compliance!          — templates ok?    ║
║    sweep!                      — clean local state║
║    fetch_latest                — get registry     ║
║    based_on_latest_standard?   — production check ║
║    rebase_on_latest_standard!  — rebase workbench ║
║    receive_latest_standard!    — update local std ║
║    settle!                     — push to backup   ║
║    label_absorbed?( name )     — merged into main?║
║                                                   ║
╚═══════════════════════════════════════════════════╝
```

### Warehouse Cleanliness

The Warehouse knows whether its floor is clean — whether there are uncommitted changes on the current workbench. This is warehouse knowledge, not the courier's concern.

```ruby
warehouse.clean?  # no uncommitted changes?
```

**Rationale:** In FedEx, the courier doesn't inspect the warehouse floor before picking up a parcel. The Warehouse manages itself — it knows if the floor is clean or if there's unpacked material lying around. In Carson, "dirty working tree" is a warehouse state, not a delivery concern. The Courier asks the Warehouse; it doesn't run `git status` itself.

**Use case:** An agent calls `carson deliver --commit "add login feature"` but the working tree is already clean (nothing to commit). The Warehouse reports "I'm clean — there's nothing to pack." The Courier blocks with a clear message: "working tree is already clean." Conversely, if the agent calls `carson deliver` without `--commit` and the tree is dirty, the Warehouse reports "I'm not clean — there's unpacked material." The Courier blocks: "working tree is dirty — use `carson deliver --commit`."

### Production Standard

A parcel's content is produced against the **production standard** (the registry state). The standard is what the client (registry) requires. Three operations maintain it:

```ruby
warehouse.based_on_latest_standard?( parcel )  # is this workbench current?
warehouse.rebase_on_latest_standard!            # rebase workbench onto latest
warehouse.receive_latest_standard!              # update warehouse's local copy
```

**The standard trio:**
- `based_on_latest_standard?` — **query.** Is this parcel produced against the latest standard? Checked before every delivery.
- `rebase_on_latest_standard!` — **fix for workbenches.** When a workbench falls behind the standard, rebase it. Used when the Courier blocks a delivery for being behind.
- `receive_latest_standard!` — **fix for the Warehouse.** After the Bureau accepts a parcel, the registry has new content. The Warehouse's local copy of the standard (local main) is now stale. This method fast-forwards it without switching branches. Uses a dual-path approach: `merge --ff-only` when main is checked out in the main worktree (the normal production case), fetch refspec when main is not checked out.

**Use case — before shipping:** An agent committed changes on `feature/login` yesterday. Overnight, another PR was merged into main. This morning, the agent runs `carson deliver`. The Courier fetches the latest standard, checks `based_on_latest_standard?` — returns false. The Courier blocks: "branch is behind origin/main." The agent rebases and delivers again.

**Use case — after acceptance:** The Bureau accepts and merges the parcel. The registry now has the new content. The Courier calls `warehouse.receive_latest_standard!` — local main fast-forwards to match the registry. The next workbench prepared from main will automatically be based on the latest standard.

### Workbench

This is settled. The active place where the agent works is a **workbench**, not a shelf.

A shelf is passive storage. A workbench is where the agent edits, builds, tests, and packs a parcel. The parcel is built on the workbench, handed to the Courier, and the workbench is what gets sealed during delivery.

A workbench is also a passive object. It is not an actor. It shows state — path, branch, prunable reason — while the Warehouse owns its lifecycle.

### One Workbench Per Parcel

A workbench is used for one parcel. The agent checks in, works, delivers, then checks out. New work starts on a new workbench from the latest standard.

**Rationale:**
1. **Traceability** — workbench, parcel, branch, and delivery stay aligned.
2. **Isolation** — ownership stays clear; old local state does not leak into new work.
3. **Clean standard** — a new workbench starts from the updated standard instead of inheriting stale local state.

**Use case:** An agent finishes `feature/auth` and the parcel is accepted. Instead of continuing on the same workbench, the agent checks out. For the next job, the agent checks in again and receives a fresh workbench based on the latest standard.

### Workbench Seal

Once a parcel ships and the waybill is filed, the Warehouse seals the workbench. No more packing until the delivery outcome is confirmed. This prevents the agent from modifying a workbench while its parcel is in flight at the registry.

**Lifecycle:**

| Outcome | Seal action | Why |
|---|---|---|
| Delivered | Unseal (workbench is done — housekeep removes it) | Parcel accepted, workbench served its purpose |
| Held / rejected | Unseal (courier brought parcel back) | Agent can fix and re-deliver |
| Filed (checks exhausted) | Stays sealed | Parcel still at the registry — no changes allowed |

**Mechanism:** Seal marker file at `~/.carson/seals/<sha256-of-worktree-path>` containing the PR number and worktree path. Lives outside the worktree so it does not pollute `git status`. `warehouse.pack!` refuses when sealed. `carson audit` (via pre-commit hook) blocks `git commit` on sealed workbenches.

**Crash recovery:** If Carson is killed mid-delivery, the marker survives at `~/.carson/seals/`. The next `carson deliver` or company monitor run finds the marker, reads the PR number, and checks the waybill to determine the current state.

### Enforcement Layers

Carson and Claude Code are two separate enforcement systems with different domains.

| Layer | Domain | Mechanism | What it governs |
|---|---|---|---|
| **Carson** | Git operations | Pre-commit hook → `carson audit`, pre-push hook, delivery guards | Commits, pushes, merges, PR creation, branch operations |
| **Claude Code** | Agent tools | PreToolUse hooks, deny patterns, `settings.json` | File edits (Write, Edit), shell commands (Bash), destructive operations |
| **TAI global hooks** | Cross-project safety | `~/AI/enforce/hooks/pre-commit`, bash-write-guard, main-tree-write-guard | Main branch commits, secret files, main tree writes |

Carson cannot prevent an agent from editing files on a sealed workbench. It can only prevent the agent from committing or delivering those edits. The PreToolUse layer (Claude Code hooks) is the right place for file-level enforcement.

**Implication:** The workbench seal is partial enforcement. Full enforcement requires both layers working together — Carson seals the workbench (blocks commits), and a Claude Code hook blocks file edits on sealed workbenches.

## 8. The Delivery Domain

### The Bureau and Its Registry

The Bureau (GitHub) includes its registry. Bureaucrats at the registry check parcels (CI, review, mergeability). The registry is where accepted parcels live (remote main).

```
  The Bureau (GitHub)
  ┌──────────────────────────────────────────────┐
  │                                              │
  │  Registry                                    │
  │  ┌──────────────────────────────────┐        │
  │  │                                  │        │
  │  │  Bureaucrats check parcels here  │        │
  │  │  ┌──────────┐  ┌─────────────┐   │        │
  │  │  │ CI check │  │ Review check│   │        │
  │  │  └──────────┘  └─────────────┘   │        │
  │  │                                  │        │
  │  │  All accepted parcels live here  │        │
  │  │  This is what production sees    │        │
  │  │  This IS the production standard │        │
  │  └──────────────────────────────────┘        │
  │                                              │
  └──────────────────────────────────────────────┘
```

### Waybill and Delivery

A **Waybill** is the shipping document filed with the Bureau. It has a tracking number, a URL, and the Bureau's findings written onto it. It is a passive data object — it does not fetch, file, or accept anything itself.

A **Delivery** is Carson's internal receipt. It records the parcel's journey and persists itself through the ledger. It is a passive ledger record.

### The Courier — A Robot

The Courier is a robot employee. Assigned to a Warehouse. Delivers parcels to the Bureau. Does one errand, reports back. Waits at the registry while bureaucrats check the parcel.

```
╔═══════════════════════════════════════════════════════════╗
║             Carson::Courier                               ║
║           (the delivery robot)                            ║
║                                                           ║
║  assigned to: a warehouse                                 ║
║  injected:    merge_method, ledger,                       ║
║               MAX_CHECKS_AT_BUREAU = 6,                   ║
║               poll_interval_at_bureau                     ║
║                                                           ║
║  can:                                                     ║
║    deliver( parcel )            — ship parcel to Bureau   ║
║    wait_and_poll_at_bureau      — poll bureaucrats        ║
║    pause_between_polls          — sleep between checks    ║
║    definitively_blocked?        — hard failure?           ║
║                                                           ║
║  design:                                                  ║
║    Waits at the Bureau while bureaucrats check.           ║
║    Polls up to MAX_CHECKS_AT_BUREAU times.                ║
║    Reports definitive answer or "filed" if exhausted.     ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
```

### Situations the Courier Encounters

Every situation is numbered. The number appears as a code comment on the method that handles it.

```
01. Parcel on main           — cannot deliver from the destination
02. Parcel behind standard   — not based on client's latest standard
03. Shipping fails           — warehouse couldn't push to Bureau
04. Waybill filing fails     — Bureau rejected the paperwork
05. Pending at Bureau        — bureaucrats still checking (CI running)
06. Failed at Bureau         — bureaucrats rejected (CI failed)
07. Review officer pending   — review still in progress
08. Review changes requested — officer wants corrections
09. Merge conflict           — parcel conflicts with registry contents
10. Behind standard (post)   — standard changed since shipping
11. Policy block             — Bureau regulation prevents acceptance
12. Draft waybill            — form not finalised
13. Mergeability pending     — Bureau still processing eligibility
14. Acceptance succeeds      — parcel enters registry. Delivered.
15. Acceptance fails         — classify why, report
16. Bureau unreachable       — cannot contact the Bureau
17. Already delivered        — parcel already in registry
18. Waybill closed           — cancelled externally
```

### The Delivery Flow

The Courier ships, files, then waits at the Bureau polling bureaucrats. If checks clear within the poll window, the Courier accepts into the registry and reports. If checks are exhausted, the Courier reports "filed."

```
  Agent                                 Courier                                           Bureau (GitHub)
    │                                      │                                                      │
    │ "deliver this parcel"                │                                                      │
    │─────────────────────────────────────►│                                                      │
    │                                      │                                                      │
    │                                      │ ask Warehouse                                        │
    │                                      │ - floor clean?                                       │
    │                                      │ - compliance ok?                                     │
    │                                      │ - based on latest standard?                          │
    │                                      │                                                      │
    │                                      │ ship                                                 │
    │                                      │─────────────────────────────────────────────────────►│
    │                                      │                                                      │
    │                                      │ file Waybill                                         │
    │                                      │─────────────────────────────────────────────────────►│
    │                                      │                                                      │
    │                                      │ tracking #42                                         │
    │                                      │◄─────────────────────────────────────────────────────│
    │                                      │                                                      │
    │                                      │ poll loop at Bureau                                  │
    │                                      │ - check status                                       │
    │                                      │─────────────────────────────────────────────────────►│
    │                                      │◄─────────────────────────────────────────────────────│
    │                                      │ - pause                                              │
    │                                      │ - repeat up to MAX_CHECKS                            │
    │                                      │                                                      │
    │                                      │ accept into registry (if clear)                      │
    │                                      │─────────────────────────────────────────────────────►│
    │                                      │ merged                                               │
    │                                      │◄─────────────────────────────────────────────────────│
    │                                      │                                                      │
    │ delivered / filed / held             │                                                      │
    │◄─────────────────────────────────────│                                                      │
    │                                      │                                                      │
```

### Delivery Status Flow

```
┌──────────┐
│  Packed  │
└────┬─────┘
     ▼
┌──────────┐
│ Shipped  │
└────┬─────┘
     ▼
┌────────────────┐
│ Filed at Bureau│
└────┬─────┬─────┘
     │     │
     │     └────────────────────►┌──────────┐
     │                           │ Rejected │
     │                           └──────────┘
     │
     ├───────────────────────────►┌──────────┐
     │                            │   Held   │
     │                            └──────────┘
     │
     ▼
┌──────────┐
│ Cleared  │
└────┬─────┘
     ▼
┌────────────────────┐
│ Accepted into the  │
│ Registry           │
└────┬───────────────┘
     │
     ├───────────────────────────►┌──────────────┐
     │                            │ Bounced back │
     │                            └──────────────┘
     │
     ▼
┌────────────────┐
│ Checked out /  │
│ done           │
└────────────────┘
```

### Destination Modes (Future)

Currently Carson operates in **remote-centred** mode: parcels are shipped to the Bureau, checked by bureaucrats, and accepted into the registry (remote main). The local standard is received from the registry after acceptance.

A future **local-centred** mode merges parcels locally — the remote is a synced backup for future settlement, like a client storing parcels in Carson's warehouse for futures trading.

```
Remote-centred (current):
  ship → waybill → registry → acceptance

Local-centred (future):
  merge locally → settle! (push to remote backup for settlement)
```

The Warehouse and Courier must be designed so the destination mode is injectable, not baked in.

## 9. Implementation Surface, Coding Conventions, and Scars

### Current File Layout

The current implementation is still transitional. The final object model is ahead of the file tree.

```
lib/carson.rb                         ← company entry point / reporting surface
lib/carson/cli.rb                    ← command parsing / CLI surface
lib/carson/courier.rb                ← delivery worker
lib/carson/warehouse.rb              ← local repository authority
lib/carson/worktree.rb               ← transition name for the workbench object
lib/carson/branch.rb                 ← branch state under Warehouse ownership
lib/carson/parcel.rb                 ← committed changes
lib/carson/waybill.rb                ← shipping document
lib/carson/delivery.rb               ← tracking record
lib/carson/repository.rb             ← shared repository operations
lib/carson/revision.rb               ← revision state
lib/carson/config.rb                 ← warehouse configuration
lib/carson/ledger.rb                 ← filing cabinet hidden behind Delivery
lib/carson/version.rb                ← version surface
lib/carson/runtime.rb                ← runtime entry point still being dissolved
lib/carson/runtime/                  ← transitional surface still being dissolved
```

### Implementation Status

#### Phase 1 — Foundation (done)

| Class | Lines | Tests | Status |
|---|---|---|---|
| Carson::Parcel | 24 | 7 tests, 8 assertions | Merged |
| Carson::Warehouse | 105 | 22 tests, 33 assertions | Merged |
| Carson::Waybill | 196 | 16 tests, 29 assertions | Merged |
| Carson::Courier | 160 | 3 tests, 8 assertions | Merged |
| Wiring (carson.rb) | +3 | — | Merged |

All 531 tests pass. New classes work alongside existing code.

#### Phase 2 — Make it live (in progress)

1. ~~Rename `includes_latest?` → `based_on_latest_standard?`~~ (done)
2. ~~Add `rebase_on_latest_standard!` (rebase workbench onto latest)~~ (done)
3. ~~Rename `prepare!` → `pack!`~~ (done)
4. ~~Add `warehouse.submit_compliance!` (injected checker, DI)~~ (done)
5. ~~Add `warehouse.clean?` (dirty tree is warehouse knowledge)~~ (done)
6. ~~Add `warehouse.receive_latest_standard!` (update local standard after acceptance)~~ (done)
7. ~~Add `commit_message:` to Courier (pack before ship)~~ (done)
8. ~~Add `Carson.report` (JSON + text rendering, technical language)~~ (done)
9. ~~Wire `deliver!` to delegate to Courier~~ (done — live in production)
10. ~~Courier waits and polls at the Bureau — configurable MAX_CHECKS and interval~~ (done)
11. ~~Inject merge method from config~~ (done)
12. ~~Inject ledger into Courier~~ (done)
13. Add `warehouse.sweep!` (absorb housekeep)
14. Add `settle!` (local-centred backup push)
15. Carson Co. absorbs internal monitor work (Bureau feedback → client notification)
16. ~~Courier: `return` and `salvage` commands~~ (superseded by the `carson checkout` model)
17. ~~Rename commands: govern→monitor, housekeep→sweep, abandon→return, recover→salvage, status→track~~ (superseded by the `carson checkin / deliver / checkout` model)
18. Remove Runtime — absorbed by domain objects

566 tests pass (21 skipped — RuntimeDeliverTest pending OO adaptation).

#### Phase 3 — Workbench seal and delivery progress (done, 4.0.1)

19. ~~Courier waits and polls at the Bureau (`MAX_CHECKS_AT_BUREAU = 6`, configurable interval)~~ (done)
20. ~~Hold reasons renamed: `inspector_*` → `*_at_bureau`~~ (done)
21. ~~Actionable delivery output~~ (done)
22. ~~Delivery progress: Courier reports opening line + per-check status~~ (done)
23. ~~Workbench seal: `seal_shelf!`, `unseal_shelf!`, `sealed?`, `pack!` guard~~ (done)
24. ~~Seal guard in `carson audit` — blocks `git commit` on sealed workbench~~ (done)
25. ~~`deliver.poll_interval_at_bureau` config with env override~~ (done)
26. ~~`error_at_bureau` treated as transient, not definitive~~ (done)

#### Phase 3b — Bureau interaction and output language (done, 4.1.0)

27. ~~Waybill → data object: removed `fetch_ci`, `refresh!`, `accept!`, `file!`, all `gh` calls~~ (done)
28. ~~Warehouse gains bureau interaction: `check_parcel_at_bureau_with`, `file_waybill_for!`, `register_parcel_at_bureau_with!`~~ (done)
29. ~~CI diagnostic captured: `fetch_ci_state_for` preserves first line of stderr~~ (done, #468)
30. ~~`hold_summary` returns client language directly — `translate_hold` removed~~ (done, #458)
31. ~~Consistent naming: Bureau not registry. Hold reasons, constants, config keys renamed~~ (done)
32. ~~Output format `:human` → `:text`. `report_human` → `report_text`~~ (done)
33. ~~Story language purged from all output surfaces~~ (done, #458)

#### Phase 4 — Open items

34. Workbench seal enforcement gap: Carson governs git (pre-commit hook → `carson audit`). It cannot govern file edits — that is Claude Code's domain (PreToolUse hooks). The seal blocks commits but not Write/Edit. See Warehouse Domain § Enforcement Layers.
35. Introduce `carson checkin` as the public agent verb for asking the Warehouse to prepare a fresh workbench.
36. Introduce `carson checkout` as the public agent verb for asking the Warehouse to release a workbench and local custody when safe.
37. Make the Workbench object fully passive and move all lifecycle management into the Warehouse.
38. Move branch, worktree, and stash lifecycle under Warehouse ownership as one coherent repo-local domain.
39. Carson Co. monitor: connect with the Bureau, check filed deliveries, and update parcel delivery states as internal company work.
40. `warehouse.sweep!` (absorb housekeep).
41. `settle!` (local-centred backup push).
42. Remove Runtime — absorbed by Carson Co., Warehouse, Courier, Waybill, and Delivery.

### Coding Conventions

#### No private `attr_reader`

`attr_reader` exists to create a public interface method. For purely internal state, use the instance variable directly. A private `attr_reader` creates a method where direct variable access suffices.

```ruby
# Wrong — attr_reader for internal-only access
class Courier
private
	attr_reader :warehouse

	def check_bureau( waybill )
		warehouse.main_label  # calls private method
	end
end

# Right — direct instance variable for internal state
class Courier
	def initialize( warehouse )
		@warehouse = warehouse
	end

	def check_bureau( waybill )
		@warehouse.main_label  # direct, simple, honest
	end
end
```

#### Numbered situations in code comments

Every situation a class can encounter is numbered in its class documentation. The number appears as a code comment on the method or branch that handles it:

```ruby
# 02. Parcel behind standard — not based on the client's latest standard.
unless @warehouse.based_on_latest_standard?( parcel )
	return blocked( result, "branch is behind ..." )
end
```

This makes the code auditable — you can verify every documented situation has a handler, and every handler references a documented situation.

### Scars

#### Unsync'd local main cascade (2026-03-23)

Not receiving the latest standard (`warehouse.receive_latest_standard!`) after a merge caused a cascade: merge conflicts, extra PRs, lost commits, multiple rebase attempts. The exact situation `based_on_latest_standard?` is designed to prevent.

**Lesson:** Always receive the latest standard immediately after any parcel reaches the registry. This is `warehouse.receive_latest_standard!` — not optional, not deferrable. The cost of skipping it compounds with every subsequent operation. Now automated: the Courier calls it after every acceptance.

#### Sub-agents and OO (2026-03-23)

A sub-agent was dispatched to build `Carson::Warehouse` with explicit instruction to read `CODING/RUBY.md` § Pure OO Design. The sub-agent followed style rules perfectly — tabs, spaces, `it` parameter, story language, hidden git. But it committed primitive obsession: `ship( label )` taking a string where a `Parcel` object belongs.

**Lesson:** Sub-agents read rules but do not internalise them. The enforcement mechanism is code review, not instruction. Every sub-agent's work must be reviewed for OO violations before merge. The rules prevent gross errors; only review catches the subtle ones.

#### "Go" means code (2026-03-22)

The user said "Go!" expecting overnight marathon implementation. The agent invoked the writing-plans skill, wrote a 300-line plan document, asked "Subagent-driven or inline?", and stopped. The user woke up to zero code.

**Lesson:** When the user gives an execution command ("Go!", "Do it", "Marathon"), write code immediately. Never invoke planning skills, never ask execution method, never produce documents about code instead of code. The skill process chain is guidance, not a gate. The user's direct command overrides any skill workflow.

#### Unsealed workbench after delivery (2026-03-23)

Agent modified files on a workbench after `carson deliver` failed ("held"). The workbench had unstaged changes when the next rebase was attempted: "cannot rebase: You have unstaged changes." The agent blamed a Carson bug. It was a system design gap — no mechanical enforcement prevented the agent from working on the workbench while its parcel was in flight.

**Lesson:** Convention is not enforcement. If the system allows the mistake, the system has the defect — not the agent. The workbench seal (`seal_shelf!`, `sealed?`, `pack!` guard, `carson audit` check) was built as a response. But the seal only governs git commits. File-level enforcement requires Claude Code's PreToolUse hooks — a separate enforcement layer Carson does not control. Full enforcement requires both layers.

#### Agent rushes, places code in wrong location (2026-03-23)

Agent put a seal guard (bash code) in `config/hooks/pre-commit` — a hook distribution template, not a Carson feature location. The seal is Carson logic; it belongs in Carson's Ruby code (`carson audit`). The agent skipped planning and jumped to code.

**Lesson:** Plan before code, even for "obvious" fixes. Especially for shared artefacts that affect every governed repo. The question "where does this belong?" is a design question, not an implementation detail.

#### Short timeout, wrong recovery (2026-03-23)

The original Courier had a 30-second polling loop: check Bureau status every 5 seconds, give up if not cleared within the window. Two problems: (a) 30 seconds was too short — CI takes minutes, so the Courier always timed out, and (b) the recovery action was "re-deliver" (`carson deliver` again) instead of checking the existing parcel. The agent was told to ship again when the parcel was already at the Bureau being checked.

**Lesson:** Waiting at the Bureau IS the Courier's job — that's where parcels get checked. The problem was never "polling vs. not polling." It was the short timeout and the wrong recovery action. The Courier now waits at the Bureau with configurable patience (`MAX_CHECKS_AT_BUREAU = 6`, configurable poll interval). If checks are exhausted before bureaucrats finish, the Courier reports "filed" with the tracking number — not "failed." Carson Co. then owns the follow-up monitoring work.
