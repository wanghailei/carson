# Carson OO Refactoring — The FedEx Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Carson from a procedural god-object (Runtime) into pure OO domain classes using the FedEx delivery service metaphor.

**Architecture:** New domain classes (Parcel, Warehouse, Waybill, Courier, Cleaner, Dispatcher) are built alongside existing code using TDD. Each new class is tested independently. Once a new class is proven, the corresponding Runtime method delegates to it. Old code is removed only after all tests pass through the new path. No big bang — incremental extraction with continuous green tests.

**Tech Stack:** Ruby, Minitest, Carson test helpers (CarsonTestSupport), Open3 for git/gh subprocess calls.

**Spec:** `docs/spec/spec.20260322.oo-fedex.md` (the FedEx metaphor domain model)

---

## Phasing Strategy

The refactoring is split into phases. Each phase produces working software. All 483 existing tests pass after every phase.

| Phase | Scope | New files | Priority |
|---|---|---|---|
| **1** | Parcel + Warehouse | `parcel.rb`, `warehouse.rb` + tests | Tonight |
| **2** | Waybill | `waybill.rb` + tests | Tonight |
| **3** | Courier (deliver) | `courier.rb` + tests, wire into CLI | Tonight |
| **4** | Cleaner (sweep) | `cleaner.rb` + tests | Next session |
| **5** | Dispatcher (monitor/track) | `dispatcher.rb` + tests | Next session |
| **6** | Rename commands + cleanup | CLI, file renames, remove dead code | Next session |

Phases 1-3 are the critical path — the delivery flow. Phases 4-6 are independent and can follow in subsequent sessions.

---

## File Structure

### New files to create

```
lib/carson/
  parcel.rb              ← the committed changes (the thing being delivered)
  warehouse.rb           ← the repository (wraps git with story-language methods)
  waybill.rb             ← the shipping document (wraps PR interaction with bureau)
  courier.rb             ← the delivery person (orchestrates delivery)
  cleaner.rb             ← the warehouse cleaner (Phase 4)
  dispatcher.rb          ← the delivery monitor (Phase 5)

test/
  parcel_test.rb
  warehouse_test.rb
  waybill_test.rb
  courier_test.rb
  cleaner_test.rb         (Phase 4)
  dispatcher_test.rb      (Phase 5)
```

### Existing files to modify (later phases)

```
lib/carson/cli.rb              ← route commands to employees instead of Runtime
lib/carson/delivery.rb         ← add self-persistence (hide the ledger)
lib/carson/runtime/deliver.rb  ← delegate to Courier, then remove
lib/carson/runtime.rb          ← thin down as employees take over
```

### Naming rule

All class names, method names, and public interfaces use story language (FedEx metaphor). Git and GitHub terms appear only inside method bodies and private variables. See spec § Naming Rule for the full mapping.

---

## Phase 1: Parcel + Warehouse

### Task 1: Carson::Parcel

The parcel is the committed changes — the thing being delivered. It's the simplest domain object. Start here to establish the pattern.

**Files:**
- Create: `lib/carson/parcel.rb`
- Create: `test/parcel_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/parcel_test.rb
require "minitest/autorun"
require_relative "../lib/carson/parcel"

class ParcelTest < Minitest::Test
	def test_knows_its_label
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_equal "feature/login", parcel.label
	end

	def test_knows_its_head
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_equal "abc123", parcel.head
	end

	def test_knows_its_shelf
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123", shelf: "/tmp/worktree" )
		assert_equal "/tmp/worktree", parcel.shelf
	end

	def test_shelf_is_optional
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_nil parcel.shelf
	end

	def test_knows_when_on_main
		parcel = Carson::Parcel.new( label: "main", head: "abc123" )
		assert parcel.on_main?( "main" )
	end

	def test_knows_when_not_on_main
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		refute parcel.on_main?( "main" )
	end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/parcel_test.rb`
Expected: FAIL — `Carson::Parcel` not defined

- [ ] **Step 3: Write the implementation**

