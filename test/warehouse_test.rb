# Tests for Carson::Warehouse — the intelligent, self-managing building.
# Vault, seal, and bureau tested via Warehouse interface.
# Tests real git operations against temporary repositories. No mocking.
require_relative "test_helper"
require_relative "../lib/carson/parcel"
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
		# Clean up seal files created during tests.
		seals_dir = File.join( ENV.fetch( "HOME" ), ".carson", "seals" )
		FileUtils.rm_rf( seals_dir ) if Dir.exist?( seals_dir )
	end

	# --- Identity ---

	def test_path_returns_warehouse_location
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert_equal @repo_path, warehouse.path
	end

	# --- What the warehouse knows ---

	def test_current_label_returns_active_branch
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert_equal "main", warehouse.current_label
	end

	def test_current_label_follows_branch_changes
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/login", out: File::NULL, err: File::NULL )
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert_equal "feature/login", warehouse.current_label
	end

	def test_current_head_returns_commit_sha
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		expected_sha, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "HEAD" )
		assert_equal expected_sha.strip, warehouse.current_head
	end

	def test_main_label_defaults_to_main
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert_equal "main", warehouse.main_label
	end

	def test_main_label_uses_config_value
		warehouse = Carson::Warehouse.new( path: @repo_path, main_label: "trunk" )
		assert_equal "trunk", warehouse.main_label
	end

	def test_bureau_address_defaults_to_github
		warehouse = Carson::Warehouse.new( path: @repo_path )
		assert_equal "github", warehouse.bureau_address
	end

	def test_bureau_address_uses_config_value
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "upstream" )
		assert_equal "upstream", warehouse.bureau_address
	end

	# --- Cleanliness ---

	def test_clean_when_nothing_uncommitted
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert warehouse.clean?
	end

	def test_not_clean_when_dirty
		File.write( File.join( @repo_path, "dirty.txt" ), "uncommitted" )
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		refute warehouse.clean?
	end

	# --- Compliance ---

	def test_submit_compliance_passes_without_checker
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		result = warehouse.submit_compliance!
		assert result[ :compliant ]
		refute result[ :committed ]
	end

	def test_submit_compliance_delegates_to_checker
		checker = ->( _warehouse ) { { compliant: true, committed: true } }
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin", compliance_checker: checker )
		result = warehouse.submit_compliance!
		assert result[ :compliant ]
		assert result[ :committed ]
	end

	def test_submit_compliance_reports_failure
		checker = ->( _warehouse ) { { compliant: false, committed: false, error: "template drift" } }
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin", compliance_checker: checker )
		result = warehouse.submit_compliance!
		refute result[ :compliant ]
		assert_equal "template drift", result[ :error ]
	end

	# --- Warehouse operations ---

	def test_pack_stages_and_commits
		File.write( File.join( @repo_path, "new_file.txt" ), "content" )
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		warehouse.pack!( message: "add new file" )

		log, = Open3.capture3( "git", "-C", @repo_path, "log", "--oneline", "-1" )
		assert_includes log, "add new file"
	end

	def test_pack_returns_truthy_on_success
		File.write( File.join( @repo_path, "file.txt" ), "content" )
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		result = warehouse.pack!( message: "test commit" )
		assert result
	end

	def test_ship_pushes_to_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/ship-test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "shipped.txt" ), "shipped" )
		system( "git", "-C", @repo_path, "add", "shipped.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "ship this", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/ship-test", head: warehouse.current_head )
		result = warehouse.ship( parcel )
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

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/custom-remote", head: warehouse.current_head )
		result = warehouse.ship( parcel, remote: "upstream" )
		assert result

		remote_branches, = Open3.capture3( "git", "-C", second_remote, "branch" )
		assert_includes remote_branches, "feature/custom-remote"
	end

	def test_based_on_latest_when_up_to_date
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "main", head: warehouse.current_head )
		assert warehouse.based_on_latest?( parcel )
	end

	def test_based_on_latest_false_when_behind
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

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		# Fetch so we know about the new remote commit.
		warehouse.receive_latest!

		parcel = Carson::Parcel.new( label: "feature/behind", head: warehouse.current_head )
		refute warehouse.based_on_latest?( parcel )
	end

	# --- Production standard ---

	def test_rebase_onto_latest_standard
		# Advance main on the remote via a second clone.
		second_clone = File.join( @tmpdir, "second-clone-rebase" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "advanced.txt" ), "advanced" )
		system( "git", "-C", second_clone, "add", "advanced.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "advance registry", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Create a feature branch on original repo (behind registry).
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/needs-rebase", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "feature.txt" ), "feature work" )
		system( "git", "-C", @repo_path, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "feature commit", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		warehouse.receive_latest!

		# Confirm behind before updating.
		parcel = Carson::Parcel.new( label: "feature/needs-rebase", head: warehouse.current_head )
		refute warehouse.based_on_latest?( parcel )

		# Update standard — rebase onto registry.
		result = warehouse.rebase!
		assert result

		# After rebase, the parcel should be based on the latest standard.
		rebased_parcel = Carson::Parcel.new( label: "feature/needs-rebase", head: warehouse.current_head )
		assert warehouse.based_on_latest?( rebased_parcel )
	end

	def test_rebase_returns_false_on_conflict
		# Advance main on remote with a conflicting file.
		second_clone = File.join( @tmpdir, "second-clone-conflict" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "conflict.txt" ), "remote version" )
		system( "git", "-C", second_clone, "add", "conflict.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "remote conflict", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Create a feature branch with the same file, different content.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/conflict", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "conflict.txt" ), "local version" )
		system( "git", "-C", @repo_path, "add", "conflict.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "local conflict", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		warehouse.receive_latest!

		result = warehouse.rebase!
		refute result

		# Clean up the failed rebase so teardown can remove the directory.
		system( "git", "-C", @repo_path, "rebase", "--abort", out: File::NULL, err: File::NULL )
	end

	# --- Receive latest standard ---

	def test_receive_latest_fast_forwards_local_main
		# Advance remote main via a second clone.
		second_clone = File.join( @tmpdir, "second-clone-sync" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "synced.txt" ), "synced" )
		system( "git", "-C", second_clone, "add", "synced.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "advance for sync", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Switch to a feature branch so we're not on main.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/sync-test", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )

		# Local main should be behind before sync.
		local_before, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )
		remote_after, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "origin/main" )

		result = warehouse.receive_latest!
		assert result

		# After sync, local main should match the remote.
		local_after, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )
		refute_equal local_before.strip, local_after.strip
	end

	# --- Inventory ---

	def test_labels_returns_all_branch_names
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/alpha", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/beta", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		labels = warehouse.labels

		assert_includes labels, "main"
		assert_includes labels, "feature/alpha"
		assert_includes labels, "feature/beta"
	end

	def test_absorbed_true_when_merged
		# Create and merge a branch.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/merged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "merged.txt" ), "merged" )
		system( "git", "-C", @repo_path, "add", "merged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on merged branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "merge", "feature/merged", "--no-ff", "-m", "merge merged", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert warehouse.absorbed?( "feature/merged" )
	end

	def test_absorbed_true_when_rebase_merged
		# Simulate a rebase merge: replay the branch commit as a new SHA on main.
		# The original branch tip is NOT reachable from main — this is the bug
		# that `git branch --merged` missed.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/rebased", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "rebased.txt" ), "rebased" )
		system( "git", "-C", @repo_path, "add", "rebased.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on rebased branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )

		# Cherry-pick replays the content with a new SHA — same effect as rebase merge.
		system( "git", "-C", @repo_path, "cherry-pick", "feature/rebased", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		assert warehouse.absorbed?( "feature/rebased" ),
			"absorbed? should return true for rebase-merged branches"
	end

	def test_absorbed_false_when_not_merged
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/unmerged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "unmerged.txt" ), "unmerged" )
		system( "git", "-C", @repo_path, "add", "unmerged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on unmerged branch", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		refute warehouse.absorbed?( "feature/unmerged" )
	end

	# --- Error handling ---

	def test_pack_fails_gracefully_with_nothing_to_commit
		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		result = warehouse.pack!( message: "nothing here" )
		refute result
	end

	def test_ship_fails_gracefully_with_invalid_remote
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/bad-remote", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "bad.txt" ), "bad" )
		system( "git", "-C", @repo_path, "add", "bad.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "bad remote test", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "feature/bad-remote", head: warehouse.current_head )
		result = warehouse.ship( parcel, remote: "nonexistent" )
		refute result
	end

	# --- Shelf seal ---

	def test_sealed_false_by_default
		warehouse = Carson::Warehouse.new( path: @repo_path )
		refute warehouse.sealed?
	end

	def test_seal_and_unseal_workbench
		warehouse = Carson::Warehouse.new( path: @repo_path )
		warehouse.seal!( tracking: 42 )

		assert warehouse.sealed?
		assert_equal "42", warehouse.sealed_tracking_number

		warehouse.unseal!
		refute warehouse.sealed?
		assert_nil warehouse.sealed_tracking_number
	end

	def test_pack_blocked_when_shelf_sealed
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/sealed", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "sealed.txt" ), "sealed" )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		warehouse.seal!( tracking: 99 )

		error = assert_raises( RuntimeError ) do
			warehouse.pack!( message: "should be blocked" )
		end
		assert_includes error.message, "locked"
		assert_includes error.message, "PR #99"
	end

	def test_pack_allowed_after_shelf_unsealed
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/unsealed", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "unsealed.txt" ), "unsealed" )

		warehouse = Carson::Warehouse.new( path: @repo_path )
		warehouse.seal!( tracking: 100 )
		warehouse.unseal!

		assert warehouse.pack!( message: "should work after unseal" )
	end

	def test_unseal_is_safe_when_not_sealed
		warehouse = Carson::Warehouse.new( path: @repo_path )
		# Should not raise.
		warehouse.unseal!
		refute warehouse.sealed?
	end

	def test_seal_does_not_dirty_worktree
		warehouse = Carson::Warehouse.new( path: @repo_path )
		warehouse.seal!( tracking: 42 )

		assert warehouse.clean?, "seal marker should not appear in git status"

		warehouse.unseal!
	end

	# --- Receive latest standard from worktree ---

	def test_receive_latest_from_worktree
		# Create a worktree — main stays checked out in the main tree.
		worktree_path = File.join( @tmpdir, "worktree" )
		system( "git", "-C", @repo_path, "worktree", "add", "-b", "feature/wt-sync",
			worktree_path, out: File::NULL, err: File::NULL )

		# Advance remote main via a second clone.
		second_clone = File.join( @tmpdir, "second-clone-wt" )
		system( "git", "clone", @remote_path, second_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( second_clone, "wt-synced.txt" ), "synced" )
		system( "git", "-C", second_clone, "add", "wt-synced.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "commit", "-m", "advance for wt sync", out: File::NULL, err: File::NULL )
		system( "git", "-C", second_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )

		# Create warehouse from the worktree (the normal courier scenario).
		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )

		local_before, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )

		result = warehouse.receive_latest!
		assert result, "receive_latest! should succeed from worktree"

		local_after, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "main" )
		refute_equal local_before.strip, local_after.strip,
			"local main should advance after receive_latest! from worktree"

		# Cleanup worktree.
		system( "git", "-C", @repo_path, "worktree", "remove", worktree_path,
			out: File::NULL, err: File::NULL )
	end
end
