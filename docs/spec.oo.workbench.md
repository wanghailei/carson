# Workbench Refactor — Pure OO

Spec date: 2026-03-24

Implements spec.oo.md Phase 4 items 37–38, 40.

## Problem

`Carson::Worktree` (lib/carson/worktree.rb, 660 lines) is procedural code in a class wrapper. Domain behaviour lives on class methods. `private_class_method` is used because Ruby's `private` keyword cannot govern `def self.` methods. The instance holds state but the class holds lifecycle — two personalities in one body.

The OO spec is clear: the workbench is a passive object that shows state. The Warehouse owns its lifecycle (build, tear down, sweep, safety checks). The workbench does not act.

## Design

### The Workbench — Passive State Object

A workbench is a place in the warehouse where the agent works. It shows state. It does not act. The Warehouse owns its lifecycle.

**What a workbench knows:**

| Knowledge | Attribute / method |
|---|---|
| Where it is | `path` |
| What label it carries | `branch` |
| Why git considers it stale | `prunable_reason` |
| Whether it still physically exists | `exists?` |
| Whether its surface is clean | `clean?` |
| Whether git marks it stale | `prunable?` |

**What a workbench does NOT know:**

- Whether the agent is standing at it (warehouse safety check)
- Whether another process occupies it (warehouse safety check)
- Whether its commits are pushed (warehouse safety check)
- How to build or tear down itself (warehouse lifecycle)

### Carson::Worktree — The Class

```ruby
# A workbench in the warehouse. A passive place where the agent works.
# It shows state — path, branch, prunable reason — but does not act.
# The Warehouse owns its lifecycle.
#
# What a workbench knows:
#   - where it is (path)
#   - what label it carries (branch)
#   - whether it still physically exists (directory present)
#   - whether its surface is clean (no uncommitted changes)
#   - whether git considers it stale (prunable)
module Carson
	class Worktree
		attr_reader :path, :branch, :prunable_reason

		def initialize( path:, branch:, prunable_reason: nil )
			@path = path
			@branch = branch
			@prunable_reason = prunable_reason
		end

		# Does this workbench still physically exist?
		def exists?
			Dir.exist?( path )
		end

		# Is the workbench surface clean? (no uncommitted changes)
		def clean?
			return false unless exists?

			stdout, = Open3.capture3( "git", "status", "--porcelain", chdir: path )
			stdout.to_s.strip.empty?
		rescue StandardError
			false
		end

		# Is git marking this workbench as stale?
		def prunable?
			!prunable_reason.to_s.strip.empty?
		end
	end
end
```

No class methods. No lifecycle. No `runtime`. No `private_class_method`. Three attributes, three queries. Approximately 30 lines.

### Carson::Warehouse::Workbench — The Concern

The Warehouse gains workbench capabilities through a companion module, following the Rails pattern (like `ActiveRecord::Relation` with `relation/query_methods.rb`).

**File layout:**

```
lib/carson/
  warehouse.rb                ← core class + includes
  warehouse/
    workbench.rb              ← the workbench concern
    seal.rb                   ← the seal concern (extracted from warehouse.rb)
    bureau.rb                 ← the bureau concern (extracted from warehouse.rb)
```

**Stories the Warehouse handles:**

1. **Agent: "I need a place to work."** The Warehouse builds a new workbench from the latest production standard.
2. **Agent: "I'm done with this workbench."** The Warehouse checks safety, then tears down the workbench — directory, registration, label.
3. **Warehouse sweeps.** The Warehouse walks its workbenches, checks each one's state, tears down those safe to reap. Repairs any that are physically missing (integrity anomaly).
4. **Warehouse inventories.** List all workbenches. Find by path or name.

**Module interface:**

