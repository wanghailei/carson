# Tests for Warehouse::Vault — vault acceptance (local-centred delivery).
# Tests real git operations against temporary repositories. No mocking.
require_relative "test_helper"
require_relative "../lib/carson/parcel"
require "open3"

class VaultTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-vault-test", carson_tmp_root )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		# Create a bare remote and clone it.
		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.rm_rf( @tmpdir )
	end

	# --- Vault acceptance: fast-forward merge ---

	def test_accept_merges_branch_into_main
		# Create a branch with a commit, then switch back to main.
		worktree_path = create_worktree( "feature" )
		File.write( File.join( worktree_path, "feature.txt" ), "new feature" )
		system( "git", "-C", worktree_path, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "add feature", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature", head: warehouse.current_head )
		result = warehouse.accept!( parcel )

		assert_equal "ok", result[ :status ]
		assert_equal "feature", result[ :branch ]

		# Verify the file is now on main.
		main_files, = Open3.capture3( "git", "-C", @repo_path, "ls-tree", "--name-only", "main" )
		assert_includes main_files, "feature.txt"
	end

	def test_accept_blocks_when_branch_has_diverged
		# Create a branch with a commit.
		worktree_path = create_worktree( "diverged" )
		File.write( File.join( worktree_path, "diverged.txt" ), "diverged work" )
		system( "git", "-C", worktree_path, "add", "diverged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "diverged work", out: File::NULL, err: File::NULL )

		# Create a different commit on main (making the branch non-ff).
		File.write( File.join( @repo_path, "main-change.txt" ), "main changed" )
		system( "git", "-C", @repo_path, "add", "main-change.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "main moves forward", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "diverged", head: warehouse.current_head )
		result = warehouse.accept!( parcel )

		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "cannot be fast-forwarded"
		assert_includes result[ :recovery ], "Rebase"
	end

	def test_accept_blocks_with_dirty_tree_diagnosis_when_main_has_conflicting_changes
		# Create a branch that modifies README.md.
		worktree_path = create_worktree( "dirty-conflict" )
		File.write( File.join( worktree_path, "README.md" ), "# Changed by branch" )
		system( "git", "-C", worktree_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "change readme", out: File::NULL, err: File::NULL )

		# Dirty the same file in the main worktree (uncommitted).
		File.write( File.join( @repo_path, "README.md" ), "# Dirty local edit" )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "dirty-conflict", head: warehouse.current_head )
		result = warehouse.accept!( parcel )

		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "uncommitted changes"
		assert_includes result[ :recovery ], "dirty files"
		# Must NOT say "cannot be fast-forwarded" — the branch IS a valid ff descendant.
		refute_includes result[ :error ], "cannot be fast-forwarded"
	end

	def test_accept_returns_new_head_after_merge
		worktree_path = create_worktree( "headcheck" )
		File.write( File.join( worktree_path, "check.txt" ), "head check" )
		system( "git", "-C", worktree_path, "add", "check.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "head check", out: File::NULL, err: File::NULL )

		branch_head, = Open3.capture3( "git", "-C", worktree_path, "rev-parse", "HEAD" )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "headcheck", head: branch_head.strip )
		result = warehouse.accept!( parcel )

		assert_equal "ok", result[ :status ]
		# After ff-only merge, main's HEAD should match the branch's HEAD.
		assert_equal branch_head.strip, result[ :head ]
	end

private

	# Create a worktree branch from main and return its path.
	def create_worktree( name )
		worktree_path = File.join( @tmpdir, name )
		system( "git", "-C", @repo_path, "worktree", "add", "-b", name, worktree_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		worktree_path
	end
end
