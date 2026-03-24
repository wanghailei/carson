# Tests for Carson::Worktree — a passive workbench in the warehouse.
# The workbench shows state: path, branch, existence, cleanliness, staleness.
# It does not act. The Warehouse owns its lifecycle.
require_relative "test_helper"
require "open3"

class WorktreeTest < Minitest::Test
	def setup
		@tmpdir = Dir.mktmpdir( "carson-worktree-test" )
		@repo_path = File.join( @tmpdir, "repo" )

		# Create a real git repo so clean? can run git status.
		system( "git", "init", "-b", "main", @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "initial commit", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.rm_rf( @tmpdir )
	end

	# --- Identity ---

	def test_knows_its_path
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "feature/login" )
		assert_equal "/tmp/workbench", workbench.path
	end

	def test_knows_its_branch
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "feature/login" )
		assert_equal "feature/login", workbench.branch
	end

	def test_knows_its_prunable_reason
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "old", prunable_reason: "gitdir file points to non-existent location" )
		assert_equal "gitdir file points to non-existent location", workbench.prunable_reason
	end

	def test_prunable_reason_defaults_to_nil
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "feature/login" )
		assert_nil workbench.prunable_reason
	end

	# --- exists? ---

	def test_exists_when_directory_present
		workbench = Carson::Worktree.new( path: @repo_path, branch: "main" )
		assert workbench.exists?
	end

	def test_not_exists_when_directory_missing
		workbench = Carson::Worktree.new( path: File.join( @tmpdir, "gone" ), branch: "old" )
		refute workbench.exists?
	end

	# --- clean? ---

	def test_clean_when_nothing_uncommitted
		workbench = Carson::Worktree.new( path: @repo_path, branch: "main" )
		assert workbench.clean?
	end

	def test_not_clean_when_untracked_file
		File.write( File.join( @repo_path, "dirty.txt" ), "uncommitted" )
		workbench = Carson::Worktree.new( path: @repo_path, branch: "main" )
		refute workbench.clean?
	end

	def test_not_clean_when_modified_file
		File.write( File.join( @repo_path, "README.md" ), "modified" )
		workbench = Carson::Worktree.new( path: @repo_path, branch: "main" )
		refute workbench.clean?
	end

	def test_clean_false_when_directory_missing
		workbench = Carson::Worktree.new( path: File.join( @tmpdir, "gone" ), branch: "old" )
		refute workbench.clean?
	end

	# --- prunable? ---

	def test_prunable_when_reason_present
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "old", prunable_reason: "gitdir file points to non-existent location" )
		assert workbench.prunable?
	end

	def test_not_prunable_when_reason_nil
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "main" )
		refute workbench.prunable?
	end

	def test_not_prunable_when_reason_empty
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "main", prunable_reason: "" )
		refute workbench.prunable?
	end

	def test_not_prunable_when_reason_whitespace
		workbench = Carson::Worktree.new( path: "/tmp/workbench", branch: "main", prunable_reason: "   " )
		refute workbench.prunable?
	end
end
