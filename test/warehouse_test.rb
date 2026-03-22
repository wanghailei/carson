# Tests for Carson::Warehouse — the repository with story-language methods.
# Tests real git operations against temporary repositories. No mocking.
require_relative "test_helper"
require "open3"

class WarehouseTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-warehouse-test", carson_tmp_root )
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
	end

	def teardown
		FileUtils.rm_rf( @tmpdir )
	end

	# --- Identity ---

	def test_path_returns_warehouse_location
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal @repo_path, warehouse.path
	end

	# --- What the warehouse knows ---

	def test_current_label_returns_active_branch
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal "main", warehouse.current_label
	end

	def test_current_label_follows_branch_changes
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/login", out: File::NULL, err: File::NULL )
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal "feature/login", warehouse.current_label
	end

	def test_current_head_returns_commit_sha
		warehouse = Carson::Warehouse.new( path: @repo_path )
		expected_sha, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "HEAD" )
		assert_equal expected_sha.strip, warehouse.current_head
	end

	def test_main_label_defaults_to_main
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal "main", warehouse.main_label
	end

	def test_main_label_uses_config_value
		warehouse = Carson::Warehouse.new( path: @repo_path, main_label: "trunk" )
		assert_equal "trunk", warehouse.main_label
	end

	def test_bureau_address_defaults_to_origin
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal "origin", warehouse.bureau_address
	end

	def test_bureau_address_uses_config_value
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "upstream" )
		assert_equal "upstream", warehouse.bureau_address
	end

	# --- Warehouse operations ---

	def test_prepare_stages_and_commits
		File.write( File.join( @repo_path, "new_file.txt" ), "content" )
		warehouse = Carson::Warehouse.new( path: @repo_path )
		warehouse.prepare!( message: "add new file" )

		log, = Open3.capture3( "git", "-C", @repo_path, "log", "--oneline", "-1" )
		assert_includes log, "add new file"
	end

	def test_prepare_returns_truthy_on_success
		File.write( File.join( @repo_path, "file.txt" ), "content" )
		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.prepare!( message: "test commit" )
		assert result
	end

	def test_ship_pushes_to_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/ship-test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "shipped.txt" ), "shipped" )
		system( "git", "-C", @repo_path, "add", "shipped.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "ship this", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.ship( "feature/ship-test" )
		assert result

		# Verify the remote received the branch.
		remote_branches, = Open3.capture3( "git", "-C", @remote_path, "branch" )
		assert_includes remote_branches, "feature/ship-test"
	end

	def test_ship_uses_custom_remote
		# Create a second bare remote.
		second_remote = File.join( @tmpdir, "second.git" )
		system( "git", "init", "--bare", "-b", "main", second_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "remote", "add", "upstream", second_remote, out: File::NULL, err: File::NULL )

		system( "git", "-C", @repo_path, "checkout", "-b", "feature/custom-remote", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "custom.txt" ), "custom" )
		system( "git", "-C", @repo_path, "add", "custom.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "custom remote", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.ship( "feature/custom-remote", remote: "upstream" )
		assert result

		remote_branches, = Open3.capture3( "git", "-C", second_remote, "branch" )
		assert_includes remote_branches, "feature/custom-remote"
	end

	def test_fetch_latest_updates_remote_refs
		# Push main to remote first (already done in setup).
		# Clone a second copy, make a commit there, push it.
		second_clone = File.join( @tmpdir, "second-clone" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "from_second.txt" ), "hello" )
		system( "git", "-C", second_clone, "add", "from_second.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "from second clone", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Before fetch, our repo doesn't know about the new commit.
		before_sha, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "origin/main" )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.fetch_latest
		assert result

		after_sha, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "origin/main" )
		refute_equal before_sha.strip, after_sha.strip
	end

	def test_fetch_latest_uses_custom_remote
		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.fetch_latest( remote: "origin" )
		assert result
	end

	def test_includes_latest_when_up_to_date
		warehouse = Carson::Warehouse.new( path: @repo_path )
		# On main, which is up to date with origin/main.
		assert warehouse.includes_latest?( "main" )
	end

	def test_includes_latest_false_when_behind
		# Make a second clone, push a new commit.
		second_clone = File.join( @tmpdir, "second-clone-ancestor" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "newer.txt" ), "newer" )
		system( "git", "-C", second_clone, "add", "newer.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "newer commit", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Create a feature branch on the original repo without fetching.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/behind", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		# Fetch so we know about the new remote commit.
		warehouse.fetch_latest

		refute warehouse.includes_latest?( "feature/behind" )
	end

	# --- Inventory ---

	def test_labels_returns_all_branch_names
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/alpha", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/beta", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		labels = warehouse.labels

		assert_includes labels, "main"
		assert_includes labels, "feature/alpha"
		assert_includes labels, "feature/beta"
	end

	def test_label_absorbed_true_when_merged
		# Create and merge a branch.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/merged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "merged.txt" ), "merged" )
		system( "git", "-C", @repo_path, "add", "merged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on merged branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "merge", "feature/merged", "--no-ff", "-m", "merge merged", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert warehouse.label_absorbed?( "feature/merged" )
	end

	def test_label_absorbed_false_when_not_merged
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/unmerged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "unmerged.txt" ), "unmerged" )
		system( "git", "-C", @repo_path, "add", "unmerged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on unmerged branch", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		refute warehouse.label_absorbed?( "feature/unmerged" )
	end

	def test_shelves_returns_worktree_paths
		warehouse = Carson::Warehouse.new( path: @repo_path )
		shelves = warehouse.shelves

		# At minimum, the main worktree should be present.
		assert shelves.any? { |shelf| shelf.include?( @repo_path ) }
	end

	# --- Error handling ---

	def test_prepare_fails_gracefully_with_nothing_to_commit
		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.prepare!( message: "nothing here" )
		refute result
	end

	def test_ship_fails_gracefully_with_invalid_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/bad-remote", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "bad.txt" ), "bad" )
		system( "git", "-C", @repo_path, "add", "bad.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "bad remote test", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		result = warehouse.ship( "feature/bad-remote", remote: "nonexistent" )
		refute result
	end
end
