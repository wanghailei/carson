require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "sqlite3"

class LedgerTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-ledger-test", carson_tmp_root )
		@ledger = Carson::Ledger.new( path: File.join( @tmp_dir, "test-ledger.json" ) )
		@repository = Carson::Repository.new( path: @tmp_dir, runtime: nil )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if File.directory?( @tmp_dir )
	end

	# --- bootstrap ---

	def test_missing_json_file_bootstraps_as_empty
		path = File.join( @tmp_dir, "nonexistent.json" )
		ledger = Carson::Ledger.new( path: path )
		assert_equal [], ledger.active_deliveries( repo_path: @tmp_dir )
	end

	def test_malformed_json_raises_actionable_error
		path = File.join( @tmp_dir, "bad.json" )
		File.write( path, "{invalid-json" )
		ledger = Carson::Ledger.new( path: path )
		error = assert_raises( RuntimeError ) { ledger.active_deliveries( repo_path: @tmp_dir ) }
		assert_includes error.message, path
	end

	def test_json_path_migrates_legacy_sqlite_sibling
		sqlite_path = File.join( @tmp_dir, "state.sqlite3" )
		write_legacy_sqlite_ledger( path: sqlite_path, repo_path: @tmp_dir, branch_name: "feature/legacy-sibling", delivery_id: 7 )

		ledger = Carson::Ledger.new( path: File.join( @tmp_dir, "state.json" ) )
		deliveries = ledger.active_deliveries( repo_path: @tmp_dir )

		assert_equal [ "feature/legacy-sibling" ], deliveries.map( &:branch )
		assert File.exist?( ledger.path )
		refute_equal Carson::Ledger::SQLITE_HEADER, File.binread( ledger.path, Carson::Ledger::SQLITE_HEADER.bytesize )
	end

	def test_sqlite_path_migrates_in_place_when_config_still_points_to_legacy_location
		sqlite_path = File.join( @tmp_dir, "state.sqlite3" )
		write_legacy_sqlite_ledger( path: sqlite_path, repo_path: @tmp_dir, branch_name: "feature/legacy-config", delivery_id: 9 )

		ledger = Carson::Ledger.new( path: sqlite_path )
		deliveries = ledger.active_deliveries( repo_path: @tmp_dir )

		assert_equal [ "feature/legacy-config" ], deliveries.map( &:branch )
		refute_equal Carson::Ledger::SQLITE_HEADER, File.binread( sqlite_path, Carson::Ledger::SQLITE_HEADER.bytesize )
	end

	# --- upsert_delivery ---

	def test_idempotent_upsert_for_same_identity
		d1 = create_test_delivery
		d2 = create_test_delivery
		assert_equal d1.key, d2.key
		assert_equal 1, @ledger.active_deliveries( repo_path: @tmp_dir ).length
	end

	def test_supersedes_older_active_deliveries_on_new_head
		old = create_test_delivery( head: "old-head" )
		assert old.active?
		_new = create_test_delivery( head: "new-head" )
		deliveries = @ledger.active_deliveries( repo_path: @tmp_dir )
		assert_equal 1, deliveries.length
		assert_equal "new-head", deliveries.first.head
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

	def test_escalation_after_three_recorded_revisions
		delivery = create_test_delivery( status: "gated" )
		3.times { |i| @ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "attempt #{i + 1}" ) }
		updated = @ledger.active_delivery( repo_path: @tmp_dir, branch_name: "feature/test" )
		assert_equal 3, updated.revision_count
	end

	# --- revisions_for_delivery ---

	def test_revisions_for_delivery_returns_in_ascending_order
		delivery = create_test_delivery
		@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "failed", summary: "first" )
		@ledger.record_revision( delivery: delivery, cause: "ci", provider: "codex", status: "completed", summary: "second" )

		updated = @ledger.active_delivery( repo_path: @tmp_dir, branch_name: "feature/test" )
		revisions = @ledger.revisions_for_delivery( delivery: updated )
		assert_equal 2, revisions.length
		assert_equal 1, revisions.first.number
		assert_equal 2, revisions.last.number
		assert_equal "first", revisions.first.summary
		assert_equal "second", revisions.last.summary
	end

	# --- active_deliveries filtering ---

	def test_active_deliveries_returns_only_active_state_deliveries
		create_test_delivery( branch_name: "feature/active", head: "aaa", status: "queued" )
		create_test_delivery( branch_name: "feature/gated", head: "bbb", status: "gated" )
		terminal = create_test_delivery( branch_name: "feature/done", head: "ccc", status: "queued" )
		@ledger.update_delivery( delivery: terminal, status: "integrated" )

		actives = @ledger.active_deliveries( repo_path: @tmp_dir )
		active_branches = actives.map( &:branch ).sort
		assert_includes active_branches, "feature/active"
		assert_includes active_branches, "feature/gated"
		refute_includes active_branches, "feature/done"
	end

	def test_active_deliveries_uses_same_states_as_delivery_model
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
		) do |root_runtime, worktree_runtime, _repo_root, worktree_path|
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

			state = JSON.parse( File.read( root_runtime.ledger.path ) )
			rows = state.fetch( "deliveries" ).values.select { |data| data[ "branch_name" ] == "codex/legacy-ledger-upsert" }
			assert_equal 1, rows.length
			assert_equal canonical_repo_path, rows.first.fetch( "repo_path" )
			assert_equal 79, rows.first.fetch( "pr_number" )
			assert_equal canonical_repo_path, canonical_delivery.repo_path
		end
	end

	def test_active_deliveries_preserve_fifo_when_created_at_matches
		now = "2026-03-16T00:00:00Z"
		state = {
			"next_sequence" => 3,
			"deliveries" => {
				"#{@tmp_dir}:feature/b:head-b" => {
					"sequence" => 1,
					"repo_path" => @tmp_dir,
					"branch_name" => "feature/b",
					"head" => "head-b",
					"worktree_path" => @tmp_dir,
					"status" => "queued",
					"pr_number" => 1,
					"pr_url" => "https://github.com/test/repo/pull/1",
					"cause" => nil,
					"summary" => "first",
					"created_at" => now,
					"updated_at" => now,
					"integrated_at" => nil,
					"superseded_at" => nil,
					"revisions" => []
				},
				"#{@tmp_dir}:feature/a:head-a" => {
					"sequence" => 2,
					"repo_path" => @tmp_dir,
					"branch_name" => "feature/a",
					"head" => "head-a",
					"worktree_path" => @tmp_dir,
					"status" => "queued",
					"pr_number" => 2,
					"pr_url" => "https://github.com/test/repo/pull/2",
					"cause" => nil,
					"summary" => "second",
					"created_at" => now,
					"updated_at" => now,
					"integrated_at" => nil,
					"superseded_at" => nil,
					"revisions" => []
				}
			}
		}
		File.write( @ledger.path, JSON.pretty_generate( state ) + "\n" )

		deliveries = @ledger.active_deliveries( repo_path: @tmp_dir )
		assert_equal [ "feature/b", "feature/a" ], deliveries.map( &:branch )
	end

	def test_integrated_deliveries_returns_only_integrated_with_worktree_path
		integrated = create_test_delivery( branch_name: "feature/integrated", head: "int1", status: "queued" )
		@ledger.update_delivery(
			delivery: integrated,
			status: "integrated",
			worktree_path: File.join( @tmp_dir, ".claude", "worktrees", "integrated" )
		)

		failed = create_test_delivery( branch_name: "feature/failed", head: "fail1", status: "queued" )
		@ledger.update_delivery(
			delivery: failed,
			status: "failed",
			worktree_path: File.join( @tmp_dir, ".claude", "worktrees", "failed" )
		)

		missing_path = create_test_delivery( branch_name: "feature/no-worktree", head: "nw1", status: "queued" )
		@ledger.update_delivery(
			delivery: missing_path,
			status: "integrated",
			worktree_path: nil
		)

		results = @ledger.integrated_deliveries( repo_path: @tmp_dir )
		assert_equal [ "feature/integrated" ], results.map( &:branch )
		assert_equal "integrated", results.first.status
	end

	def test_integrated_deliveries_include_legacy_worktree_repo_path_rows_for_canonical_root
		with_feature_worktree_runtimes(
			branch_name: "codex/legacy-integrated-query",
			worktree_name: "legacy-integrated-query"
		) do |root_runtime, worktree_runtime, repo_root, worktree_path|
			legacy_repository = Carson::Repository.new( path: worktree_path, runtime: nil )
			delivery = worktree_runtime.ledger.upsert_delivery(
				repository: legacy_repository,
				branch_name: "codex/legacy-integrated-query",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 78,
				pr_url: "https://github.com/test/repo/pull/78",
				status: "integrated",
				summary: "integrated into main",
				cause: nil
			)

			deliveries = root_runtime.ledger.integrated_deliveries( repo_path: repo_root )
			assert_equal [ delivery.branch ], deliveries.map( &:branch )
		end
	end

