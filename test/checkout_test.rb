# Tests for Warehouse#checkout! — agent checks out, warehouse releases the workbench.
require_relative "test_helper"
require "open3"

class CheckoutTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-checkout-test", carson_tmp_root )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		# Create a bare remote and clone it.
		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "initial commit", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		@warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
	end

	def teardown
		# Clean up any seal markers created during tests.
		@seal_markers_to_clean&.each do |marker|
			File.delete( marker ) if File.exist?( marker )
		end

		if Dir.exist?( @repo_path )
			stdout, = Open3.capture3( "git", "-C", @repo_path, "worktree", "list", "--porcelain" )
			stdout.lines.each do |line|
				next unless line.start_with?( "worktree " )
				wt_path = line.sub( "worktree ", "" ).strip
				next if wt_path == @repo_path
				Open3.capture3( "git", "-C", @repo_path, "worktree", "remove", "--force", wt_path ) rescue nil
			end
		end
		FileUtils.rm_rf( @tmpdir )
	end

	# --- checkout! ---

	def test_checkout_removes_clean_workbench
		@warehouse.build_workbench!( name: "clean-bench" )
		workbench = @warehouse.workbench_named( "clean-bench" )

		result = @warehouse.checkout!( workbench )

		assert_equal "ok", result[ :status ]
		refute Dir.exist?( workbench.path ), "directory should be removed"
	end

	def test_checkout_result_command_is_checkout
		@warehouse.build_workbench!( name: "cmd-bench" )
		workbench = @warehouse.workbench_named( "cmd-bench" )

		result = @warehouse.checkout!( workbench )

		assert_equal "checkout", result[ :command ]
	end

	def test_checkout_deletes_local_branch
		@warehouse.build_workbench!( name: "branch-bench" )
		workbench = @warehouse.workbench_named( "branch-bench" )

		@warehouse.checkout!( workbench )

		_, _, branch_ok = Open3.capture3( "git", "-C", @repo_path,
			"show-ref", "--verify", "--quiet", "refs/heads/branch-bench" )
		refute branch_ok.success?, "local branch should be deleted"
	end

	def test_checkout_blocks_on_sealed_workbench
		@warehouse.build_workbench!( name: "sealed-bench" )
		workbench = @warehouse.workbench_named( "sealed-bench" )

		# Seal the workbench — parcel is in flight.
		seal_warehouse = Carson::Warehouse.new( path: workbench.path )
		seal_warehouse.seal!( tracking: 42 )
		track_seal_marker( seal_warehouse )

		result = @warehouse.checkout!( workbench )

		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "sealed"
		assert_includes result[ :error ], "42"
	end

	def test_checkout_force_overrides_seal
		@warehouse.build_workbench!( name: "force-seal" )
		workbench = @warehouse.workbench_named( "force-seal" )

		seal_warehouse = Carson::Warehouse.new( path: workbench.path )
		seal_warehouse.seal!( tracking: 99 )
		track_seal_marker( seal_warehouse )

		result = @warehouse.checkout!( workbench, force: true )

		assert_equal "ok", result[ :status ]
		refute Dir.exist?( workbench.path ), "directory should be removed"
	end

	def test_checkout_blocks_on_dirty_workbench
		@warehouse.build_workbench!( name: "dirty-bench" )
		workbench = @warehouse.workbench_named( "dirty-bench" )
		File.write( File.join( workbench.path, "dirty.txt" ), "dirty" )

		result = @warehouse.checkout!( workbench )

		assert_equal "error", result[ :status ]
		assert_includes result[ :error ].to_s.downcase, "uncommitted"
	end

private

	# Track seal markers so teardown can clean them up.
	def track_seal_marker( seal_warehouse )
		@seal_markers_to_clean ||= []
		@seal_markers_to_clean << seal_warehouse.send( :delivering_marker_path )
	end
end
