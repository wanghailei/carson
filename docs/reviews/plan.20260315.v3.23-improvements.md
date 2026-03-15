# Carson v3.23 Post-Review Improvements

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 2 confirmed bugs, add regression and coverage tests for critical gaps, and clean up housekeeping items — all identified from the v3.23.0+v3.23.1 code review.

**Architecture:** All fixes are surgical — no structural changes. Bug fixes are one-line corrections. Test coverage additions follow the existing Minitest + CarsonTestSupport pattern with isolated git repos and mock gh binaries. Housekeeping is separated into its own commit.

**Tech Stack:** Ruby, Minitest, JSON, Open3, git CLI

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/carson/runtime/local/onboard.rb` | Modify line 298 | Fix `e` -> `exception` NameError |
| `lib/carson/runtime/deliver.rb` | Modify line 317 | Fix `Process::Status` truthiness bug |
| `test/runtime_setup_test.rb` | Modify | Regression test for onboard audit exception path |
| `test/ledger_test.rb` | Create | Unit tests for revision recording and active-state filtering |
| `test/runtime_govern_test.rb` | Modify | Reconciliation state transition tests |
| `test/runtime_deliver_test.rb` | Modify | Deliver error path tests at adapter boundary |
| `lib/carson/ledger.rb` | Modify | Deduplicate constant + fix indentation (housekeeping) |
| `lib/carson/runtime/govern.rb` | Modify line 84 | Fix pluralisation (housekeeping) |

---

## Task 1: Fix onboard rescue NameError with regression test

**Files:**
- Modify: `lib/carson/runtime/local/onboard.rb:298`
- Modify: `test/runtime_setup_test.rb`

- [ ] **Step 1: Write the failing regression test**

Add to `RuntimeSetupTest`, using the existing `build_onboard_runtime` helper (line 625):

```ruby
def test_onboard_reports_audit_error_when_audit_raises
	remote_dir = File.join( @tmp_dir, "remote.git" )
	system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
	system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
	system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

	tty_input = build_tty_input( "\n\n\n\n" )
	with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
		output = StringIO.new
		runtime = build_onboard_runtime( input: tty_input, output_stream: output )
		# Force audit! to raise so onboard_run_audit! exercises its rescue path
		runtime.define_singleton_method( :audit! ) { |**_| raise StandardError, "simulated audit failure" }

		status = runtime.onboard!

		assert_equal Carson::Runtime::EXIT_OK, status
		assert_includes output.string, "Audit skipped"
	end
end
```

- [ ] **Step 2: Run test to verify it fails (proves the bug)**

```bash
ruby -Ilib -Itest test/runtime_setup_test.rb --name test_onboard_reports_audit_error_when_audit_raises
```

Expected: FAIL — `NameError: undefined local variable or method 'e'` is raised inside `onboard_run_audit!`, but the `ensure` block's `return` swallows it. The ensure calls `onboard_print_audit_result(status: nil, error: nil)`, which does not print "Audit skipped", so the assertion fails.

- [ ] **Step 3: Fix the bug**

Change line 298 of `lib/carson/runtime/local/onboard.rb` from `audit_error = e` to `audit_error = exception`.

- [ ] **Step 4: Run test to verify it passes**

```bash
ruby -Ilib -Itest test/runtime_setup_test.rb --name test_onboard_reports_audit_error_when_audit_raises
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/carson/runtime/local/onboard.rb test/runtime_setup_test.rb
git commit -m "fix: rescue variable NameError in onboard_run_audit!

audit_error = e referenced undefined variable; should be exception.
When audit! raised during onboard, the NameError was silently swallowed
by the ensure block, giving the user no diagnostic.

