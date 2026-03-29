# Tests for Carson::Warehouse::Workbench — the warehouse's workbench concern.
# The warehouse builds, tears down, sweeps, and inventories workbenches.
# Workbenches are passive objects — the warehouse acts on them.
require_relative "test_helper"
require "open3"

class WarehouseWorkbenchTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-warehouse-workbench-test", carson_tmp_root )
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
		# Clean up worktrees before removing the temp directory.
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

	# --- Inventory: workbenches ---

	def test_workbenches_returns_worktree_instances
		workbenches = @warehouse.workbenches
		assert_kind_of Array, workbenches
		assert workbenches.all? { |wb| wb.is_a?( Carson::Worktree ) }
	end

	def test_workbenches_includes_main_worktree
		workbenches = @warehouse.workbenches
		paths = workbenches.map( &:path )
		assert paths.any? { |p| p.include?( "repo" ) }, "should include the main worktree"
	end

	def test_workbenches_includes_created_worktree
		worktree_path = File.join( @repo_path, ".claude", "worktrees", "test-bench" )
		FileUtils.mkdir_p( File.dirname( worktree_path ) )
		system( "git", "-C", @repo_path, "worktree", "add", worktree_path, "-b", "test-bench",
			out: File::NULL, err: File::NULL )

		workbenches = @warehouse.workbenches
		branches = workbenches.map( &:branch )
		assert_includes branches, "test-bench"
	end

	# --- Inventory: workbench_at ---

	def test_workbench_at_finds_by_canonical_path
		worktree_path = File.join( @repo_path, ".claude", "worktrees", "find-me" )
		FileUtils.mkdir_p( File.dirname( worktree_path ) )
		system( "git", "-C", @repo_path, "worktree", "add", worktree_path, "-b", "find-me",
			out: File::NULL, err: File::NULL )

		found = @warehouse.workbench_at( path: worktree_path )
		assert_kind_of Carson::Worktree, found
		assert_equal "find-me", found.branch
	end

	def test_workbench_at_returns_nil_for_unknown_path
		found = @warehouse.workbench_at( path: "/nonexistent/path" )
		assert_nil found
	end

	# --- Inventory: workbench_named ---

	def test_workbench_named_finds_by_bare_name
		worktree_path = File.join( @repo_path, ".claude", "worktrees", "by-name" )
		FileUtils.mkdir_p( File.dirname( worktree_path ) )
		system( "git", "-C", @repo_path, "worktree", "add", worktree_path, "-b", "by-name",
			out: File::NULL, err: File::NULL )

		found = @warehouse.workbench_named( "by-name" )
		assert_kind_of Carson::Worktree, found
		assert_equal "by-name", found.branch
	end

	def test_workbench_named_returns_nil_for_unknown_name
		found = @warehouse.workbench_named( "no-such-bench" )
		assert_nil found
	end

	# --- Inventory: workbench_registered? ---

	def test_workbench_registered_true_for_known_path
		worktree_path = File.join( @repo_path, ".claude", "worktrees", "registered" )
		FileUtils.mkdir_p( File.dirname( worktree_path ) )
		system( "git", "-C", @repo_path, "worktree", "add", worktree_path, "-b", "registered",
			out: File::NULL, err: File::NULL )

		assert @warehouse.workbench_registered?( path: worktree_path )
	end

	def test_workbench_registered_false_for_unknown_path
		refute @warehouse.workbench_registered?( path: "/nonexistent" )
	end

	# --- Lifecycle: build_workbench! ---

	def test_build_workbench_creates_directory_and_branch
		result = @warehouse.build_workbench!( name: "new-bench" )

		assert_equal "ok", result[ :status ]
		assert_equal "new-bench", result[ :name ]
		assert Dir.exist?( result[ :path ] )

		# Branch exists.
		_, _, branch_ok = Open3.capture3( "git", "-C", @repo_path,
			"show-ref", "--verify", "--quiet", "refs/heads/new-bench" )
		assert branch_ok.success?, "branch should be created"
	end

	def test_build_workbench_error_when_name_exists
		@warehouse.build_workbench!( name: "duplicate" )
		result = @warehouse.build_workbench!( name: "duplicate" )

		assert_equal "error", result[ :status ]
		assert_includes result[ :error ], "already exists"
	end

	# --- Lifecycle: remove_workbench! ---

	def test_remove_removes_directory_and_branch
		result = @warehouse.build_workbench!( name: "tear-me" )
		workbench = @warehouse.workbench_named( "tear-me" )

		tear_result = @warehouse.remove_workbench!( workbench )

		assert_equal "ok", tear_result[ :status ]
		refute Dir.exist?( result[ :path ] ), "directory should be removed"

		# Branch should be deleted.
		_, _, branch_ok = Open3.capture3( "git", "-C", @repo_path,
			"show-ref", "--verify", "--quiet", "refs/heads/tear-me" )
		refute branch_ok.success?, "branch should be deleted"
	end

	def test_remove_blocked_when_dirty_without_force
		@warehouse.build_workbench!( name: "dirty-bench" )
		workbench = @warehouse.workbench_named( "dirty-bench" )
		File.write( File.join( workbench.path, "dirty.txt" ), "dirty" )

		result = @warehouse.remove_workbench!( workbench )

		assert_equal "error", result[ :status ]
		assert_includes result[ :error ].to_s.downcase, "uncommitted"
	end

	def test_remove_forced_when_dirty
		@warehouse.build_workbench!( name: "force-bench" )
		workbench = @warehouse.workbench_named( "force-bench" )
		File.write( File.join( workbench.path, "dirty.txt" ), "dirty" )

		result = @warehouse.remove_workbench!( workbench, force: true )

		assert_equal "ok", result[ :status ]
	end

	# --- Safety: assess_removal ---

	def test_assess_removal_ok_for_clean_workbench
		@warehouse.build_workbench!( name: "safe-bench" )
		workbench = @warehouse.workbench_named( "safe-bench" )

		assessment = @warehouse.assess_removal( workbench )
		assert_equal :ok, assessment[ :status ]
	end

	def test_assess_removal_blocked_when_dirty
		@warehouse.build_workbench!( name: "dirty-assess" )
		workbench = @warehouse.workbench_named( "dirty-assess" )
		File.write( File.join( workbench.path, "dirty.txt" ), "dirty" )

		assessment = @warehouse.assess_removal( workbench )
		refute_equal :ok, assessment[ :status ]
		assert assessment[ :error ]
	end

	# --- Safety: workbench knows if CWD is inside ---

	def test_workbench_not_occupied_when_cwd_elsewhere
		@warehouse.build_workbench!( name: "not-here" )
		workbench = @warehouse.workbench_named( "not-here" )

		refute workbench.holds_cwd?
	end

	# --- Repair: missing workbench ---

	def test_remove_repairs_missing_workbench
		@warehouse.build_workbench!( name: "will-vanish" )
		workbench = @warehouse.workbench_named( "will-vanish" )

		# Destroy the directory externally.
		FileUtils.rm_rf( workbench.path )

		result = @warehouse.remove_workbench!( workbench )
		assert_equal "ok", result[ :status ]

		# Branch should be cleaned up.
		_, _, branch_ok = Open3.capture3( "git", "-C", @repo_path,
			"show-ref", "--verify", "--quiet", "refs/heads/will-vanish" )
		refute branch_ok.success?, "branch should be deleted after repair"
	end
end
