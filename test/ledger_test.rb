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