Adds regression test that stubs audit! to raise and verifies the
'Audit skipped' message appears in onboard output."
```

---

## Task 2: Fix Process::Status truthiness in sync_after_merge!

**Files:**
- Modify: `lib/carson/runtime/deliver.rb:314-317`
- Modify: `test/runtime_deliver_test.rb`

- [ ] **Step 1: Write the failing regression test**

Add to `RuntimeDeliverTest`:

```ruby
def test_sync_after_merge_detects_pull_failure
	runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
	init_git_repo_with_remote( repo_root )

	result = {}
	# Call sync_after_merge! against the repo whose remote has no new
	# commits — git pull --ff-only will succeed, so we need to break it.
	# Remove the remote to force a failure.
	system( "git", "-C", repo_root, "remote", "remove", "origin", out: File::NULL, err: File::NULL )

	runtime.send( :sync_after_merge!, remote: "origin", main: "main", result: result )

	assert_equal false, result[ :synced ]
	refute_nil result[ :sync_error ]
	FileUtils.remove_entry( tmp_dir )
end
```

- [ ] **Step 2: Run test to verify it fails (proves the bug)**

```bash
ruby -Ilib -Itest test/runtime_deliver_test.rb --name test_sync_after_merge_detects_pull_failure
```

Expected: FAIL — `Process::Status` is always truthy, so `result[:synced]` is `true` and the assertion fails.

- [ ] **Step 3: Fix the bug**

Change lines 314-317 from:

```ruby
_, pull_stderr, pull_success, = Open3.capture3(
	"git", "-C", main_root, "pull", "--ff-only", remote, main
)
if pull_success
```

to:

```ruby
_, pull_stderr, pull_status, = Open3.capture3(
	"git", "-C", main_root, "pull", "--ff-only", remote, main
)
if pull_status.success?
```

Rename `pull_success` to `pull_status` to match the convention used elsewhere (e.g. `worktree.rb:87`).

- [ ] **Step 4: Run test to verify it passes**

```bash
ruby -Ilib -Itest test/runtime_deliver_test.rb --name test_sync_after_merge_detects_pull_failure
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/carson/runtime/deliver.rb test/runtime_deliver_test.rb
git commit -m "fix: check Process::Status with .success? in sync_after_merge!

Open3.capture3 returns a Process::Status object which is always truthy.
The condition never took the false branch. Adds regression test that
removes the git remote and calls sync_after_merge!, verifying it
correctly reports synced: false."
```

---

## Task 3: Add Ledger unit tests

**Files:**
- Create: `test/ledger_test.rb`

These tests verify the behavioural contracts of Ledger's revision and delivery operations.

- [ ] **Step 1: Write the test file**

Create `test/ledger_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require "fileutils"

class LedgerTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-ledger-test", carson_tmp_root )
		@ledger = Carson::Ledger.new( path: File.join( @tmp_dir, "test-ledger.json" ) )
		@repository = Carson::Repository.new( path: @tmp_dir, authority: "remote", runtime: nil )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if File.directory?( @tmp_dir )
	end

	# --- record_revision ---

	def test_record_revision_creates_first_revision_with_number_one
		delivery = create_test_delivery
		revision = @ledger.record_revision(
			delivery: delivery,
			cause: "ci",
			provider: "codex",
			status: "completed",
			summary: "fixed CI"
		)
		assert_equal 1, revision.number
		assert_equal "completed", revision.status
		assert_equal "ci", revision.cause
		assert_equal "codex", revision.provider
		refute_nil revision.finished_at
	end

	def test_record_revision_increments_number_sequentially
		delivery = create_test_delivery
		r1 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "attempt 1" )
		r2 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "attempt 2" )
		r3 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "attempt 3" )
		assert_equal 1, r1.number
		assert_equal 2, r2.number
		assert_equal 3, r3.number
	end

	def test_record_revision_sets_finished_at_for_terminal_statuses
		delivery = create_test_delivery
		running = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "running", summary: "in progress" )
		assert_nil running.finished_at

		failed = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "broke" )
		refute_nil failed.finished_at

		stalled = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "stalled", summary: "timeout" )
		refute_nil stalled.finished_at
	end

	def test_record_revision_bumps_delivery_revision_count
		delivery = create_test_delivery
		@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "done" )
		updated = @ledger.active_delivery( repo_path: @tmp_dir, branch_name: "feature/test" )
		assert_equal 1, updated.revision_count
	end

	# --- revisions_for_delivery ---

	def test_revisions_for_delivery_returns_in_ascending_order
		delivery = create_test_delivery
		@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "first" )
		@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "second" )

		revisions = @ledger.revisions_for_delivery( delivery_id: delivery.id )
		assert_equal 2, revisions.length
		assert_equal 1, revisions.first.number
		assert_equal 2, revisions.last.number
		assert_equal "first", revisions.first.summary
		assert_equal "second", revisions.last.summary
	end

	# --- active_deliveries filtering ---

	def test_active_deliveries_returns_only_active_state_deliveries
		# Create deliveries in various states
		active = create_test_delivery( branch_name: "feature/active", head: "aaa", status: "queued" )
		gated = create_test_delivery( branch_name: "feature/gated", head: "bbb", status: "gated" )
		terminal = create_test_delivery( branch_name: "feature/done", head: "ccc", status: "queued" )
		@ledger.update_delivery( delivery: terminal, status: "integrated" )

		actives = @ledger.active_deliveries( repo_path: @tmp_dir )
		active_branches = actives.map( &:branch ).sort
		assert_includes active_branches, "feature/active"
		assert_includes active_branches, "feature/gated"
		refute_includes active_branches, "feature/done"
	end

	def test_active_deliveries_uses_same_states_as_delivery_model
		# Verify that every state Delivery considers active is also
		# returned by Ledger's active_deliveries query.
		Carson::Delivery::ACTIVE_STATES.each_with_index do |state, index|
			create_test_delivery(
				branch_name: "feature/state-#{index}",
				head: "head#{index}",
				status: state
			)
		end

		actives = @ledger.active_deliveries( repo_path: @tmp_dir )
		returned_statuses = actives.map( &:status ).uniq.sort
		expected_statuses = Carson::Delivery::ACTIVE_STATES.sort
		assert_equal expected_statuses, returned_statuses,
			"Ledger active_deliveries must return all states that Delivery considers active"
	end

private

	def create_test_delivery( branch_name: "feature/test", head: "abc123", status: "queued" )
		@ledger.upsert_delivery(
			repository: @repository,
			branch_name: branch_name,
			head: head,
			worktree_path: @tmp_dir,
			authority: "remote",
			pr_number: 1,
			pr_url: "https://github.com/test/repo/pull/1",
			status: status,
			summary: "test delivery",
			cause: nil
		)
	end
end
```

- [ ] **Step 2: Run all ledger tests**

```bash
ruby -Ilib -Itest test/ledger_test.rb
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add test/ledger_test.rb
git commit -m "test: add Ledger unit tests for revision recording and active filtering

Covers record_revision (numbering, finished_at, counter bump),
revisions_for_delivery ordering, and behavioural verification that
active_deliveries returns exactly the states Delivery considers active."
```

---

## Task 4: Add govern reconciliation tests

**Files:**
- Modify: `test/runtime_govern_test.rb`

- [ ] **Step 1: Write test for reconcile — PR MERGED**

Add to `RuntimeGovernTest`:

```ruby
def test_govern_reconciles_merged_pr_as_integrated
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	create_feature_branch( repo_root, "feature/merged" )
	delivery = create_delivery(
		runtime: runtime, repo_root: repo_root,
		branch_name: "feature/merged", status: "queued",
		summary: "awaiting integration"
	)
	runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

	result = runtime.govern!( dry_run: true )
	assert_equal Carson::Runtime::EXIT_OK, result
	row = delivery_row( runtime: runtime, id: delivery.id )
	assert_equal "integrated", row.fetch( "status" )
	refute_nil row.fetch( "integrated_at" )
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 2: Write test for reconcile — PR CLOSED**