```ruby
# lib/carson/parcel.rb
# The committed changes on a branch — the thing being delivered.
# A parcel sits on a shelf (worktree) identified by a label (branch name).
# It does not deliver itself — the courier does that.
module Carson
	class Parcel
		attr_reader :label, :head, :shelf

		def initialize( label:, head:, shelf: nil )
			@label = label
			@head = head
			@shelf = shelf
		end

		def on_main?( main_label )
			label == main_label
		end
	end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Ilib -Itest test/parcel_test.rb`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lib/carson/parcel.rb test/parcel_test.rb
git commit -m "Add Carson::Parcel — the committed changes being delivered"
```

---

### Task 2: Carson::Warehouse

The warehouse wraps a git repository with story-language methods. It knows its shelves, labels, config, and can ship parcels. Git commands are hidden inside.

This is the biggest foundation object. It absorbs `repo_root`, `current_branch`, `current_head`, `push_branch!`, `assess_branch_freshness`, and other Runtime methods. Built incrementally — start with identity and querying, add operations later.

**Files:**
- Create: `lib/carson/warehouse.rb`
- Create: `test/warehouse_test.rb`

- [ ] **Step 1: Write failing tests for identity and query methods**

```ruby
# test/warehouse_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/carson/warehouse"

class WarehouseTest < Minitest::Test
	def setup
		@dir = Dir.mktmpdir( "warehouse-test" )
		system( "git", "-C", @dir, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @dir, "commit", "--allow-empty", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.rm_rf( @dir )
	end

	def test_knows_its_path
		warehouse = Carson::Warehouse.new( path: @dir )
		assert_equal File.expand_path( @dir ), warehouse.path
	end

	def test_current_label_returns_branch_name
		warehouse = Carson::Warehouse.new( path: @dir )
		assert_equal "main", warehouse.current_label
	end

	def test_current_head_returns_sha
		warehouse = Carson::Warehouse.new( path: @dir )
		assert_match( /\A[0-9a-f]{40}\z/, warehouse.current_head )
	end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/warehouse_test.rb`
Expected: FAIL — `Carson::Warehouse` not defined

- [ ] **Step 3: Write minimal implementation**

```ruby
# lib/carson/warehouse.rb
# A governed repository — the warehouse where parcels are stored and shipped from.
# Wraps git operations with story-language methods. Git terms are hidden inside.
require "open3"

module Carson
	class Warehouse
		attr_reader :path

		def initialize( path:, work_dir: nil )
			@path = File.expand_path( path )
			@work_dir = work_dir || @path
		end

		# The label on the current shelf (branch name).
		def current_label
			git( "rev-parse", "--abbrev-ref", "HEAD" ).strip
		end

		# The tip of the parcel on the current shelf (commit SHA).
		def current_head
			git( "rev-parse", "HEAD" ).strip
		end

		private

		def git( *args )
			stdout, stderr, status = Open3.capture3( "git", *args, chdir: @work_dir )
			raise "git #{args.first} failed: #{stderr}" unless status.success?
			stdout
		end
	end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ruby -Ilib -Itest test/warehouse_test.rb`
Expected: all PASS

- [ ] **Step 5: Commit**

```bash
git add lib/carson/warehouse.rb test/warehouse_test.rb
git commit -m "Add Carson::Warehouse — the repository with story-language methods"
```

- [ ] **Step 6: Add shipping and registry methods with tests**

Add tests for `ship`, `fetch_latest`, and `includes_latest?`:

```ruby
# Additional tests in warehouse_test.rb

def test_ship_pushes_parcel_to_remote
	# Set up a bare remote
	remote = Dir.mktmpdir( "remote" )
	system( "git", "-C", remote, "init", "--bare", "-b", "main", out: File::NULL, err: File::NULL )
	system( "git", "-C", @dir, "remote", "add", "github", remote, out: File::NULL, err: File::NULL )

	# Create a branch with a commit
	system( "git", "-C", @dir, "checkout", "-b", "feature/test", out: File::NULL, err: File::NULL )
	system( "git", "-C", @dir, "commit", "--allow-empty", "-m", "feature", out: File::NULL, err: File::NULL )

	warehouse = Carson::Warehouse.new( path: @dir )
	parcel = Carson::Parcel.new( label: "feature/test", head: warehouse.current_head )

	warehouse.ship( parcel, remote: "github" )

	# Verify the branch exists on the remote
	stdout, _, status = Open3.capture3( "git", "-C", remote, "branch", "--list", "feature/test" )
	assert status.success?
	refute stdout.strip.empty?, "branch should exist on remote after shipping"
ensure
	FileUtils.rm_rf( remote )
end

def test_includes_latest_returns_true_when_up_to_date
	warehouse = Carson::Warehouse.new( path: @dir )
	parcel = Carson::Parcel.new( label: "main", head: warehouse.current_head )
	# On main, the parcel includes main — trivially true
	assert warehouse.includes_latest?( parcel, registry: "main" )
end

def test_includes_latest_returns_false_when_behind
	# Create a branch, then advance main
	system( "git", "-C", @dir, "checkout", "-b", "feature/old", out: File::NULL, err: File::NULL )
	system( "git", "-C", @dir, "checkout", "main", out: File::NULL, err: File::NULL )
	system( "git", "-C", @dir, "commit", "--allow-empty", "-m", "advance", out: File::NULL, err: File::NULL )
	system( "git", "-C", @dir, "checkout", "feature/old", out: File::NULL, err: File::NULL )

	warehouse = Carson::Warehouse.new( path: @dir )
	parcel = Carson::Parcel.new( label: "feature/old", head: warehouse.current_head )
	refute warehouse.includes_latest?( parcel, registry: "main" )
end
```

- [ ] **Step 7: Implement shipping and registry methods**

```ruby
# Add to Carson::Warehouse

# Ship the parcel to the bureau (git push).
def ship( parcel, remote: )
	git( "push", "--no-verify", "-u", remote, parcel.label )
end

# Fetch the latest registry state from the bureau (git fetch).
def fetch_latest( remote:, registry: )
	git( "fetch", remote, registry )
end

# Does the parcel include the latest registry state?
# True if the registry head is an ancestor of the parcel head.
def includes_latest?( parcel, registry: )
	_, _, status = Open3.capture3(
		"git", "merge-base", "--is-ancestor", registry, parcel.head,
		chdir: @work_dir
	)
	status.success?
end
```

- [ ] **Step 8: Run tests, verify all pass**

Run: `ruby -Ilib -Itest test/warehouse_test.rb`
Expected: all PASS

- [ ] **Step 9: Commit**

```bash
git add lib/carson/warehouse.rb test/warehouse_test.rb
git commit -m "Add Warehouse shipping and registry methods"
```

---

## Phase 2: Waybill

### Task 3: Carson::Waybill

The waybill is the shipping document filed with the bureau (GitHub PR). It has a tracking number, knows the bureau's response (CI, review, mergeability), and can ask the bureau to accept the parcel.

This is the most complex extraction — it absorbs `find_or_create_pr!`, `check_pr_ci`, `pull_request_state`, `github_merge_assessment`, `classify_merge_failure`, and `merge_pr!` from deliver.rb.

**Files:**
- Create: `lib/carson/waybill.rb`
- Create: `test/waybill_test.rb`

- [ ] **Step 1: Write failing tests for identity and filing**

```ruby
# test/waybill_test.rb
require "minitest/autorun"
require_relative "../lib/carson/waybill"

class WaybillTest < Minitest::Test
	def test_unfiled_waybill_is_not_filed
		waybill = Carson::Waybill.new( label: "feature/test", warehouse_path: "/tmp/repo" )
		refute waybill.filed?
	end

	def test_filed_waybill_knows_tracking_number
		waybill = Carson::Waybill.new(
			label: "feature/test",
			warehouse_path: "/tmp/repo",
			tracking_number: 42,
			url: "https://github.com/owner/repo/pull/42"
		)
		assert waybill.filed?
		assert_equal 42, waybill.tracking_number
	end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/waybill_test.rb`
Expected: FAIL — `Carson::Waybill` not defined

- [ ] **Step 3: Write minimal implementation (identity only)**

```ruby
# lib/carson/waybill.rb
# The shipping document filed with the bureau (GitHub PR).
# Has a tracking number. Knows the bureau's response. Can ask for acceptance.
# Uses gh CLI internally — that's the tool, not the domain.
require "json"
require "open3"

module Carson
	class Waybill
		attr_reader :tracking_number, :url, :label

		def initialize( label:, warehouse_path:, tracking_number: nil, url: nil, review_gate: nil )
			@label = label
			@warehouse_path = warehouse_path
			@tracking_number = tracking_number
			@url = url
			@review_gate = review_gate
			@state = nil
			@ci = nil
		end

		def filed?
			!tracking_number.nil?
		end
	end
end
```

- [ ] **Step 4: Run test to verify it passes, commit**

Run: `ruby -Ilib -Itest test/waybill_test.rb`

```bash
git add lib/carson/waybill.rb test/waybill_test.rb
git commit -m "Add Carson::Waybill — the shipping document (identity)"
```

- [ ] **Step 5: Add bureau response tests (cleared?, held?, accepted?)**

```ruby
# Additional tests in waybill_test.rb

def test_cleared_when_ci_passes_and_merge_clean
	waybill = build_waybill
	waybill.stub_state( { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" } )
	waybill.stub_ci( :pass )
	assert waybill.cleared?
end

def test_held_when_ci_pending
	waybill = build_waybill
	waybill.stub_state( { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "BLOCKED" } )
	waybill.stub_ci( :pending )
	assert waybill.held?
	assert_equal "inspector_pending", waybill.hold_reason
end

def test_accepted_when_merged
	waybill = build_waybill
	waybill.stub_state( { "state" => "MERGED" } )
	assert waybill.accepted?
end

def test_rejected_when_closed
	waybill = build_waybill
	waybill.stub_state( { "state" => "CLOSED" } )
	assert waybill.rejected?
end

private

def build_waybill
	Carson::Waybill.new(
		label: "feature/test",
		warehouse_path: "/tmp/repo",
		tracking_number: 42,
		url: "https://github.com/owner/repo/pull/42"
	)
end
```

- [ ] **Step 6: Implement bureau response methods**

These methods absorb logic from `github_merge_assessment`, `delivery_assessment`, and `evaluate_delivery_for_settle`:

```ruby
# Add to Carson::Waybill

def refresh!
	@state = fetch_state
	@ci = fetch_ci
	self
end

def accepted?
	@state&.dig( "state" ) == "MERGED"
end

def rejected?
	@state&.dig( "state" ) == "CLOSED"
end

def draft?
	@state&.dig( "isDraft" ) || false
end

def cleared?
	return false unless filed?
	return false if draft?
	return false unless @ci == :pass
	merge_status = @state&.dig( "mergeStateStatus" ).to_s.upcase
	mergeable = @state&.dig( "mergeable" ).to_s.upcase
	merge_status == "CLEAN" || mergeable == "MERGEABLE"
end

def held?
	return false if cleared? || accepted? || rejected?
	true
end

def hold_reason
	return "draft" if draft?
	return "inspector_pending" if @ci == :pending
	return "inspector_failed" if @ci == :fail
	return "merge_conflict" if merge_conflicting?
	return "behind_registry" if merge_behind?
	return "policy_block" if merge_blocked?
	"pending"
end

def hold_summary
	case hold_reason
	when "draft" then "waybill is still a draft"
	when "inspector_pending" then "waiting for customs inspection"
	when "inspector_failed" then "customs inspection failed"
	when "merge_conflict" then "parcel has conflicts with registry"
	when "behind_registry" then "parcel is behind the registry"
	when "policy_block" then "blocked by bureau policy"
	else "waiting for bureau assessment"
	end
end

# Ask the bureau to accept the parcel into the registry.
def accept!( method: )
	_, stderr, success, = gh( "pr", "merge", tracking_number.to_s, "--#{method}" )
	unless success
		classify_rejection( stderr.to_s.strip )
	end
	refresh!
	self
end

private

def merge_conflicting?
	status = @state&.dig( "mergeStateStatus" ).to_s.upcase
	mergeable = @state&.dig( "mergeable" ).to_s.upcase
	mergeable == "CONFLICTING" || status == "DIRTY" || status == "CONFLICTING"
end

def merge_behind?
	@state&.dig( "mergeStateStatus" ).to_s.upcase == "BEHIND"
end

def merge_blocked?
	@state&.dig( "mergeStateStatus" ).to_s.upcase == "BLOCKED"
end

def fetch_state
	stdout, _, success, = gh( "pr", "view", tracking_number.to_s,
		"--json", "number,state,isDraft,url,mergeStateStatus,mergeable,mergedAt" )
	return nil unless success
	JSON.parse( stdout ) rescue nil
end

def fetch_ci
	stdout, _, success, = gh( "pr", "checks", tracking_number.to_s, "--json", "name,bucket" )
	return :error unless success
	checks = JSON.parse( stdout ) rescue []
	return :none if checks.empty?
	buckets = checks.map { |entry| entry[ "bucket" ].to_s.downcase }
	return :fail if buckets.include?( "fail" )
	return :pending if buckets.include?( "pending" )
	:pass
end

def gh( *args )
	stdout, stderr, status = Open3.capture3( "gh", *args, chdir: @warehouse_path )
	[ stdout, stderr, status.success?, status.exitstatus ]
end
```

- [ ] **Step 7: Add stub methods for testing (test helper)**

```ruby
# Add to Carson::Waybill for test support

def stub_state( state )
	@state = state
end

def stub_ci( ci )
	@ci = ci
end
```

- [ ] **Step 8: Run tests, verify all pass, commit**

Run: `ruby -Ilib -Itest test/waybill_test.rb`

```bash
git add lib/carson/waybill.rb test/waybill_test.rb
git commit -m "Add Waybill bureau response and acceptance methods"
```

- [ ] **Step 9: Add waybill filing (find existing or create new)**

Add `file!` method and `self.find` class method. Tests with mock gh.

```bash
git commit -m "Add Waybill filing — find existing or create new"
```

---

## Phase 3: Courier

### Task 4: Carson::Courier

The courier is the delivery person. Assigned to a warehouse. Delivers parcels by shipping, filing waybills, settling at customs, and collecting proof.

This absorbs the `deliver!` orchestration and the settle loop from deliver.rb.

**Files:**
- Create: `lib/carson/courier.rb`
- Create: `test/courier_test.rb`

- [ ] **Step 1: Write failing test for basic delivery guard**

```ruby
# test/courier_test.rb
require "minitest/autorun"
require_relative "../lib/carson/courier"
require_relative "../lib/carson/parcel"
require_relative "../lib/carson/warehouse"

class CourierTest < Minitest::Test
	def test_blocks_delivery_from_main
		warehouse = build_warehouse
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "main", head: "abc123" )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /cannot deliver from main/, result[ :error ] )
	end
end
```

- [ ] **Step 2: Implement Courier skeleton with guards**

```ruby
# lib/carson/courier.rb
# The delivery person — picks up parcels and delivers them to the registry.
# Assigned to one warehouse. Uses git and gh tools internally.
module Carson
	class Courier
		BLOCKED = 2
		OK = 0
		ERROR = 1
		MERGE_ATTEMPT_CAP = 3

		def initialize( warehouse, output: $stdout, verbose: false )
			@warehouse = warehouse
			@output = output
			@verbose = verbose
		end

		def deliver( parcel, title: nil, body_file: nil, commit_message: nil )
			result = { command: "deliver", label: parcel.label }

			if parcel.on_main?( warehouse.main_label )
				return blocked( result, "cannot deliver from #{warehouse.main_label}" )
			end

			# ... rest of delivery flow ...
			result
		end

		private

		attr_reader :warehouse

		def blocked( result, message, recovery: nil )
			result[ :exit ] = BLOCKED
			result[ :error ] = message
			result[ :recovery ] = recovery
			result
		end
	end
end
```

- [ ] **Step 3: Run test, verify pass, commit**

```bash
git commit -m "Add Carson::Courier — delivery person skeleton with guards"
```

- [ ] **Step 4: Build out the full delivery flow incrementally**

Each sub-step adds one stage of the delivery flow with its test:

1. **Ship the parcel** — courier calls `warehouse.ship( parcel )`
2. **File the waybill** — courier creates `Waybill.new(...)`, calls `file!`
3. **Create delivery record** — courier writes tracking record
4. **Settle loop** — courier waits at customs, checks `waybill.cleared?`, calls `waybill.accept!`
5. **Proof of delivery** — courier collects merge proof
6. **Report** — courier reports result to agent

Each sub-step: write test → run (fail) → implement → run (pass) → commit.

- [ ] **Step 5: Final commit for complete Courier**

```bash
git commit -m "Complete Courier delivery flow with settle loop"
```

---

### Task 5: Wire Courier into CLI

Make `carson deliver` create a Courier and delegate to it. Keep the old Runtime::Deliver as fallback during transition.

**Files:**
- Modify: `lib/carson/cli.rb`
- Modify: `lib/carson/runtime/deliver.rb` (delegate to Courier)

- [ ] **Step 1: Add require statements**

```ruby
# In lib/carson.rb or where requires are centralised
require_relative "carson/parcel"
require_relative "carson/warehouse"
require_relative "carson/waybill"
require_relative "carson/courier"
```

- [ ] **Step 2: Make Runtime::Deliver delegate to Courier**

```ruby
# In runtime/deliver.rb — make deliver! create a Courier internally
def deliver!( title: nil, body_file: nil, commit_message: nil, json_output: false )
	warehouse = Warehouse.new( path: main_worktree_root, work_dir: repo_root )
	parcel = Parcel.new( label: current_branch, head: current_head, shelf: repo_root )
	courier = Courier.new( warehouse, output: output, verbose: verbose? )

	courier.deliver( parcel, title: title, body_file: body_file, commit_message: commit_message )
end
```

- [ ] **Step 3: Run ALL existing tests**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: all 483+ tests PASS

- [ ] **Step 4: Commit**

```bash
git commit -m "Wire Courier into deliver! — new OO path"
```

---

## Phase 4: Cleaner (next session)

### Task 6: Carson::Cleaner

Absorbs `housekeep!`, `reap_dead_worktrees!`, stale branch pruning from `runtime/housekeep.rb`.

**Files:**
- Create: `lib/carson/cleaner.rb`
- Create: `test/cleaner_test.rb`

(Detailed steps follow same TDD pattern as Courier)

---

## Phase 5: Dispatcher (next session)

### Task 7: Carson::Dispatcher

Absorbs `govern!`, `reconcile_delivery!`, `status` from `runtime/govern.rb` and `runtime/status.rb`.

**Files:**
- Create: `lib/carson/dispatcher.rb`
- Create: `test/dispatcher_test.rb`

(Detailed steps follow same TDD pattern)

---

## Phase 6: Rename commands + cleanup (next session)

### Task 8: Rename CLI commands

| Old | New |
|---|---|
| `carson govern` | `carson monitor` |
| `carson housekeep` | `carson sweep` |
| `carson abandon` | `carson return` |
| `carson recover` | `carson salvage` |
| `carson status` | `carson track` |

### Task 9: Remove dead code

- Remove `runtime/deliver.rb` (replaced by `courier.rb`)
- Remove `runtime/housekeep.rb` (replaced by `cleaner.rb`)
- Remove `runtime/govern.rb` (replaced by `dispatcher.rb`)
- Thin `runtime.rb` — only shared infrastructure remains
- Rename remaining Runtime modules to story names

### Task 10: Rename files

- `repository.rb` → keep as internal (Warehouse wraps it)
- `worktree.rb` → `shelf.rb`
- `branch.rb` → `label.rb`

---

## Testing Strategy

### New object tests

Each new class gets its own test file with unit tests. Tests use real git repos (tmpdir) where possible, mock gh CLI where needed.

### Existing test compatibility

All 483+ existing tests must pass throughout the refactoring. The transition strategy:
1. New classes are tested independently
2. Runtime methods delegate to new classes
3. Existing tests exercise the new path through Runtime
4. Only after all tests pass do we remove old code

### Test commands

```bash
# Run one test file
ruby -Ilib -Itest test/parcel_test.rb

# Run all tests
ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"
```

---

## Marathon Tonight: Scope

Tasks 1-5 (Phases 1-3) are tonight's scope:
1. Carson::Parcel — 10 minutes
2. Carson::Warehouse — 30 minutes
3. Carson::Waybill — 60 minutes (most complex extraction)
4. Carson::Courier — 45 minutes
5. Wire into CLI — 15 minutes

Total: ~2.5 hours of focused work. All existing tests green at every commit.