private

	def write_legacy_sqlite_ledger( path:, repo_path:, branch_name:, delivery_id: )
		database = SQLite3::Database.new( path )
		database.execute_batch( <<~SQL )
			CREATE TABLE deliveries (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				repo_path TEXT NOT NULL,
				branch_name TEXT NOT NULL,
				head TEXT NOT NULL,
				worktree_path TEXT,
				status TEXT NOT NULL,
				pr_number INTEGER,
				pr_url TEXT,
				revision_count INTEGER NOT NULL DEFAULT 0,
				cause TEXT,
				summary TEXT,
				created_at TEXT NOT NULL,
				updated_at TEXT NOT NULL,
				integrated_at TEXT,
				superseded_at TEXT
			);

			CREATE TABLE revisions (
				id INTEGER PRIMARY KEY AUTOINCREMENT,
				delivery_id INTEGER NOT NULL,
				number INTEGER NOT NULL,
				cause TEXT NOT NULL,
				provider TEXT NOT NULL,
				status TEXT NOT NULL,
				started_at TEXT NOT NULL,
				finished_at TEXT,
				summary TEXT
			);
		SQL
		timestamp = "2026-03-16T00:00:00Z"
		database.execute(
			<<~SQL,
				INSERT INTO deliveries (
					id, repo_path, branch_name, head, worktree_path, status,
					pr_number, pr_url, revision_count, cause, summary, created_at, updated_at
				) VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )
			SQL
			[
				delivery_id, repo_path, branch_name, "head-#{delivery_id}", repo_path, "queued",
				delivery_id, "https://github.com/test/repo/pull/#{delivery_id}", 0, nil, "legacy delivery",
				timestamp, timestamp
			]
		)
	ensure
		database&.close
	end

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