```ruby
def test_govern_reconciles_closed_pr_as_failed
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	create_feature_branch( repo_root, "feature/closed" )
	delivery = create_delivery(
		runtime: runtime, repo_root: repo_root,
		branch_name: "feature/closed", status: "queued",
		summary: "awaiting integration"
	)
	runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

	result = runtime.govern!( dry_run: true )
	assert_equal Carson::Runtime::EXIT_OK, result
	row = delivery_row( runtime: runtime, id: delivery.id )
	assert_equal "failed", row.fetch( "status" )
	assert_includes row.fetch( "summary" ), "closed without integration"
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 3: Write test for reconcile — head advanced supersession**

```ruby
def test_govern_reconciles_advanced_head_as_superseded
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	create_feature_branch( repo_root, "feature/advanced" )
	delivery = create_delivery(
		runtime: runtime, repo_root: repo_root,
		branch_name: "feature/advanced", status: "queued",
		summary: "original head"
	)

	# Advance the branch head after creating the delivery
	system( "git", "-C", repo_root, "checkout", "feature/advanced", out: File::NULL, err: File::NULL )
	File.write( File.join( repo_root, "feature.txt" ), "updated content" )
	system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "advance head", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

	result = runtime.govern!( dry_run: true )
	assert_equal Carson::Runtime::EXIT_OK, result
	row = delivery_row( runtime: runtime, id: delivery.id )
	assert_equal "superseded", row.fetch( "status" )
	refute_nil row.fetch( "superseded_at" )
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 4: Write test for revise — no agent provider escalates**

```ruby
def test_govern_escalates_when_no_agent_provider
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	create_feature_branch( repo_root, "feature/no-agent" )
	delivery = create_delivery(
		runtime: runtime, repo_root: repo_root,
		branch_name: "feature/no-agent", status: "gated",
		summary: "CI failing", cause: "ci"
	)
	stub_reconciliation( runtime, delivery: delivery )
	runtime.define_singleton_method( :select_agent_provider ) { nil }

	result = runtime.govern!( dry_run: false )
	assert_equal Carson::Runtime::EXIT_OK, result
	row = delivery_row( runtime: runtime, id: delivery.id )
	assert_equal "escalated", row.fetch( "status" )
	assert_includes row.fetch( "summary" ), "no agent provider"
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 5: Run all govern tests**

```bash
ruby -Ilib -Itest test/runtime_govern_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add test/runtime_govern_test.rb
git commit -m "test: cover reconcile_delivery! state transitions and revise escalation

Tests PR MERGED (integrated), PR CLOSED (failed), head-advanced
(superseded), and no-agent-provider (escalated) paths that were
previously stubbed out entirely."
```

---

## Task 5: Add deliver error path tests at adapter boundary

**Files:**
- Modify: `test/runtime_deliver_test.rb`

The existing deliver tests use a mock `gh` binary (the right approach for gh interactions). For push failure, we stub `git_run` at the adapter boundary — the same layer Carson uses internally — rather than replacing `push_branch!` which would skip the actual error-handling logic in `push_branch!` (lines 147-161) and `force_push_with_lease!` (lines 164-183).

- [ ] **Step 1: Write test for push failure**

Add to `RuntimeDeliverTest`:

```ruby
def test_deliver_reports_push_failure
	runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
	init_git_repo_with_remote( repo_root )
	create_feature_branch( repo_root, "feature/push-fail" )
	stub_ready_assessment( runtime )

	# Stub git_run at the adapter boundary to simulate push rejection
	original_git_run = runtime.method( :git_run )
	runtime.define_singleton_method( :git_run ) do |*args|
		if args.include?( "push" )
			[ "", "fatal: could not push\n", false, 1 ]
		else
			original_git_run.call( *args )
		end
	end

	result = with_env( "PATH" => mock_path ) { runtime.deliver! }
	assert_equal Carson::Runtime::EXIT_ERROR, result
	output = output_string( runtime )
	assert_includes output, "could not push"
	FileUtils.remove_entry( tmp_dir )
end
```

- [ ] **Step 2: Write test for PR creation failure**

```ruby
def test_deliver_reports_pr_creation_failure
	runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh_failing_create
	init_git_repo_with_remote( repo_root )
	create_feature_branch( repo_root, "feature/no-pr" )
	stub_ready_assessment( runtime )

	result = with_env( "PATH" => mock_path ) { runtime.deliver! }
	assert_equal Carson::Runtime::EXIT_ERROR, result
	output = output_string( runtime )
	assert_includes output, "authentication required"
	assert_includes output, "gh pr create"
	FileUtils.remove_entry( tmp_dir )