```ruby
# The warehouse's workbench concern.
# Builds, tears down, sweeps, and inventories workbenches.
# Workbenches are passive objects — the warehouse acts on them.
module Carson
	class Warehouse
		module Workbench

			# --- Inventory ---

			# All workbenches in this warehouse.
			# Parses the git worktree registry into Worktree instances.
			def workbenches

			# Find a workbench by canonical path.
			def workbench_at( path: )

			# Resolve a bare name and find the workbench.
			def workbench_named( name: )

			# Is this path a registered workbench?
			def workbench_registered?( path: )

			# --- Lifecycle ---

			# Build a new workbench from the latest production standard.
			# Creates the directory, branches from the latest standard,
			# ensures .claude/ is excluded from git status.
			def build_workbench!( name: )

			# Tear down a workbench — directory, registration, label.
			# The warehouse checks safety before acting.
			def tear_down_workbench!( workbench, force: false, skip_unpushed: false )

			# Sweep stale workbenches. Walk all agent-owned workbenches,
			# check state, tear down those safe to reap. Repair missing ones.
			def sweep_workbenches!

		private

			# --- Safety checks ---
			# The warehouse inspects the workbench and its environment.

			# Is the agent's working directory inside this workbench?
			def agent_at_workbench?( workbench )

			# Is another process occupying this workbench?
			def workbench_held_by_process?( workbench )

			# Would tearing down lose unpushed work?
			# Content-aware: compares tree content vs main, not SHAs.
			def workbench_has_unpushed_work?( workbench )

			# Full safety assessment before tear-down.
			# Returns { status:, error:, recovery: } or { status: :ok }.
			def assess_teardown( workbench, force: false, skip_unpushed: false )

			# --- Repair ---

			# Handle a missing workbench — prune stale registration,
			# clean up label. Called during sweep or tear-down when the
			# directory is gone.
			def repair_missing_workbench!( workbench )

			# --- Build helpers ---

			# Verify the workbench was created correctly.
			def workbench_creation_verified?( path:, branch: )

			# Clean up partial state from a failed build.
			def cleanup_partial_build!( path:, branch: )

			# Capture diagnostic state for a build verification failure.
			def gather_build_diagnostics( git_stdout:, git_stderr:, name: )

			# Ensure .claude/ is in .git/info/exclude.
			def ensure_claude_dir_excluded!

			# --- Path resolution ---

			# Resolve a bare name, relative path, or absolute path
			# to a canonical workbench path.
			def resolve_workbench_path( name )
		end
	end
end
```

### Companion Extractions

Two existing concerns in `warehouse.rb` move to companion files:

**`warehouse/seal.rb` — `Carson::Warehouse::Seal`**

Extracted from current `warehouse.rb` lines 109–136. Renamed from shelf to workbench:

- `seal_workbench!( tracking_number: )` (was `seal_shelf!`)
- `unseal_workbench!` (was `unseal_shelf!`)
- `sealed?`
- `sealed_tracking_number`
- Private: `delivering_marker_path`

**`warehouse/bureau.rb` — `Carson::Warehouse::Bureau`**

Extracted from current `warehouse.rb` lines 174–334:

- `check_parcel_at_bureau_with( waybill )`
- `file_waybill_for!( parcel, title:, body_file: )`
- `register_parcel_at_bureau_with!( waybill, method: )`
- Private: `fetch_pr_state_for`, `fetch_ci_state_for`, `find_existing_waybill_for`

### What warehouse.rb Keeps

After extraction, `warehouse.rb` holds the core identity:

- `initialize`, `path`, `main_label`, `bureau_address`
- `current_label`, `current_head`
- `clean?`, `pack!`, `ship`
- `based_on_latest_standard?`, `rebase_on_latest_standard!`, `receive_latest_standard!`
- `labels`, `label_absorbed?`, `main_worktree_root`
- `git` and `gh` private gateways
- `include Workbench, Seal, Bureau`

### Output Concern

The Warehouse does not handle output rendering. Warehouse methods return result hashes. The Runtime delegates (transitional) handle JSON/human rendering. When Runtime dissolves, Carson.report takes over.

```ruby
# Warehouse returns a result
result = warehouse.build_workbench!( name: "feature-auth" )
# => { command: "worktree create", status: "ok", name: ..., path: ..., branch: ... }

# Runtime delegate renders it (transitional)
def worktree_create!( name:, json_output: false )
	result = warehouse.build_workbench!( name: name )
	finish_worktree( result: result, json_output: json_output )
end
```

## Caller Changes

### Runtime Delegate (`runtime/local/worktree.rb`)

```ruby
# Before
def worktree_create!( name:, json_output: false )
	Worktree.create!( name: name, runtime: self, json_output: json_output )
end

def worktree_remove!( worktree_path:, force: false, skip_unpushed: false, json_output: false )
	Worktree.remove!( path: worktree_path, runtime: self, force: force,
		skip_unpushed: skip_unpushed, json_output: json_output )
end

def sweep_stale_worktrees!
	Worktree.sweep_stale!( runtime: self )
end

def worktree_list
	Worktree.list( runtime: self )
end

# After
def worktree_create!( name:, json_output: false )
	result = warehouse.build_workbench!( name: name )
	finish_worktree( result: result, json_output: json_output )
end

def worktree_remove!( worktree_path:, force: false, skip_unpushed: false, json_output: false )
	workbench = warehouse.workbench_named( worktree_path )
	unless workbench
		return finish_worktree(
			result: { command: "worktree remove", status: "error",
				name: worktree_path, error: "not a registered worktree",
				recovery: "carson worktree list" },
			json_output: json_output )
	end
	result = warehouse.tear_down_workbench!(
		workbench, force: force, skip_unpushed: skip_unpushed )
	finish_worktree( result: result, json_output: json_output )
end

def sweep_stale_worktrees!
	warehouse.sweep_workbenches!
end

def worktree_list
	warehouse.workbenches
end
```

