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
║                    FedEx  →  Carson                              ║
╠══════════════════════════════════════════════════════════════════╣
║                                                                  ║
║  FedEx (the company)       →  Carson (the company, the CLI)      ║
║  Courier (robot employee)  →  Carson::Courier                    ║
║                                                                  ║
║  Warehouse (intelligent)   →  Carson::Warehouse                  ║
║  Shelf                     →  Carson::Shelf                      ║
║  Shelf label               →  Carson::Label                      ║
║  Parcel (package)          →  Carson::Parcel                     ║
║  Waybill (shipping doc)    →  Carson::Waybill                    ║
║  Tracking record           →  Carson::Delivery                   ║
║  Sender / Client           →  The agent (AI or human)            ║
║                                                                  ║
║  Bureau (registry office)  →  GitHub                             ║
║  Bureaucrat (CI)           →  CI system                          ║
║  Bureaucrat (review)       →  Code reviewer                      ║
║  Registry                  →  Remote main branch                 ║
║  Production standard       →  Registry state (what rebase checks)║
║                                                                  ║
║  Ship                      →  git push (hidden inside)           ║
║  File waybill              →  gh pr create (hidden inside)       ║
║  Registry check            →  CI checks + code review            ║
║  Accept into registry      →  gh pr merge (hidden inside)        ║
║  Proof of delivery         →  Merge proof                        ║
║  Pack                      →  git add + git commit               ║
║  Submit compliance         →  Template sync                      ║
║  Sweep                     →  Worktree/branch cleanup            ║
║  Settle                    →  Push to remote backup (local mode) ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## Two Languages

Carson speaks two languages. Mixing them is a defect.

**Story language** is for Carson's internal domain model — source code, class names, method names, architecture docs, code comments. This is how Carson's developers and maintainers think about the system. Warehouse, Parcel, Courier, Bureau, Shelf, Label.

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

## Architecture — Three Roles

The previous design had four roles (Courier, Cleaner, Dispatcher). Refined to three:

1. **Carson Co.** — the company itself handles dispatch, monitoring, and client notification. No separate Dispatcher. In an AI-run company, the company IS the dispatcher.
2. **Courier** — a robot that delivers parcels. Does one errand at a time, reports back.
3. **Warehouse** — intelligent and autonomous. Packs parcels, checks compliance, sweeps itself, knows its own cleanliness.

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
║  THE COMPANY (Carson module — CLI + dispatch + notification)     ║
║  ┌─────────────────────────────────────────────┐                 ║
║  │  Routes commands to employees               │                 ║
║  │  Receives bureau feedback                   │                 ║
║  │  Notifies clients IMMEDIATELY               │                 ║
║  │  Dispatches courier when work is needed      │                ║
║  │  Manages warehouse portfolio                │                 ║
║  └─────────────────────────────────────────────┘                 ║
║                                                                  ║
║  ROBOT EMPLOYEES                                                 ║
║  ┌────────────┐                                                  ║
║  │  Courier   │  ← delivers parcels to the bureau                ║
║  │  (robot)   │  ← does one errand, reports back                 ║
║  └────────────┘                                                  ║
║                                                                  ║
║  INTELLIGENT WAREHOUSES (self-managing)                          ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            ║
║  │  ~/AI        │  │  ~/Dev/      │  │  ~/Dev/      │  ···       ║
║  │              │  │   nexus      │  │   carson     │            ║
║  │  Packs       │  │              │  │              │            ║
║  │  Sweeps      │  │  Packs       │  │  Packs       │            ║
║  │  Complies    │  │  Sweeps      │  │  Sweeps      │            ║
║  │  Cleans      │  │  Complies    │  │  Complies    │            ║
║  └──────────────┘  └──────────────┘  └──────────────┘            ║
║                                                                  ║
║  The more clients, the better. Good business.                    ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## The Warehouse — Intelligent and Autonomous