end
```

- [ ] **Step 3: Add the mock helper for failing PR creation**

Add to the private section of `RuntimeDeliverTest`:

```ruby
def build_runtime_with_mock_gh_failing_create
	tmp_dir = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
	repo_root = File.join( tmp_dir, "repo" )
	FileUtils.mkdir_p( repo_root )

	mock_bin = File.join( tmp_dir, "mock-bin" )
	FileUtils.mkdir_p( mock_bin )
	File.write( File.join( mock_bin, "gh" ), <<~BASH )
		#!/usr/bin/env bash
		if [[ "$1" == "pr" && "$2" == "view" ]]; then
			echo "not found" >&2
			exit 1
		fi
		if [[ "$1" == "pr" && "$2" == "create" ]]; then
			echo "authentication required" >&2
			exit 1
		fi
		if [[ "$1" == "--version" ]]; then
			echo "gh version mock"
			exit 0
		fi
		echo "unsupported: $*" >&2
		exit 1
	BASH
	FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

	output = StringIO.new
	error = StringIO.new
	config_path = write_test_config( repo_root: repo_root )
	runtime = nil
	with_env( "CARSON_CONFIG_FILE" => config_path ) do
		runtime = Carson::Runtime.new(
			repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
			output: output, error: error, verbose: false
		)
	end
	[ runtime, repo_root, "#{mock_bin}:#{ENV.fetch( 'PATH' )}", tmp_dir ]
end
```

- [ ] **Step 4: Run all deliver tests**

```bash
ruby -Ilib -Itest test/runtime_deliver_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add test/runtime_deliver_test.rb
git commit -m "test: cover deliver error paths at adapter boundary

Push failure test stubs git_run to return non-zero exit, exercising
push_branch!'s actual stderr handling and error text extraction.
PR creation failure test uses a mock gh binary that rejects pr create,
exercising create_pr!'s error and recovery message construction."
```

---

## Task 6: Housekeeping (separate commit)

**Files:**
- Modify: `lib/carson/ledger.rb:9,78,286-295`
- Modify: `lib/carson/runtime/govern.rb:84`

- [ ] **Step 1: Deduplicate ACTIVE_STATES constant**

Change line 9 of `lib/carson/ledger.rb` from:

```ruby
ACTIVE_DELIVERY_STATES = %w[preparing gated queued integrating escalated].freeze
```

to:

```ruby
ACTIVE_DELIVERY_STATES = Delivery::ACTIVE_STATES
```

- [ ] **Step 2: Fix indentation — upsert_delivery `if row` block**

Align the `if row` block at line 78 to the same level as the surrounding `with_database` block body.

- [ ] **Step 3: Fix indentation — `supersede_branch!` private method**

Align `supersede_branch!` (lines 286-295) to two tabs from module scope, matching the other private methods.

- [ ] **Step 4: Fix "delivery" pluralisation**

Change line 84 of `lib/carson/runtime/govern.rb` from:

```ruby
puts_line "#{repository.name}: #{deliveries.length} active deliver#{plural_suffix( count: deliveries.length )}"
```

to:

```ruby
puts_line "#{repository.name}: #{deliveries.length} active deliver#{deliveries.length == 1 ? 'y' : 'ies'}"
```

- [ ] **Step 5: Run full test suite**

```bash
ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/carson/ledger.rb lib/carson/runtime/govern.rb
git commit -m "chore: deduplicate active-state constant, fix indentation and pluralisation

Ledger now references Delivery::ACTIVE_STATES instead of maintaining
its own copy. Fixes inconsistent indentation in upsert_delivery and
supersede_branch!. Corrects 'deliver/delivers' to 'delivery/deliveries'
in govern output."
```

---

## Task 7: Run full suite and deliver

- [ ] **Step 1: Run full test suite**

```bash
ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"
```

Expected: all tests pass.

- [ ] **Step 2: Run CI smoke**

```bash
bash script/ci_smoke.sh
```

Expected: passes.

- [ ] **Step 3: Deliver**

```bash
carson deliver
```
