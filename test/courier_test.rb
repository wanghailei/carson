# Tests for Carson::Courier — the delivery person.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../lib/carson/parcel"
require_relative "../lib/carson/warehouse"
require_relative "../lib/carson/waybill"
require_relative "../lib/carson/courier"

class CourierTest < Minitest::Test
	# --- Guards ---

	def test_blocks_delivery_from_main
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "main", head: "abc123" )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /cannot deliver from main/, result[ :error ] )
	end

	def test_blocks_when_dirty_without_commit_message
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/dirty", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "dirty.txt" ), "uncommitted" )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/dirty", head: warehouse.current_head )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /dirty/, result[ :error ] )
	end

	def test_blocks_when_clean_with_commit_message
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/clean-commit", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/clean-commit", head: warehouse.current_head )

		result = courier.deliver( parcel, commit_message: "nothing here" )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /already clean/, result[ :error ] )
	end

	def test_auto_rebases_when_behind_registry
		setup_repo_with_remote
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )

		# Create a feature branch with a commit.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/behind", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "feature.txt" ), "feature work" )
		system( "git", "-C", @repo_path, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "feature commit", out: File::NULL, err: File::NULL )

		# Advance main on the remote (no conflict — different file).
		second = File.join( @tmpdir, "second" )
		system( "git", "clone", @remote_path, second, out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.email", "t@t.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.name", "T", out: File::NULL, err: File::NULL )
		File.write( File.join( second, "advance.txt" ), "ahead" )
		system( "git", "-C", second, "add", "advance.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "commit", "--no-verify", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "push", "origin", "main", out: File::NULL, err: File::NULL )

		output = StringIO.new
		courier = Carson::Courier.new( warehouse, output: output )
		parcel = Carson::Parcel.new( label: "feature/behind", head: warehouse.current_head )

		courier.deliver( parcel )

		# PROOF: courier rebased instead of blocking — the rebase message appeared
		# and the branch now contains the remote advance commit.
		assert_includes output.string, "rebasing"
		log, = Open3.capture3( "git", "-C", @repo_path, "log", "--oneline" )
		assert_includes log, "advance main"
	end

	def test_blocks_on_rebase_conflict
		setup_repo_with_remote
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )

		# Create a feature branch that edits README.md.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/conflict", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Conflict" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "conflict commit", out: File::NULL, err: File::NULL )

		# Advance main on the remote with a conflicting change to the same file.
		second = File.join( @tmpdir, "second" )
		system( "git", "clone", @remote_path, second, out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.email", "t@t.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.name", "T", out: File::NULL, err: File::NULL )
		File.write( File.join( second, "README.md" ), "# Different" )
		system( "git", "-C", second, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "commit", "--no-verify", "-m", "conflicting main", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "push", "origin", "main", out: File::NULL, err: File::NULL )

		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/conflict", head: warehouse.current_head )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /rebase conflict/, result[ :error ] )
	end

	def test_blocks_delivery_when_fetch_fails
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/fetch-fail", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "change.txt" ), "test" )
		system( "git", "-C", @repo_path, "add", "change.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "change", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		# Stub fetch_latest to simulate network failure.
		warehouse.define_singleton_method( :fetch_latest ) { |**| false }

		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/fetch-fail", head: warehouse.current_head )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /fetch failed/, result[ :error ] )
		assert_match( /carson sync/, result[ :recovery ] )
	end

	# --- Packing ---

	def test_packs_before_shipping_when_commit_message_provided
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/pack", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "dirty.txt" ), "uncommitted" )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/pack", head: warehouse.current_head )

		courier.deliver( parcel, commit_message: "pack this parcel" )

		# Verify the commit was created.
		log, = Open3.capture3( "git", "-C", @repo_path, "log", "--oneline", "-1" )
		assert_includes log, "pack this parcel"
	end

	# --- Ledger ---

	def test_records_delivery_when_ledger_provided
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/ledger", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "ledger.txt" ), "track me" )
		system( "git", "-C", @repo_path, "add", "ledger.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "ledger test", out: File::NULL, err: File::NULL )

		recordings = []
		fake_ledger = Object.new
		fake_ledger.define_singleton_method( :upsert_delivery ) do |**kwargs|
			recordings << kwargs
		end

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse, ledger: fake_ledger )
		parcel = Carson::Parcel.new( label: "feature/ledger", head: warehouse.current_head )

		courier.deliver( parcel )

		# At least the initial "preparing" record should exist.
		assert recordings.any? { it[ :status ] == "preparing" }
	end

	def test_ledger_final_record_includes_pr_data
		# Directly exercise the record method with a known waybill to prove
		# pr_number and pr_url reach the ledger.
		recordings = []
		fake_ledger = Object.new
		fake_ledger.define_singleton_method( :upsert_delivery ) do |**kwargs|
			recordings << kwargs
		end

		warehouse = Carson::Warehouse.new( path: "/tmp/fake", bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse, ledger: fake_ledger )
		parcel = Carson::Parcel.new( label: "feature/pr-data", head: "abc123" )

		# A waybill with known PR data (as if filing succeeded).
		waybill = Carson::Waybill.new(
			label: "feature/pr-data",
			warehouse_path: "/tmp/fake",
			tracking_number: 99,
			url: "https://github.com/owner/repo/pull/99"
		)

		# Call record directly — this is what deliver calls after the outcome.
		courier.send( :record, parcel, status: "filed", summary: nil, waybill: waybill )

		assert_equal 1, recordings.length
		record = recordings.first
		assert_equal 99, record[ :pr_number ],
			"pr_number should be the waybill tracking number"
		assert_equal "https://github.com/owner/repo/pull/99", record[ :pr_url ],
			"pr_url should be the waybill URL"
	end

	def test_ledger_preparing_record_has_nil_pr_data
		# The "preparing" record is created before the waybill exists.
		# Verify pr_number and pr_url are nil.
		recordings = []
		fake_ledger = Object.new
		fake_ledger.define_singleton_method( :upsert_delivery ) do |**kwargs|
			recordings << kwargs
		end

		warehouse = Carson::Warehouse.new( path: "/tmp/fake", bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse, ledger: fake_ledger )
		parcel = Carson::Parcel.new( label: "feature/no-waybill", head: "def456" )

		# Call record without a waybill — this is what deliver calls at "preparing".
		courier.send( :record, parcel, status: "preparing", summary: "delivery accepted" )

		assert_equal 1, recordings.length
		record = recordings.first
		assert_nil record[ :pr_number ],
			"preparing record should have nil pr_number (no waybill yet)"
		assert_nil record[ :pr_url ],
			"preparing record should have nil pr_url (no waybill yet)"
	end

	# --- Receive latest standard after acceptance ---

	def test_receives_latest_standard_after_acceptance
		setup_repo_with_remote

		# Create a feature branch and commit.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/sync-proof", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "sync.txt" ), "sync proof" )
		system( "git", "-C", @repo_path, "add", "sync.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "sync proof commit", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/sync-proof", head: warehouse.current_head )

		# Ship the parcel (real git push).
		warehouse.ship( parcel )

		# Simulate: the bureau merges the PR into remote main.
		bare_work = File.join( @tmpdir, "bare-work" )
		system( "git", "clone", @remote_path, bare_work, out: File::NULL, err: File::NULL )
		system( "git", "-C", bare_work, "config", "user.email", "t@t.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", bare_work, "config", "user.name", "T", out: File::NULL, err: File::NULL )
		system( "git", "-C", bare_work, "merge", "origin/feature/sync-proof", "--no-ff", "-m", "merge", out: File::NULL, err: File::NULL )
		system( "git", "-C", bare_work, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Record local main BEFORE receiving latest standard.
		local_main_before, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )

		# Stub a waybill reporting acceptance. Override refresh! to preserve the stub.
		waybill = Carson::Waybill.new( label: "feature/sync-proof", warehouse_path: @repo_path )
		waybill.stub_bureau_response(
			state: { "state" => "MERGED", "mergedAt" => "2026-03-23T00:00:00Z" },
			ci: :pass
		)
		waybill.define_singleton_method( :refresh! ) { self }

		# Call wait_and_poll_at_registry — the courier's poll method.
		result = { command: "deliver", label: "feature/sync-proof" }
		courier.send( :wait_and_poll_at_registry, waybill, result )

		# PROOF: outcome is "delivered" and local main has advanced.
		assert_equal "delivered", result[ :outcome ]
		assert result[ :synced ], "expected receive_latest_standard! to succeed"

		local_main_after, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )
		refute_equal local_main_before.strip, local_main_after.strip,
			"local main should have advanced after receiving latest standard"
	end

	# --- Shipping ---

	def test_ships_parcel_to_bureau
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/ship", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "ship.txt" ), "ship" )
		system( "git", "-C", @repo_path, "add", "ship.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "to ship", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/ship", head: warehouse.current_head )

		# Courier ships but waybill filing will fail (no gh in test) — that's OK for this test.
		# We verify the parcel was shipped by checking the remote.
		courier.deliver( parcel )

		remote_branches, = Open3.capture3( "git", "-C", @remote_path, "branch" )
		assert_includes remote_branches, "feature/ship"
	end

	# --- Wait and poll at registry ---

	def test_delivers_when_registry_clears_on_first_check
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )

		waybill = Carson::Waybill.new( label: "feature/clear", warehouse_path: "/tmp/fake", tracking_number: 1 )
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		# Stub refresh! to preserve the stub state, and accept! to simulate merge.
		waybill.define_singleton_method( :refresh! ) { self }
		waybill.define_singleton_method( :accept! ) do |method:|
			stub_bureau_response( state: { "state" => "MERGED" } )
			self
		end

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "delivered", result[ :outcome ]
	end

	def test_waits_and_delivers_when_registry_clears_after_delay
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )
		# No real sleeping in tests.
		courier.define_singleton_method( :pause_between_polls ) {}

		waybill = Carson::Waybill.new( label: "feature/delayed", warehouse_path: "/tmp/fake", tracking_number: 2 )

		# First two checks: CI pending. Third check: cleared and accepted.
		check_count = 0
		waybill.define_singleton_method( :refresh! ) do
			check_count += 1
			if check_count < 3
				stub_bureau_response(
					state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
					ci: :pending
				)
			else
				stub_bureau_response(
					state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
					ci: :pass
				)
			end
			self
		end
		waybill.define_singleton_method( :accept! ) do |method:|
			stub_bureau_response( state: { "state" => "MERGED" } )
			self
		end

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "delivered", result[ :outcome ]
		assert_equal 3, check_count, "expected 3 checks before delivery"
	end

	def test_holds_immediately_on_ci_failure
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )
		# No real sleeping in tests.
		courier.define_singleton_method( :pause_between_polls ) {}

		waybill = Carson::Waybill.new( label: "feature/ci-fail", warehouse_path: "/tmp/fake", tracking_number: 3 )
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :fail
		)
		waybill.define_singleton_method( :refresh! ) { self }

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "held", result[ :outcome ]
		assert_equal "failed_at_registry", result[ :hold_reason ]
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
	end

	def test_holds_immediately_on_merge_conflict
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )
		courier.define_singleton_method( :pause_between_polls ) {}

		waybill = Carson::Waybill.new( label: "feature/conflict", warehouse_path: "/tmp/fake", tracking_number: 4 )
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" },
			ci: :pass
		)
		waybill.define_singleton_method( :refresh! ) { self }

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "held", result[ :outcome ]
		assert_equal "merge_conflict", result[ :hold_reason ]
	end

	def test_reports_filed_when_checks_exhausted
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )
		courier.define_singleton_method( :pause_between_polls ) {}

		waybill = Carson::Waybill.new( label: "feature/slow-ci", warehouse_path: "/tmp/fake", tracking_number: 5 )
		# CI pending on every check — never clears.
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :pending
		)
		check_count = 0
		waybill.define_singleton_method( :refresh! ) do
			check_count += 1
			self
		end

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "filed", result[ :outcome ]
		assert_equal Carson::Courier::MAX_CHECKS_AT_REGISTRY, check_count
	end

	def test_delivers_when_already_accepted
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse )

		waybill = Carson::Waybill.new( label: "feature/merged", warehouse_path: "/tmp/fake", tracking_number: 6 )
		waybill.stub_bureau_response(
			state: { "state" => "MERGED", "mergedAt" => "2026-03-23T00:00:00Z" },
			ci: :pass
		)
		waybill.define_singleton_method( :refresh! ) { self }

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "delivered", result[ :outcome ]
	end

	# --- Ledger records PR identity from waybill ---

	def test_final_record_includes_pr_number_and_url_from_waybill
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/pr-identity", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "pr.txt" ), "pr identity" )
		system( "git", "-C", @repo_path, "add", "pr.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "pr identity test", out: File::NULL, err: File::NULL )

		recordings = []
		fake_ledger = Object.new
		fake_ledger.define_singleton_method( :upsert_delivery ) do |**kwargs|
			recordings << kwargs
		end

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse, ledger: fake_ledger )
		parcel = Carson::Parcel.new( label: "feature/pr-identity", head: warehouse.current_head )

		# Deliver — waybill filing will fail (no gh in test), so only the
		# preparing record is written. To test the final record path, we
		# call record directly with a waybill that has PR data.
		waybill = Carson::Waybill.new( label: "feature/pr-identity", warehouse_path: @repo_path, tracking_number: 99 )
		waybill.instance_variable_set( :@url, "https://github.com/test/repo/pull/99" )

		courier.send( :record, parcel, status: "filed", summary: "bureau undecided", waybill: waybill )

		final = recordings.last
		assert_equal 99, final[ :pr_number ]
		assert_equal "https://github.com/test/repo/pull/99", final[ :pr_url ]
	end

	def test_initial_record_has_nil_pr_when_no_waybill
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/no-waybill", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "nw.txt" ), "no waybill" )
		system( "git", "-C", @repo_path, "add", "nw.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "no waybill test", out: File::NULL, err: File::NULL )

		recordings = []
		fake_ledger = Object.new
		fake_ledger.define_singleton_method( :upsert_delivery ) do |**kwargs|
			recordings << kwargs
		end

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse, ledger: fake_ledger )
		parcel = Carson::Parcel.new( label: "feature/no-waybill", head: warehouse.current_head )

		courier.send( :record, parcel, status: "preparing", summary: "delivery accepted" )

		initial = recordings.last
		assert_nil initial[ :pr_number ]
		assert_nil initial[ :pr_url ]
	end

	# --- Result includes remote_main ---

	def test_result_includes_remote_main
		warehouse = Carson::Warehouse.new( path: "/tmp/fake", bureau_address: "github", main_label: "main" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "main", head: "abc123" )

		result = courier.deliver( parcel )
		assert_equal "github/main", result[ :remote_main ]
	end

	# --- Progress output ---

	def test_courier_prints_progress_during_poll
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		output = StringIO.new
		courier = Carson::Courier.new( warehouse, output: output )
		courier.define_singleton_method( :pause_between_polls ) {}

		waybill = Carson::Waybill.new( label: "feature/progress", warehouse_path: "/tmp/fake", tracking_number: 10 )
		check_count = 0
		waybill.define_singleton_method( :refresh! ) do
			check_count += 1
			if check_count < 3
				stub_bureau_response(
					state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
					ci: :pending
				)
			else
				stub_bureau_response(
					state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
					ci: :pass
				)
			end
			self
		end
		waybill.define_singleton_method( :accept! ) do |method:|
			stub_bureau_response( state: { "state" => "MERGED" } )
			self
		end

		result = {}
		courier.send( :wait_and_poll_at_registry, waybill, result )

		assert_equal "delivered", result[ :outcome ]
		assert_includes output.string, "(1/6)"
		assert_includes output.string, "(2/6)"
	end

	def test_courier_silent_without_output
		warehouse = Carson::Warehouse.new( path: "/tmp/fake" )
		courier = Carson::Courier.new( warehouse, output: nil )

		waybill = Carson::Waybill.new( label: "feature/silent", warehouse_path: "/tmp/fake", tracking_number: 11 )
		waybill.stub_bureau_response(
			state: { "state" => "MERGED" },
			ci: :pass
		)
		waybill.define_singleton_method( :refresh! ) { self }

		result = {}
		# Should not raise — nil output is safe.
		courier.send( :wait_and_poll_at_registry, waybill, result )
		assert_equal "delivered", result[ :outcome ]
	end

private

	def setup_repo_with_remote
		@tmpdir = Dir.mktmpdir( "courier-test" )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "t@t.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "T", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "--no-verify", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.rm_rf( @tmpdir ) if @tmpdir
	end
end
