# Carson OO Domain Model — The FedEx Metaphor

Spec date: 2026-03-22

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
║  Courier (employee)        →  Carson::Courier                    ║
║  Cleaner (employee)        →  Carson::Cleaner                    ║
║  Dispatcher (employee)     →  Carson::Dispatcher                 ║
║                                                                  ║
║  Warehouse                 →  Carson::Warehouse                  ║
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
║                                                                  ║
║  Ship                      →  git push (hidden inside)           ║
║  File waybill              →  gh pr create (hidden inside)       ║
║  Customs inspection        →  CI checks + code review            ║
║  Accept into registry      →  gh pr merge (hidden inside)        ║
║  Proof of delivery         →  Merge proof                        ║
║                                                                  ║
╚══════════════════════════════════════════════════════════════════╝
```

## Carson — The Company

Carson IS the CLI. When the agent calls `carson deliver`, they're talking to Carson directly. Carson is both the company and the entry point.

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
║  EMPLOYEES (each a role, each a class)                           ║
║  ┌────────────┐  ┌────────────┐  ┌────────────┐                 ║
║  │  Courier   │  │  Cleaner   │  │ Dispatcher  │                ║
║  │  delivers  │  │  sweeps    │  │  monitors   │                ║
║  │  parcels   │  │  warehouse │  │  deliveries │                ║
║  └────────────┘  └────────────┘  └────────────┘                 ║
║                                                                  ║
║  Clients (governed warehouses):                                  ║
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

```ruby
# exe/carson — this IS Carson
Carson.run( ARGV )

# Inside Carson
module Carson
	def self.run( arguments )
		command, options = parse( arguments )
		warehouse = Warehouse.new( path: Dir.pwd )

		case command
		when "deliver"
			parcel = Parcel.new(
				label: warehouse.current_label,
				head: warehouse.current_head,
				shelf: Dir.pwd
			)
			Courier.new( warehouse ).deliver( parcel, **options )
		when "return"
			parcel = Parcel.new( label: warehouse.current_label, head: warehouse.current_head )
			Courier.new( warehouse ).return_to_sender( parcel )
		when "salvage"
			parcel = Parcel.new( label: warehouse.current_label, head: warehouse.current_head )
			Courier.new( warehouse ).salvage( parcel )
		when "monitor"
			Dispatcher.new( warehouse ).monitor!( **options )
		when "track"
			Dispatcher.new( warehouse ).track
		when "sweep"
			Cleaner.new( warehouse ).sweep!( **options )
		end
	end
end
```

## Commands — All Story Language

| Command | Employee | Meaning |
|---|---|---|
| `carson deliver` | Courier | Ship parcel to the registry |
| `carson return` | Courier | Return parcel to sender |
| `carson salvage` | Courier | Rescue a stuck parcel |
| `carson monitor` | Dispatcher | Watch over all parcels continuously |
| `carson track` | Dispatcher | Where is everything right now? |
| `carson sweep` | Cleaner | Clean the warehouse |

## The Warehouse

A warehouse is a governed repository. It has shelves (worktrees) with labels (branches), parcels on shelves (committed changes), and a filing cabinet (ledger).

```
  Warehouse: ~/Dev/nexus
  ═══════════════════════════════════════════════════

  Shelves, each with a label:

  ┌─────────────────────────────────┐
  │  main                           │  ← local reference
  └─────────────────────────────────┘

  ┌─────────────────────────────────┐
  │  feature/login                  │  ← label
  │                                 │
  │    Parcel                       │  ← committed changes
  │    (3 commits, ready to ship)   │
  │                                 │
  │    Courier A is here            │
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