The warehouse manages itself. It packs parcels, checks its own compliance, knows its own cleanliness, and sweeps up. No separate Cleaner employee needed.

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
║    clean?                      — floor clean?     ║
║    pack!( message: )           — prepare a parcel ║
║    submit_compliance!          — templates ok?    ║
║    sweep!                      — clean shelves    ║
║    ship( parcel )              — send to bureau   ║
║    fetch_latest                — get registry     ║
║    based_on_latest_standard?   — production check ║
║    rebase_on_latest_standard!  — rebase shelf     ║
║    receive_latest_standard!    — update local std ║
║    settle!                     — push to backup   ║
║    label_absorbed?( name )     — merged into main?║
║                                                   ║
╚═══════════════════════════════════════════════════╝
```

### Warehouse Cleanliness

The warehouse knows whether its floor is clean — whether there are uncommitted changes on the current shelf. This is warehouse knowledge, not the courier's concern.

```ruby
warehouse.clean?  # no uncommitted changes?
```

**Rationale:** In FedEx, the courier doesn't inspect the warehouse floor before picking up a parcel. The warehouse manages itself — it knows if the floor is clean or if there's unpacked material lying around. In Carson, "dirty working tree" is a warehouse state, not a delivery concern. The courier asks the warehouse; it doesn't run `git status` itself.

**Use case:** An agent calls `carson deliver --commit "add login feature"` but the working tree is already clean (nothing to commit). The warehouse reports "I'm clean — there's nothing to pack." The courier blocks with a clear message: "working tree is already clean." Conversely, if the agent calls `carson deliver` without `--commit` and the tree is dirty, the warehouse reports "I'm not clean — there's unpacked material." The courier blocks: "working tree is dirty — use `carson deliver --commit`."

### Production Standard

A parcel's content is produced based on the **production standard** (the registry state). The standard is what the client (registry) requires. Three operations maintain it:

```ruby
warehouse.based_on_latest_standard?( parcel )  # is this shelf current?
warehouse.rebase_on_latest_standard!            # rebase shelf onto latest
warehouse.receive_latest_standard!              # update warehouse's local copy
```

**The standard pair:**
- `based_on_latest_standard?` — **query.** Is this parcel produced against the latest standard? Checked before every delivery.
- `rebase_on_latest_standard!` — **fix for shelves.** When a shelf (feature branch) falls behind the standard, rebase it. Used when the courier blocks a delivery for being behind.
- `receive_latest_standard!` — **fix for the warehouse.** After the bureau accepts a parcel, the registry has new content. The warehouse's local copy of the standard (local main) is now stale. This method fast-forwards it without switching branches.

**Use case — before shipping:** An agent committed changes on `feature/login` yesterday. Overnight, another PR was merged into main. This morning, the agent runs `carson deliver`. The courier fetches the latest standard, checks `based_on_latest_standard?` — returns false. The courier blocks: "branch is behind origin/main." The agent rebases and delivers again.

**Use case — after acceptance:** The bureau accepts and merges the parcel. The registry now has the new content. The courier calls `warehouse.receive_latest_standard!` — local main fast-forwards to match the registry. The next shelf created from main will automatically be based on the latest standard.

### One Shelf Per Parcel

A shelf (worktree/branch) is used for one parcel (feature). After the parcel is delivered and accepted, the shelf is swept. To start new work, create a new shelf.

```
Shelf: oo/phase2         (parcel delivered, accepted)
  → warehouse sweeps shelf
  → new shelf: oo/phase3  (fresh, based on latest standard)
     → new parcel, new delivery
