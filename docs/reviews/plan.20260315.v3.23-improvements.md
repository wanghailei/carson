# Carson v3.23 Post-Review Improvements

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 3 confirmed bugs and add test coverage for 4 critical gaps identified in the v3.23.0+v3.23.1 code review.

**Architecture:** All fixes are surgical — no structural changes. Bug fixes are one-line corrections. Test coverage additions follow the existing Minitest + CarsonTestSupport pattern with isolated git repos and mock gh binaries.

**Tech Stack:** Ruby, Minitest, SQLite3, Open3, git CLI

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/carson/runtime/local/onboard.rb` | Modify line 298 | Fix `e` -> `exception` NameError |
| `lib/carson/ledger.rb` | Modify line 9 | Reference `Delivery::ACTIVE_STATES` instead of duplicate constant |
| `lib/carson/ledger.rb` | Modify lines 286-295 | Fix indentation of `supersede_branch!` |
| `lib/carson/runtime/deliver.rb` | Modify line 317 | Fix `Process::Status` truthiness bug |
| `lib/carson/runtime/govern.rb` | Modify line 84 | Fix "deliver" -> "delivery" pluralisation |
| `test/ledger_test.rb` | Create | Unit tests for `record_revision` and `revisions_for_delivery` |
| `test/runtime_govern_test.rb` | Modify | Add reconciliation and revision tests |
| `test/runtime_deliver_test.rb` | Modify | Add error path tests |

---

## Task 1: Fix onboard rescue NameError

**Files:**
- Modify: `lib/carson/runtime/local/onboard.rb:298`

- [ ] **Step 1: Write the failing test**

No dedicated onboard test file exists and onboard requires complex setup (full `carson setup` flow). This is a one-character fix with clear visual proof. Skip TDD — fix directly and verify by inspection.

- [ ] **Step 2: Fix the bug**

Change line 298 from `audit_error = e` to `audit_error = exception`:

```ruby
# Before:
rescue StandardError => exception
	audit_error = e

# After:
rescue StandardError => exception
	audit_error = exception
```

- [ ] **Step 3: Verify by reading the fixed code**

Read `lib/carson/runtime/local/onboard.rb:294-302` and confirm the rescue variable name matches.

- [ ] **Step 4: Commit**

```bash
git add lib/carson/runtime/local/onboard.rb
git commit -m "fix: rescue variable NameError in onboard_run_audit!

audit_error = e referenced undefined variable; should be exception.
When audit! raised during onboard, the NameError was silently swallowed
by the ensure block, giving the user no diagnostic."
```

---

## Task 2: Deduplicate ACTIVE_STATES constant

**Files:**
- Modify: `lib/carson/ledger.rb:9`

- [ ] **Step 1: Write the failing test**

```ruby
# In test/ledger_test.rb (new file — created in Task 5)
def test_active_delivery_states_matches_delivery_constant
	assert_equal Carson::Delivery::ACTIVE_STATES, Carson::Ledger::ACTIVE_DELIVERY_STATES,
		"Ledger and Delivery active-state definitions must agree"
end
```

- [ ] **Step 2: Run test to verify it passes (baseline)**

```bash
ruby -Ilib -Itest test/ledger_test.rb --name test_active_delivery_states_matches_delivery_constant
```

Expected: PASS (they currently match by coincidence).

- [ ] **Step 3: Replace the duplicate constant with a reference**

Change line 9 of `lib/carson/ledger.rb` from:

```ruby
ACTIVE_DELIVERY_STATES = %w[preparing gated queued integrating escalated].freeze
```

to:

```ruby
ACTIVE_DELIVERY_STATES = Delivery::ACTIVE_STATES
```

- [ ] **Step 4: Verify the test still passes**

```bash
ruby -Ilib -Itest test/ledger_test.rb --name test_active_delivery_states_matches_delivery_constant
```

Expected: PASS.

- [ ] **Step 5: Run full test suite to confirm no regressions**

```bash
ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/carson/ledger.rb
git commit -m "fix: deduplicate ACTIVE_STATES between Delivery and Ledger

Ledger now references Delivery::ACTIVE_STATES instead of maintaining
its own copy. Prevents silent divergence if the state list changes."
```

---

## Task 3: Fix Process::Status truthiness in sync_after_merge!

**Files:**
- Modify: `lib/carson/runtime/deliver.rb:317`

- [ ] **Step 1: Fix the bug**

Change line 317 from `if pull_success` to `if pull_success.success?`:

```ruby
# Before:
_, pull_stderr, pull_success, = Open3.capture3(
	"git", "-C", main_root, "pull", "--ff-only", remote, main
)
if pull_success