```ruby
class Carson::Warehouse
	def initialize( path: )

	# What the warehouse knows
	def current_label             # which label is active on the current shelf
	def current_head              # tip of the parcel on current shelf
	def main_label                # the destination label (from config)
	def bureau_address            # the bureau's address (from config)

	# Warehouse operations
	def ship( parcel )            # send parcel to the bureau
	def fetch_latest              # get latest registry state from bureau
	def includes_latest?( parcel ) # is parcel up to date with registry?
	def prepare!( message: )      # stage and commit (prepare a parcel)

	# Inventory
	def shelves                   # all shelves
	def labels                    # all labels
	def label_absorbed?( name )   # has this label been merged into main?

	# Config and filing cabinet
	def config
	def ledger                    # hidden — Delivery accesses it
end
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
  │  └──────────────────────────────────┘         │
  │                                              │
  └──────────────────────────────────────────────┘
```

## Employees

Each Carson command has a dedicated employee. The current `Runtime` was every employee rolled into one god object. Each role is now its own class.

### Courier — delivers parcels

```ruby
class Carson::Courier
	def initialize( warehouse, output: $stdout, verbose: false )

	# Services
	def deliver( parcel, title: nil, body_file: nil, commit_message: nil )
	def return_to_sender( parcel )
	def salvage( parcel )

	private

	# The courier waits at the customs window
	def settle( waybill, delivery )
	# The courier updates the tracking record
	def update_tracking( delivery, waybill )
end
```

### Cleaner — sweeps the warehouse

```ruby
class Carson::Cleaner
	def initialize( warehouse, output: $stdout )

	def sweep!              # full warehouse cleanup
	def reap( shelf )       # remove one empty shelf
	def prune( label )      # remove one stale label
end
```

### Dispatcher — monitors all parcels

The dispatcher is permanently assigned to a warehouse. They monitor all in-transit parcels, take action when customs clears, and report the state of the warehouse when asked.

```ruby
class Carson::Dispatcher
	def initialize( warehouse, output: $stdout )

	def monitor!( loop_seconds: nil )   # continuous monitoring
	def track                           # point-in-time report
	def reconcile( delivery )           # update one tracking record
end
```

## Domain Objects

### Parcel — the committed changes

The protagonist. The thing being delivered. Created by agents who commit changes onto a shelf.

```ruby
class Carson::Parcel
	attr_reader :label, :head, :shelf

	def initialize( label:, head:, shelf: nil )

	def on_main?( main_label )
end
```

### Waybill — the shipping document

Filed with the bureau. Has a tracking number. Knows what the bureaucrats say. Can ask the bureau to accept the parcel.

```ruby
class Carson::Waybill
	attr_reader :tracking_number, :url, :label

	def initialize( label:, warehouse: )

	# Filing
	def filed?
	def file!( title:, body_file: nil )

	# Bureau's response (call refresh! first)
	def refresh!              # check with the bureau
	def cleared?              # all bureaucrats approve
	def held?                 # something is blocking
	def hold_reason           # "inspector_pending", "review_changes", etc.
	def hold_summary          # human-readable explanation
	def accepted?             # parcel entered the registry
	def rejected?             # waybill closed without acceptance
	def draft?

	# Request acceptance
	def accept!( method: )    # ask bureau to accept the parcel into registry
end
```

### Delivery — the tracking record

Carson's internal receipt. Records the parcel's journey. Persists itself (hides the ledger).

```ruby
class Carson::Delivery
	attr_reader :status, :tracking_number, :cause, :summary, :proof

	def self.create( warehouse:, parcel:, tracking_number:, tracking_url: )
	def self.active_for( warehouse: )

	def update( status:, cause: nil, summary: nil )
	def mark_delivered( proof: )

	def delivered?
	def held?
	def cleared?
	def failed?
end
```

### Shelf — a worktree

A shelf in the warehouse. Has a label. Can be occupied or empty. The cleaner removes empty ones.

```ruby
class Carson::Shelf
	attr_reader :path, :label

	def occupied?           # is someone working here?
	def removable?          # not occupied, not current directory
	def remove!
end
```

### Label — a branch name

A label on a shelf. Can be pruned when the shelf is gone and the parcel has been delivered.