```

**Rationale:**
1. **Traceability** — branch name = scope = PR = delivery. Reusing a shelf muddies the history.
2. **Isolation** — concurrency rules depend on scope ownership per shelf. Reusing blurs ownership.
3. **Clean standard** — a new shelf starts from the updated standard. An old shelf starts stale and needs rebasing — extra work for no benefit.

**Use case:** An agent finishes `feature/auth` and it's merged. Instead of continuing work on `feature/auth`, the agent runs `carson worktree create feature/dashboard`. The new shelf is based on the latest standard (which includes the auth work). No rebase needed. Clean scope. Clean PR.

## The Bureau and Its Registry

The bureau (GitHub) is a registry where bureaucrats work. Bureaucrats at the registry check parcels (CI, review, mergeability). The registry is where accepted parcels live (remote main).

```
  The Bureau (GitHub)
  ┌──────────────────────────────────────────────┐
  │                                              │
  │  Registry                                    │
  │  ┌──────────────────────────────────┐         │
  │  │                                  │         │
  │  │  Bureaucrats check parcels here  │         │
  │  │  ┌──────────┐  ┌─────────────┐  │         │
  │  │  │ CI check │  │ Review check│  │         │
  │  │  └──────────┘  └─────────────┘  │         │
  │  │                                  │         │
  │  │  All accepted parcels live here  │         │
  │  │  This is what production sees    │         │
  │  │  This IS the production standard │         │
  │  └──────────────────────────────────┘         │
  │                                              │
  └──────────────────────────────────────────────┘