### Abandon (`runtime/abandon.rb`)

```ruby
# Before
check = Worktree.remove_check( path: worktree.path, runtime: self,
	force: false, skip_unpushed: true )

# After
check = warehouse.assess_teardown( workbench, force: false, skip_unpushed: true )
```

### Housekeep (`runtime/housekeep.rb`)

```ruby
# Before
worktree = Worktree.find( path: worktree_path, runtime: self )
# uses: worktree.holds_cwd?, worktree.held_by_other_process?, worktree.dirty?

# After
workbench = warehouse.workbench_at( path: worktree_path )
# uses: workbench.exists?, workbench.clean?
# safety checks called internally by warehouse sweep/teardown
```

Note: `classify_worktree_cleanup` stays on Runtime for now. It queries workbench state (via instance methods) and PR state (via `gh`). When `warehouse.sweep_workbenches!` absorbs housekeep fully, this logic moves into the Workbench concern.

## Migration Table

| Current (Worktree) | Target |
|---|---|
| `Worktree.list( runtime: )` | `warehouse.workbenches` |
| `Worktree.find( path:, runtime: )` | `warehouse.workbench_at( path: )` |
| `Worktree.registered?( path:, runtime: )` | `warehouse.workbench_registered?( path: )` |
| `Worktree.create!( name:, runtime:, json_output: )` | `warehouse.build_workbench!( name: )` |
| `Worktree.remove!( path:, runtime:, force:, ... )` | `warehouse.tear_down_workbench!( workbench, force: )` |
| `Worktree.remove_check( path:, runtime:, ... )` | `warehouse.assess_teardown( workbench, ... )` |
| `Worktree.sweep_stale!( runtime: )` | `warehouse.sweep_workbenches!` |
| `worktree.holds_cwd?` | `warehouse.agent_at_workbench?( workbench )` (private) |
| `worktree.held_by_other_process?` | `warehouse.workbench_held_by_process?( workbench )` (private) |
| `worktree.dirty?` | `workbench.clean?` (inverted, on instance) |
| `worktree.exists?` | `workbench.exists?` (on instance) |
| `worktree.prunable?` | `workbench.prunable?` (on instance) |
| `Worktree::AGENT_DIRS` | `Warehouse::Workbench::AGENT_DIRS` |
| `seal_shelf!` | `seal_workbench!` (in Warehouse::Seal) |
| `unseal_shelf!` | `unseal_workbench!` (in Warehouse::Seal) |
| `shelves` | absorbed into `workbenches` |
| `private_class_method :*` | eliminated (zero remain) |

## What Dies

- Every `private_class_method` call in Worktree (zero remain)
- `runtime:` argument threading through Worktree (Warehouse holds its own infrastructure)
- ~630 lines of Worktree class methods (moved to Warehouse::Workbench)
- `dirty?` instance method (replaced by `clean?` — positive predicate)
- `holds_cwd?` and `held_by_other_process?` as instance methods (became warehouse safety checks)
- Mixed class/instance design in Worktree

## What Lives

- `Carson::Worktree` as a passive state object (~30 lines)
- `Carson::Warehouse::Workbench` module with all lifecycle
- `Carson::Warehouse::Seal` module (extracted, renamed shelf → workbench)
- `Carson::Warehouse::Bureau` module (extracted)
- All existing test coverage (updated to match new call patterns)
- `classify_worktree_cleanup` on Runtime (transitional, moves to Warehouse::Workbench later)

## Test Strategy

Tests update to match new method signatures. Same assertions, same coverage.

- `test/worktree_test.rb` — passive state: `exists?`, `clean?`, `prunable?`
- `test/warehouse_workbench_test.rb` — lifecycle: build, tear down, sweep, safety, repair
- `test/warehouse_seal_test.rb` — seal lifecycle (renamed from shelf)
- `test/warehouse_bureau_test.rb` — bureau interaction
- `test/runtime_worktree_lifecycle_test.rb` — integration through Runtime delegates (updated call patterns)

## References

- spec.oo.md § 7 (Warehouse Domain), Phase 4 items 37–38, 40
- Rails companion directory pattern (ActiveRecord::Relation, relation/*.rb)
- ~/AI/core/CODING/RUBY.md § Pure OO Design
- ~/AI/docs/study/ruby-pure-oo.md