```ruby
class Carson::Label
	attr_reader :name

	def absorbed?           # has this label been merged into the registry?
	def prune!
end
```

## Every Concept Is an Object

| Object | What it IS | What it knows | What it does |
|---|---|---|---|
| **Carson** | The company | Portfolio of warehouses | Routes commands to employees |
| **Courier** | Delivery person | Their warehouse, their shelf | Delivers, returns, salvages parcels |
| **Cleaner** | Warehouse cleaner | The warehouse state | Sweeps shelves, prunes labels |
| **Dispatcher** | Delivery monitor | All tracking records | Monitors, tracks, reconciles |
| **Warehouse** | The repository | Path, config, shelves, labels | Ships parcels, checks inventory |
| **Shelf** | A worktree | Path, label, occupant | Holds parcels, can be removed |
| **Label** | A branch name | Name, absorbed status | Identifies a shelf |
| **Parcel** | Committed changes | Label, head, shelf | The thing being delivered |
| **Waybill** | Shipping document | Tracking number, bureau's response | Filed with bureau, tracks approval |
| **Delivery** | Tracking record | Status, cause, proof | Records the parcel's journey |
| **Bureau** | GitHub | Bureaucrats, registry | Inspects, accepts/rejects parcels |
| **Inspector** | CI system | Test results | Inspects parcel quality |
| **Review Officer** | Code reviewer | Review decision | Reviews parcel contents |
| **Registry** | Remote main | All accepted parcels | The official record |

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
    │                        │── check: parcel        │
    │                        │   up to date with      │
    │                        │   registry?            │
    │                        │                        │
    │                        │── ship ───────────────►│
    │                        │                        │
    │                        │── file Waybill ───────►│
    │                        │         ┌──────────────┤
    │                        │         │ tracking #42 │
    │                        │◄────────┘              │
    │                        │                        │
    │                        │── check customs ──────►│
    │                        │                  ┌─────┤
    │                        │          Inspector     │
    │                        │          checks...     │
    │                        │          Review Officer │
    │                        │          reviews...    │
    │                        │                  │     │
    │                        │         ┌────────┘     │
    │                        │         │ held / clear │
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
    │                        │                        │
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
    │                        │   (tracking record)    │
    │                        │                        │
    │  "delivered, receipt:" │                        │
    │◄───────────────────────┤                        │
    │                        │                        │
```

## Delivery Status Flow

```
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ Picked   │────►│ Shipped  │────►│  In      │
  │ up       │     │          │     │ Customs  │
  └──────────┘     └──────────┘     │(waybill  │
                                     │ filed)   │
                                     └────┬─────┘
                                          │
                              ┌───────────┼───────────┐
                              ▼           ▼           ▼
                        ┌──────────┐ ┌──────────┐ ┌──────────┐
                        │ Held     │ │ Cleared  │ │ Rejected │
                        │(inspector│ │ (ready)  │ │ (closed) │
                        │ or review│ └────┬─────┘ └──────────┘
                        │ pending) │      │
                        └────┬─────┘      ▼
                             │      ┌──────────┐
                             │      │Delivering│
                             │      │(accepting│
                             │      │ into     │
                             │      │ registry)│
                             │      └────┬─────┘
                             │           │
                             │      ┌────┴─────┐
                             │      ▼          ▼
                             │ ┌──────────┐ ┌──────────┐
                             └►│Delivered │ │ Bounced  │
                               │(entered  │ │(accept   │
                               │ registry)│ │ failed)  │
                               └──────────┘ └──────────┘
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
    │── remove shelf ─────────►│
    │── remove shelf ─────────►│
    │── remove shelf ─────────►│
    │                          │
    │── scan for stale ───────►│
    │   labels                 │
    │         ┌────────────────┤
    │         │ 5 stale labels │
    │◄────────┘                │
    │                          │
    │── prune label ──────────►│
    │── prune label ──────────►│
    │   ···                    │
    │                          │