```

### Bureau Feedback Model

The bureau processes asynchronously — CI runs take minutes, reviews take hours. The courier waits at the registry while bureaucrats check the parcel, polling periodically (up to MAX_CHECKS_AT_REGISTRY=6 times, with configurable poll interval). If the checks clear, the courier reports the definitive answer. If checks are exhausted, the courier reports "filed" — the parcel is at the registry, bureaucrats are still checking. Carson Co. is responsible for follow-up notification when the bureau's state changes.

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

**Use case:** An agent runs `carson deliver` at 2pm. CI takes 3 minutes. The courier files the waybill, waits at the registry while bureaucrats check (polling periodically). CI passes within the poll window. The courier merges and reports: "Merged. Local main synced." If CI takes longer than the poll window, the courier reports "filed — waiting for CI checks" and the agent continues other work. When CI passes, Carson Co. (via `monitor`) detects the change, informs the agent: "PR #437 — CI passed, merging."

**Anti-pattern (old design):** The old design had two problems: (a) a 30-second timeout was too short — CI takes minutes, so the courier always timed out, and (b) the recovery action was "re-deliver" (run `carson deliver` again) instead of "check status." The agent had to manually re-run `carson deliver`, which created a new PR attempt instead of checking the existing one. This is like FedEx losing your tracking number and asking you to ship again. The fix: the courier waits at the registry with enough patience (configurable polls), and if checks are exhausted, reports the parcel as "filed" with the tracking number — not "failed."

## Output Rendering

Output is for agents by default. Human is the second class.

JSON is the primary output format — agents consume it. Human-readable is secondary. The output concern does not belong on the Courier or any domain object. It belongs at the company level — Carson formats the result for whoever is listening.

```ruby
result = courier.deliver( parcel )
Carson.report( result, format: :json )  # default — agents
Carson.report( result, format: :human ) # secondary — humans
```

The Courier returns a result hash. Carson decides how to render it. Domain objects never know or care about output format.

Output uses **technical language** — the client's language. `Carson.translate_hold` maps internal hold reasons to technical terms:

| Internal reason | Client sees | Recovery |
|---|---|---|
| `pending_at_registry` | "Waiting for CI checks." | "Run `carson track` to check status." |
| `failed_at_registry` | "CI checks failed." | "Fix failures, push, and run `carson deliver`." |
| `error_at_registry` | "CI check error — inconclusive." | "Re-run CI or run `carson deliver`." |
| `merge_conflict` | "Merge conflict with main." | "Rebase on main, resolve conflicts, and re-deliver." |
| `behind_registry` | "Branch is behind main." | "Run `git rebase origin/main` and re-deliver." |
| `policy_block` | "Blocked by branch protection rules." | "Check branch protection settings." |
| `draft` | "PR is still a draft." | "Mark PR as ready for review." |

## The Courier — A Robot

The courier is a robot employee. Assigned to a warehouse. Delivers parcels to the bureau. Does one errand, reports back. Waits at the registry while bureaucrats check the parcel.

```
╔═══════════════════════════════════════════════════════════╗
║             Carson::Courier                               ║
║           (the delivery robot)                            ║
║                                                           ║
║  assigned to: a warehouse                                 ║
║  injected:    merge_method, ledger,                       ║
║               MAX_CHECKS_AT_REGISTRY = 6,                 ║
║               poll_interval_at_registry                   ║
║                                                           ║
║  can:                                                     ║
║    deliver( parcel )            — ship parcel to registry  ║
║    return( parcel )             — return to sender          ║
║    salvage( parcel )            — rescue stuck parcel       ║
║    wait_and_poll_at_registry    — poll bureaucrats          ║
║    pause_between_polls          — sleep between checks     ║
║    definitively_blocked?        — hard failure?             ║
║                                                           ║
║  design:                                                  ║
║    Waits at registry while bureaucrats check.             ║
║    Polls up to MAX_CHECKS_AT_REGISTRY times.             ║
║    Reports definitive answer or "filed" if exhausted.    ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
```

### Situations the Courier Encounters

Every situation is numbered. The number appears as a code comment on the method that handles it.

```
01. Parcel on main          — cannot deliver from the destination
02. Parcel behind standard  — not based on client's latest standard
03. Shipping fails          — warehouse couldn't push to bureau
04. Waybill filing fails    — bureau rejected the paperwork
05. Pending at registry     — bureaucrats still checking (CI running)
06. Failed at registry      — bureaucrats rejected (CI failed)
07. Review officer pending  — review still in progress
08. Review changes requested — officer wants corrections
09. Merge conflict          — parcel conflicts with registry contents
10. Behind standard (post)  — standard changed since shipping
11. Policy block            — bureau regulation prevents acceptance
12. Draft waybill           — form not finalised
13. Mergeability pending    — bureau still processing eligibility
14. Acceptance succeeds     — parcel enters registry. Delivered.
15. Acceptance fails        — classify why, report
16. Bureau unreachable      — cannot contact the bureau
17. Already delivered       — parcel already in registry
18. Waybill closed          — cancelled externally
```

## The Delivery Flow

The courier ships, files, then waits at the registry polling bureaucrats. If checks clear within the poll window, the courier accepts into the registry and reports. If checks are exhausted, the courier reports "filed."

```
  Agent                    Courier                  Bureau (GitHub)
    │                        │                        │
    │  "deliver this parcel" │                        │
    ├───────────────────────►│                        │
    │                        │                        │
    │                        │── ask warehouse:       │
    │                        │   floor clean?         │
    │                        │   compliance ok?       │
    │                        │   based on latest?     │
    │                        │                        │
    │                        │── ship ───────────────►│
    │                        │                        │
    │                        │── file Waybill ───────►│
    │                        │         ┌──────────────┤
    │                        │         │ tracking #42 │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── wait at registry ──  │
    │                        │   ┌────────────────┐   │
    │                        │   │ poll loop:     │   │
    │                        │   │  check status ►├──►│
    │                        │   │  ◄─── status ──┤◄──┤
    │                        │   │  pause         │   │
    │                        │   │  (repeat up to │   │
    │                        │   │   MAX_CHECKS)  │   │
    │                        │   └────────────────┘   │
    │                        │                        │
    │                        │── accept (if clear) ──►│
    │                        │         ┌──────────────┤
    │                        │         │ merged       │
    │                        │◄────────┘              │
    │                        │                        │
    │  result: delivered/    │                        │
    │  filed/held            │                        │
    │◄───────────────────────┤                        │
    │                        │                        │
