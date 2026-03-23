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

	def test_blocks_delivery_when_behind_registry
		dir = setup_repo_with_remote
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )

		# Create a feature branch
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/behind", out: File::NULL, err: File::NULL )

		# Advance main on the remote
		second = File.join( @tmpdir, "second" )
		system( "git", "clone", @remote_path, second, out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.email", "t@t.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "config", "user.name", "T", out: File::NULL, err: File::NULL )
		File.write( File.join( second, "advance.txt" ), "ahead" )
		system( "git", "-C", second, "add", "advance.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "commit", "--no-verify", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", second, "push", "origin", "main", out: File::NULL, err: File::NULL )

		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/behind", head: warehouse.current_head )

		result = courier.deliver( parcel )
		assert_equal Carson::Courier::BLOCKED, result[ :exit ]
		assert_match( /behind/, result[ :error ] )
	end

	# --- Packing ---

	def test_packs_before_shipping_when_commit_message_provided
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/pack", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "dirty.txt" ), "uncommitted" )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		# Parcel created before packing — head will change after pack.
		parcel = Carson::Parcel.new( label: "feature/pack", head: warehouse.current_head )

		courier.deliver( parcel, commit_message: "pack this parcel" )

		# Verify the commit was created.
		log, = Open3.capture3( "git", "-C", @repo_path, "log", "--oneline", "-1" )
		assert_includes log, "pack this parcel"
	end

	def test_packing_fails_with_nothing_to_commit
		setup_repo_with_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/empty-pack", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		courier = Carson::Courier.new( warehouse )
		parcel = Carson::Parcel.new( label: "feature/empty-pack", head: warehouse.current_head )

		result = courier.deliver( parcel, commit_message: "nothing here" )
		assert_equal Carson::Courier::ERROR, result[ :exit ]
		assert_match( /packing failed/, result[ :error ] )
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