```

## The Dispatcher's Work

```
  Dispatcher              Tracking Records        Bureau
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
    │── request acceptance ─────────────────────────►│
    │   for #42                │                     │
    │                          │         ┌───────────┤
    │                          │         │ accepted  │
    │◄───────────────────────────────────┘           │
    │                          │                     │
    │── update record ────────►│  (#42 → delivered)  │
    │                          │                     │
```

## File Layout — All Story Names

```
lib/carson/
  carson.rb              ← the company (entry point, argument parsing)
  courier.rb             ← the delivery person
  cleaner.rb             ← the warehouse cleaner
  dispatcher.rb          ← the delivery monitor
  warehouse.rb           ← the repository
  shelf.rb               ← the worktree
  label.rb               ← the branch
  parcel.rb              ← the committed changes
  waybill.rb             ← the shipping document (PR)
  delivery.rb            ← the tracking record
  config.rb              ← warehouse configuration
  ledger.rb              ← filing cabinet (hidden behind Delivery)
```

## Naming Rule

All class names, method names, and command names use story language. Git and GitHub terms are hidden inside method bodies and private variables.

| Story name (public) | Git/GitHub term (hidden inside) |
|---|---|
| `Warehouse` | repository, git repo |
| `Shelf` | worktree |
| `Label` | branch |
| `Parcel` | committed changes |
| `Waybill` | pull request |
| `Delivery` | delivery record (same) |
| `warehouse.ship( parcel )` | `git push` |
| `warehouse.fetch_latest` | `git fetch` |
| `warehouse.current_label` | `git rev-parse --abbrev-ref HEAD` |
| `warehouse.includes_latest?( parcel )` | `git merge-base --is-ancestor` |
| `waybill.file!` | `gh pr create` |
| `waybill.cleared?` | CI pass + review approved + mergeable |
| `waybill.accept!` | `gh pr merge` |
| `shelf.remove!` | `git worktree remove` |
| `label.prune!` | `git branch -d` |

## Why Runtime Was Wrong

Runtime was every employee rolled into one person doing every job. That's not a person — it's a department pretending to be one employee. In OO, each role is its own object with its own identity, state, and responsibilities.

| What Runtime did | Who should do it |
|---|---|
| `deliver!` | **Courier** — delivers parcels |
| `govern!` | **Dispatcher** — monitors deliveries |
| `housekeep!` | **Cleaner** — sweeps the warehouse |
| `abandon!` | **Courier** — returns parcel to sender |
| `recover!` | **Courier** — salvages stuck parcels |
| `status` | **Dispatcher** — reads the dispatch board |
| held git_run, gh_run | Tools — each employee and the warehouse use them |
| held config, ledger | Company resources — warehouse provides them |

## Design Principles Applied

1. **Everything is an object.** Warehouses, shelves, labels, waybills, the bureau, inspectors, review officers — all objects with identity, state, and behaviour.

2. **One set of concepts.** Story language everywhere in public interfaces. Git and GitHub terms hidden inside. A developer reads the code and sees a delivery service, not a git wrapper.

3. **Each role is its own class.** Courier, Cleaner, Dispatcher — not one god-class doing everything. Each has a clear identity and clear responsibilities.

4. **Objects hold their own state.** The Parcel knows its contents. The Waybill knows the bureau's response. The Delivery knows its status. No data extraction between objects.

5. **Carson IS the entry point.** The company is the CLI. When the agent calls `carson deliver`, Carson creates the right employee and assigns them the work.

6. **Dependencies are tools, not identity.** Git and gh are tools employees and the warehouse use internally. They're implementation detail, not domain concepts.

## Design Status

This spec defines the complete domain model:
- What the objects ARE
- What they know
- How they relate
- How they interact (sequence flows)
- What the public interfaces look like (story language)
- How commands map to employees
- How files are organised

Next step: implement.