```

## Commands — All Story Language

| Command | Who handles | Meaning |
|---|---|---|
| `carson deliver` | Courier | Ship parcel to the registry |
| `carson return` | Courier | Return parcel to sender |
| `carson salvage` | Courier | Rescue a stuck parcel |
| `carson monitor` | Carson Co. | Watch bureau feedback, notify clients, dispatch couriers |
| `carson track` | Carson Co. | Where is everything right now? |
| `carson sweep` | Warehouse | Clean shelves and stale labels |

## Every Concept Is an Object

| Object | What it IS | What it knows | What it does |
|---|---|---|---|
| **Carson** | The company | Portfolio of warehouses | Routes commands, notifies clients, dispatches couriers |
| **Courier** | Delivery robot | Its warehouse, merge method | Delivers, returns, salvages parcels |
| **Warehouse** | Intelligent repo | Path, config, shelves, labels, cleanliness | Packs, ships, sweeps, checks compliance, manages standard |
| **Parcel** | Committed changes | Label, head, shelf | The thing being delivered |
| **Waybill** | Shipping document | Tracking number, bureau response | Filed with bureau, tracks approval |
| **Delivery** | Tracking record | Status, cause, proof | Records the parcel's journey |
| **Shelf** | A worktree | Path, label, occupant | Holds parcels, can be removed |
| **Label** | A branch name | Name, absorbed status | Identifies a shelf |
| **Bureau** | GitHub | Bureaucrats, registry | Checks parcels, accepts/rejects into registry |
| **Registry** | Remote main | All accepted parcels | The production standard |

## Destination Modes (Future)

Currently Carson operates in **remote-centred** mode: parcels are shipped to the bureau, checked by bureaucrats, and accepted into the registry (remote main). The local standard is received from the registry after acceptance.

A future **local-centred** mode merges parcels locally — the remote is a synced backup for future settlement, like a client storing parcels in Carson's warehouse for futures trading.

```
Remote-centred (current):
  ship → waybill → registry → acceptance

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
| Dirty tree check | Warehouse (`clean?`) |

## File Layout

```
lib/carson/
  carson.rb              ← the company (entry point, routing, dispatch, rendering)
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

### Phase 2 — Make it live (in progress)

1. ~~Rename `includes_latest?` → `based_on_latest_standard?`~~ (done)
2. ~~Add `rebase_on_latest_standard!` (rebase shelf onto latest)~~ (done)
3. ~~Rename `prepare!` → `pack!`~~ (done)
4. ~~Add `warehouse.submit_compliance!` (injected checker, DI)~~ (done)
5. ~~Add `warehouse.clean?` (dirty tree is warehouse knowledge)~~ (done)
6. ~~Add `warehouse.receive_latest_standard!` (update local standard after acceptance)~~ (done)
7. ~~Add `commit_message:` to Courier (pack before ship)~~ (done)
8. ~~Add `Carson.report` (JSON + human rendering, technical language)~~ (done)
9. ~~Wire `deliver!` to delegate to Courier~~ (done — live in production)
10. ~~Courier waits and polls at registry — configurable MAX_CHECKS and interval~~ (done)
11. ~~Inject merge method from config~~ (done)
12. ~~Inject ledger into Courier~~ (done)
13. Add `warehouse.sweep!` (absorb housekeep)
14. Add `settle!` (local-centred backup push)
15. Carson Co. absorbs `monitor` and `track` (bureau feedback → client notification)
16. Courier: `return` and `salvage` commands
17. Rename commands: govern→monitor, housekeep→sweep, abandon→return, recover→salvage, status→track
18. Remove Runtime — absorbed by domain objects

552 tests pass (21 skipped — RuntimeDeliverTest pending OO adaptation).

## Coding Conventions

### No private `attr_reader`

`attr_reader` exists to create a public interface method. For purely internal state, use the instance variable directly. A private `attr_reader` creates a method where a direct variable access suffices.

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

### Numbered situations in code comments

Every situation a class can encounter is numbered in its class documentation. The number appears as a code comment on the method or branch that handles it:

```ruby
# 02. Parcel behind standard — not based on client's latest standard.
unless @warehouse.based_on_latest_standard?( parcel )
	return blocked( result, "branch is behind ..." )
