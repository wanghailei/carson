# Tests for Warehouse#prepare! empty parcel guard.
# The warehouse refuses to prepare an empty parcel for delivery.
require_relative "../test_helper"
require_relative "../../lib/carson/parcel"
require "open3"

class WarehousePrepareEmptyTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-warehouse-empty-test", carson_tmp_root )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "initial commit", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.rm_rf( @tmpdir )
	end

	def test_prepare_blocks_empty_parcel
		# Branch at the same commit as main — zero commits ahead.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/empty", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/empty", head: warehouse.current_head )

		result = warehouse.prepare!( parcel )

		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "no commits ahead"
		assert_includes result[ :recovery ], "Commit"
	end

	def test_prepare_allows_parcel_with_commits
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/has-work", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "work.txt" ), "real work" )
		system( "git", "-C", @repo_path, "add", "work.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "real commit", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/has-work", head: warehouse.current_head )

		result = warehouse.prepare!( parcel )

		assert_equal "ok", result[ :status ]
		refute_nil result[ :parcel ]
		assert_equal "feature/has-work", result[ :parcel ].label
	end

	def test_prepare_returns_parcel_with_origin
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/origin-check", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "origin.txt" ), "origin check" )
		system( "git", "-C", @repo_path, "add", "origin.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "origin commit", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/origin-check", head: warehouse.current_head )

		result = warehouse.prepare!( parcel )

		assert_equal "ok", result[ :status ]
		refute_nil result[ :parcel ].origin, "returned parcel should have origin set"
		refute result[ :parcel ].empty?, "parcel with commits should not be empty"
	end
end