# After:
_, pull_stderr, pull_status, = Open3.capture3(
	"git", "-C", main_root, "pull", "--ff-only", remote, main
)
if pull_status.success?
```

Also rename the variable from `pull_success` to `pull_status` to match the convention used elsewhere in the codebase (e.g. `worktree.rb:87`).

- [ ] **Step 2: Verify by reading**

Read `lib/carson/runtime/deliver.rb:312-325` and confirm `.success?` is called on the status object.

- [ ] **Step 3: Commit**

```bash
git add lib/carson/runtime/deliver.rb
git commit -m "fix: check Process::Status with .success? in sync_after_merge!

Open3.capture3 returns a Process::Status object which is always truthy.
The condition never took the false branch. Currently dead code but
prevents a trap for future callers."
```

---

## Task 4: Fix "deliver" pluralisation in govern output

**Files:**
- Modify: `lib/carson/runtime/govern.rb:84`

- [ ] **Step 1: Fix the wording**

Change line 84 from:

```ruby
puts_line "#{repository.name}: #{deliveries.length} active deliver#{plural_suffix( count: deliveries.length )}"
```

to:

```ruby
puts_line "#{repository.name}: #{deliveries.length} active deliver#{deliveries.length == 1 ? 'y' : 'ies'}"
```

- [ ] **Step 2: Commit**

```bash
git add lib/carson/runtime/govern.rb
git commit -m "fix: correct pluralisation of 'delivery' in govern output"
```

---

## Task 5: Fix Ledger indentation and add Ledger unit tests

**Files:**
- Modify: `lib/carson/ledger.rb:78,286-295`
- Create: `test/ledger_test.rb`

- [ ] **Step 1: Fix indentation — upsert_delivery `if row` block**

Align the `if row` block at line 78 to the same level as the surrounding `with_database` block body (two tabs from module scope, matching the `INSERT` block below it).

- [ ] **Step 2: Fix indentation — `supersede_branch!` private method**

Align `supersede_branch!` (lines 286-295) to two tabs from module scope, matching the other private methods (`build_delivery`, `build_revision`, `active_state_placeholders`, `now_utc`).

- [ ] **Step 3: Write the test file skeleton**

Create `test/ledger_test.rb`:

```ruby
require_relative "test_helper"
require "tmpdir"
require "fileutils"

class LedgerTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-ledger-test", carson_tmp_root )
		@ledger = Carson::Ledger.new( path: File.join( @tmp_dir, "test-ledger.sqlite3" ) )
		@repository = Carson::Repository.new( path: @tmp_dir, authority: "remote", runtime: nil )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if File.directory?( @tmp_dir )
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

- [ ] **Step 4: Write test for `record_revision` — first revision**

```ruby
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
```

- [ ] **Step 5: Run to verify it passes**

```bash
ruby -Ilib -Itest test/ledger_test.rb --name test_record_revision_creates_first_revision_with_number_one
```

Expected: PASS.

- [ ] **Step 6: Write test for sequential revision numbering**

```ruby
def test_record_revision_increments_number_sequentially
	delivery = create_test_delivery
	r1 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "attempt 1" )
	r2 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "attempt 2" )
	r3 = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "attempt 3" )
	assert_equal 1, r1.number
	assert_equal 2, r2.number
	assert_equal 3, r3.number
end
```

- [ ] **Step 7: Write test for `finished_at` only on terminal statuses**

```ruby
def test_record_revision_sets_finished_at_for_terminal_statuses
	delivery = create_test_delivery
	running = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "running", summary: "in progress" )
	assert_nil running.finished_at

	failed = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "broke" )
	refute_nil failed.finished_at

	stalled = @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "stalled", summary: "timeout" )
	refute_nil stalled.finished_at
end
```

- [ ] **Step 8: Write test for revision_count bump on delivery**

```ruby
def test_record_revision_bumps_delivery_revision_count
	delivery = create_test_delivery
	@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "done" )
	updated = @ledger.active_delivery( repo_path: @tmp_dir, branch_name: "feature/test" )
	assert_equal 1, updated.revision_count
end
```

- [ ] **Step 9: Write test for `revisions_for_delivery` ordering**

```ruby
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
```

- [ ] **Step 10: Write test for constant agreement**

```ruby
def test_active_delivery_states_matches_delivery_constant
	assert_equal Carson::Delivery::ACTIVE_STATES, Carson::Ledger::ACTIVE_DELIVERY_STATES,
		"Ledger and Delivery active-state definitions must agree"
end
```