end
```

This makes the code auditable — you can verify every documented situation has a handler, and every handler references a documented situation.

## Scars

### Unsync'd local main cascade (2026-03-23)

Not receiving the latest standard (`warehouse.receive_latest_standard!`) after a merge caused a cascade: merge conflicts, extra PRs, lost commits, multiple rebase attempts. The exact situation `based_on_latest_standard?` is designed to prevent.

**Lesson:** Always receive the latest standard immediately after any parcel reaches the registry. This is `warehouse.receive_latest_standard!` — not optional, not deferrable. The cost of skipping it compounds with every subsequent operation. Now automated: the Courier calls it after every acceptance.

### Sub-agents and OO (2026-03-23)

A sub-agent was dispatched to build `Carson::Warehouse` with explicit instruction to read `CODING/RUBY.md` § Pure OO Design. The sub-agent followed style rules perfectly — tabs, spaces, `it` parameter, story language, hidden git. But it committed primitive obsession: `ship( label )` taking a string where a `Parcel` object belongs.

**Lesson:** Sub-agents read rules but do not internalise them. The enforcement mechanism is code review, not instruction. Every sub-agent's work must be reviewed for OO violations before merge. The rules prevent gross errors; only review catches the subtle ones.

### "Go" means code (2026-03-22)

The user said "Go!" expecting overnight marathon implementation. The agent invoked the writing-plans skill, wrote a 300-line plan document, asked "Subagent-driven or inline?", and stopped. The user woke up to zero code.

**Lesson:** When the user gives an execution command ("Go!", "Do it", "Marathon"), write code immediately. Never invoke planning skills, never ask execution method, never produce documents about code instead of code. The skill process chain is guidance, not a gate. The user's direct command overrides any skill workflow.

### Short timeout, wrong recovery (2026-03-23)

The original Courier had a 30-second polling loop: check bureau status every 5 seconds, give up if not cleared within the window. Two problems: (a) 30 seconds was too short — CI takes minutes, so the courier always timed out, and (b) the recovery action was "re-deliver" (run `carson deliver` again) instead of "check status." Re-delivering created a new attempt instead of checking the existing parcel. The agent was told to ship again when the parcel was already at the registry being checked.

**Lesson:** Waiting at the registry IS the courier's job — that's where parcels get checked. The problem was never "polling vs. not polling." It was the short timeout and the wrong recovery action. The courier now waits at the registry with configurable patience (MAX_CHECKS_AT_REGISTRY=6, configurable poll interval). If checks are exhausted before bureaucrats finish, the courier reports "filed" with the tracking number — not "failed." The recovery action is "check status" (`carson track`), not "re-deliver."

## Design Principles

1. **Everything is an object.** Warehouses, shelves, labels, waybills, the bureau, bureaucrats — all objects with identity, state, and behaviour.
2. **Two languages, never mixed.** Story language in source code. Technical language in output. The metaphor serves the developer; the output serves the agent.
3. **The warehouse manages itself.** Packs, sweeps, checks compliance, knows its own cleanliness. No separate Cleaner.
4. **Carson Co. notifies first, dispatches second.** When the bureau sends feedback, the client is informed immediately. The courier is dispatched only if there's an errand to run.
5. **The courier is a robot.** Does one errand, reports back. Waits and polls at the registry while bureaucrats check the parcel. Re-dispatch (after poll exhaustion) is the company's job.
6. **Objects hold their own state.** No data extraction between objects.
7. **Production standard.** Parcels must be based on the client's latest standard before shipping. Three operations: query (`based_on_latest_standard?`), fix shelf (`rebase_on_latest_standard!`), update warehouse (`receive_latest_standard!`).
8. **One shelf per parcel.** Shelves are disposable; the registry is permanent. New work starts on a new shelf from the updated standard.
9. **Destination mode is injectable.** Remote-centred now, local-centred later.
10. **Runtime dissolves.** Its responsibilities are absorbed by the objects they belong to.
11. **Numbered situations.** Every courier situation has a code number in the comments.

## References

- 99 Bottles of OOP (Sandi Metz, Katrina Owen, TJ Stankus)
- Rails source patterns (github.com/rails/rails)
- ~/AI/core/CODING/RUBY.md § Pure OO Design
- ~/AI/docs/study/ruby-pure-oo.md
