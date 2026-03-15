require_relative "test_helper"
require "tmpdir"
require "fileutils"

class LedgerTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-ledger-test", carson_tmp_root )
		@ledger = Carson::Ledger.new( path: File.join( @tmp_dir, "test-ledger.sqlite3" ) )
		@repository = Carson::Repository.new( path: @tmp_dir, runtime: nil )
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

	def test_active_deliveries_reads_existing_database_without_wal_write_access
		create_test_delivery( branch_name: "feature/readonly", head: "readonly-head", status: "queued" )
		state_path = @ledger.path
		FileUtils.rm_f( [ "#{state_path}-wal", "#{state_path}-shm" ] )
		File.chmod( 0o444, state_path )
		File.chmod( 0o555, @tmp_dir )

		readonly_ledger = Carson::Ledger.new( path: state_path )
		deliveries = readonly_ledger.active_deliveries( repo_path: @tmp_dir )
		assert_equal [ "feature/readonly" ], deliveries.map( &:branch )
	ensure
		File.chmod( 0o755, @tmp_dir ) if Dir.exist?( @tmp_dir )
		File.chmod( 0o644, state_path ) if state_path && File.exist?( state_path )
	end

	def test_active_deliveries_include_legacy_worktree_repo_path_rows_for_canonical_root
		with_feature_worktree_runtimes(
			branch_name: "codex/legacy-ledger-query",
			worktree_name: "legacy-ledger-query"
		) do |root_runtime, worktree_runtime, repo_root, worktree_path|
			legacy_repository = Carson::Repository.new( path: worktree_path, runtime: nil )
			worktree_runtime.ledger.upsert_delivery(
				repository: legacy_repository,
				branch_name: "codex/legacy-ledger-query",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 77,
				pr_url: "https://github.com/test/repo/pull/77",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)

			deliveries = root_runtime.ledger.active_deliveries( repo_path: repo_root )
			assert_equal [ "codex/legacy-ledger-query" ], deliveries.map( &:branch )
		end
	end

	def test_upsert_delivery_rekeys_legacy_worktree_repo_path_rows_to_canonical_root
		with_feature_worktree_runtimes(
			branch_name: "codex/legacy-ledger-upsert",
			worktree_name: "legacy-ledger-upsert"
		) do |root_runtime, worktree_runtime, repo_root, worktree_path|
			canonical_repo_path = root_runtime.send( :repository_record ).path
			legacy_repository = Carson::Repository.new( path: worktree_path, runtime: nil )
			worktree_runtime.ledger.upsert_delivery(
				repository: legacy_repository,
				branch_name: "codex/legacy-ledger-upsert",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 78,
				pr_url: "https://github.com/test/repo/pull/78",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)

			canonical_delivery = root_runtime.ledger.upsert_delivery(
				repository: root_runtime.send( :repository_record ),
				branch_name: "codex/legacy-ledger-upsert",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 79,
				pr_url: "https://github.com/test/repo/pull/79",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)

			rows = root_runtime.ledger.send( :with_database ) do |database|
				database.execute(
					"SELECT repo_path, pr_number FROM deliveries WHERE branch_name = ? ORDER BY id ASC",
					[ "codex/legacy-ledger-upsert" ]
				)
			end
			assert_equal 1, rows.length
			assert_equal canonical_repo_path, rows.first.fetch( "repo_path" )
			assert_equal 79, rows.first.fetch( "pr_number" )
			assert_equal canonical_repo_path, canonical_delivery.repository.path
		end
	end

	# --- integrated_deliveries ---

	def test_integrated_deliveries_returns_integrated_with_worktree_path
		delivery = create_test_delivery( branch_name: "feature/int", head: "int1", status: "queued" )
		@ledger.update_delivery( delivery: delivery, status: "integrated", worktree_path: "/tmp/wt" )

		results = @ledger.integrated_deliveries( repo_path: @tmp_dir )
		assert_equal 1, results.length
		assert_equal "feature/int", results.first.branch
		assert_equal "integrated", results.first.status
	end

	def test_integrated_deliveries_excludes_failed_and_superseded
		d1 = create_test_delivery( branch_name: "feature/fail", head: "fail1", status: "queued" )
		@ledger.update_delivery( delivery: d1, status: "failed", worktree_path: "/tmp/wt1" )

		d2 = create_test_delivery( branch_name: "feature/sup", head: "sup1", status: "queued" )
		@ledger.update_delivery( delivery: d2, status: "superseded", worktree_path: "/tmp/wt2" )

		results = @ledger.integrated_deliveries( repo_path: @tmp_dir )
		assert_empty results
	end

	def test_integrated_deliveries_excludes_nil_worktree_path
		delivery = create_test_delivery( branch_name: "feature/no-wt", head: "nw1", status: "queued" )
		@ledger.update_delivery( delivery: delivery, status: "integrated", worktree_path: nil )

		results = @ledger.integrated_deliveries( repo_path: @tmp_dir )
		assert_empty results
	end

	def test_integrated_deliveries_matches_worktree_repo_path
		# Simulate a delivery created from within a worktree (legacy repo_path).
		worktree_repo_path = "#{@tmp_dir}/.claude/worktrees/my-feature"
		worktree_repo = Carson::Repository.new( path: worktree_repo_path, authority: "remote", runtime: nil )
		delivery = @ledger.upsert_delivery(
			repository: worktree_repo,
			branch_name: "feature/wt-path",
			head: "wtp1",
			worktree_path: worktree_repo_path,
			authority: "remote",
			pr_number: 2,
			pr_url: "https://github.com/test/repo/pull/2",
			status: "integrated",
			summary: "test",
			cause: nil
		)

		# Query using the main repo root — should still find the delivery.
		results = @ledger.integrated_deliveries( repo_path: @tmp_dir )
		assert_equal 1, results.length
		assert_equal "feature/wt-path", results.first.branch
	end

private

	def create_test_delivery( branch_name: "feature/test", head: "abc123", status: "queued" )
		@ledger.upsert_delivery(
			repository: @repository,
			branch_name: branch_name,
			head: head,
			worktree_path: @tmp_dir,
			pr_number: 1,
			pr_url: "https://github.com/test/repo/pull/1",
			status: status,
			summary: "test delivery",
			cause: nil
		)
	end
end