- [ ] **Step 11: Run all ledger tests**

```bash
ruby -Ilib -Itest test/ledger_test.rb
```

Expected: all pass.

- [ ] **Step 12: Commit**

```bash
git add lib/carson/ledger.rb test/ledger_test.rb
git commit -m "test: add Ledger unit tests for revision recording and retrieval

Covers record_revision (numbering, finished_at, counter bump),
revisions_for_delivery ordering, and constant agreement with Delivery.
Also fixes inconsistent indentation in upsert_delivery and
supersede_branch!."
```

---

## Task 6: Add govern reconciliation and revision tests

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

- [ ] **Step 2: Run test**

```bash
ruby -Ilib -Itest test/runtime_govern_test.rb --name test_govern_reconciles_merged_pr_as_integrated
```

Expected: PASS.

- [ ] **Step 3: Write test for reconcile — PR CLOSED**

```ruby
def test_govern_reconciles_closed_pr_as_failed
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	create_feature_branch( repo_root, "feature/closed" )
	create_delivery(
		runtime: runtime, repo_root: repo_root,
		branch_name: "feature/closed", status: "queued",
		summary: "awaiting integration"
	)
	runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

	result = runtime.govern!( dry_run: true )
	assert_equal Carson::Runtime::EXIT_OK, result
	row = delivery_row( runtime: runtime, id: 1 )
	assert_equal "failed", row.fetch( "status" )
	assert_includes row.fetch( "summary" ), "closed without integration"
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 4: Write test for reconcile — head advanced supersession**

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

- [ ] **Step 5: Write test for revise — no agent provider escalates**

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

- [ ] **Step 6: Run all govern tests**

```bash
ruby -Ilib -Itest test/runtime_govern_test.rb
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add test/runtime_govern_test.rb
git commit -m "test: cover reconcile_delivery! state transitions and revise escalation

Tests PR MERGED (integrated), PR CLOSED (failed), head-advanced
(superseded), and no-agent-provider (escalated) paths that were
previously stubbed out entirely."
```

---

## Task 7: Add deliver error path tests

**Files:**
- Modify: `test/runtime_deliver_test.rb`

- [ ] **Step 1: Write test for push failure**

Add to `RuntimeDeliverTest`:

```ruby
def test_deliver_reports_push_failure
	runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
	init_git_repo_with_remote( repo_root )
	create_feature_branch( repo_root, "feature/push-fail" )
	stub_ready_assessment( runtime )

	# Stub push to fail by making remote unreachable
	runtime.define_singleton_method( :push_branch! ) do |remote:, branch:, result:|
		result[ :error ] = "failed to push"
		result[ :recovery ] = "git fetch #{remote} #{branch} && carson deliver"
		Carson::Runtime::EXIT_ERROR
	end

	result = with_env( "PATH" => mock_path ) { runtime.deliver! }
	assert_equal Carson::Runtime::EXIT_ERROR, result
	output = output_string( runtime )
	assert_includes output, "failed to push"
	FileUtils.remove_entry( tmp_dir )
end
```

- [ ] **Step 2: Write test for PR creation failure**

```ruby
def test_deliver_reports_pr_creation_failure
	tmp_dir = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
	repo_root = File.join( tmp_dir, "repo" )
	FileUtils.mkdir_p( repo_root )

	mock_bin = File.join( tmp_dir, "mock-bin" )
	FileUtils.mkdir_p( mock_bin )
	# gh pr view fails (no existing PR) and gh pr create also fails
	File.write( File.join( mock_bin, "gh" ), <<~BASH )
		#!/usr/bin/env bash
		if [[ "$1" == "pr" && "$2" == "view" ]]; then
			echo "not found" >&2
			exit 1
		fi
		if [[ "$1" == "pr" && "$2" == "create" ]]; then
			echo "error creating PR" >&2
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

	init_git_repo_with_remote( repo_root )
	create_feature_branch( repo_root, "feature/no-pr" )
	stub_ready_assessment( runtime )

	result = with_env( "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) { runtime.deliver! }
	assert_equal Carson::Runtime::EXIT_ERROR, result
	FileUtils.remove_entry( tmp_dir )
end
```

- [ ] **Step 3: Run all deliver tests**

```bash
ruby -Ilib -Itest test/runtime_deliver_test.rb
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add test/runtime_deliver_test.rb
git commit -m "test: cover deliver error paths for push and PR creation failure

Verifies that push failure sets error/recovery in result and that
PR creation failure returns EXIT_ERROR."
```

---

## Task 8: Run full suite and deliver

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
