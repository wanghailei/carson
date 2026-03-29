# Tests for Carson::Warehouse::Vault — the production standard.
# The vault is local main. It accepts parcels and tracks absorption.
# Tests real git operations against temporary repositories. No mocking.
require_relative "test_helper"
require_relative "../lib/carson/parcel"
require "open3"

class VaultTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-vault-test", carson_tmp_root )
		@repo_path = File.join( @tmpdir, "repo" )

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

	# --- Accept ---

	def test_accept_fast_forwards_the_standard
		# Create a branch ahead of main, then switch back.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/login", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "login.txt" ), "login" )
		system( "git", "-C", @repo_path, "add", "login.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "add login", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		parcel = Carson::Parcel.new( label: "feature/login", head: "ignored" )

		result = vault.accept!( parcel )
		assert_equal "ok", result[ :status ]
		assert_equal "feature/login", result[ :branch ]

		# Verify the file is now on main.
		main_files, = Open3.capture3( "git", "-C", @repo_path, "ls-tree", "--name-only", "main" )
		assert_includes main_files, "login.txt"
	end

	def test_accept_returns_new_head
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/head", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "head.txt" ), "head check" )
		system( "git", "-C", @repo_path, "add", "head.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "head check", out: File::NULL, err: File::NULL )
		branch_head, = Open3.capture3( "git", "-C", @repo_path, "rev-parse", "HEAD" )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		parcel = Carson::Parcel.new( label: "feature/head", head: branch_head.strip )

		result = vault.accept!( parcel )
		assert_equal "ok", result[ :status ]
		assert_equal branch_head.strip, result[ :head ]
	end

	def test_accept_blocks_when_not_fast_forward
		# Create diverged branches.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/diverged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "diverged.txt" ), "diverged" )
		system( "git", "-C", @repo_path, "add", "diverged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "diverged branch", out: File::NULL, err: File::NULL )

		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "main-only.txt" ), "main" )
		system( "git", "-C", @repo_path, "add", "main-only.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "main diverged", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		parcel = Carson::Parcel.new( label: "feature/diverged", head: "ignored" )

		result = vault.accept!( parcel )
		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "cannot be fast-forwarded"
		assert_includes result[ :recovery ], "Rebase"
	end

	def test_accept_blocks_with_dirty_tree_diagnosis
		# Create a branch that modifies README.md.
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/dirty", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Changed by branch" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "change readme", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )

		# Dirty the same file in the main worktree (uncommitted).
		File.write( File.join( @repo_path, "README.md" ), "# Dirty local edit" )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		parcel = Carson::Parcel.new( label: "feature/dirty", head: "ignored" )

		result = vault.accept!( parcel )
		assert_equal "block", result[ :status ]
		assert_includes result[ :error ], "uncommitted changes"
		assert_includes result[ :recovery ], "dirty files"
		refute_includes result[ :error ], "cannot be fast-forwarded"
	end

	def test_accept_errors_when_main_not_checked_out
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/other", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		parcel = Carson::Parcel.new( label: "feature/other", head: "ignored" )

		result = vault.accept!( parcel )
		assert_equal "error", result[ :status ]
		assert_includes result[ :error ], "not checked out"
	end

	# --- Absorbed ---

	def test_absorbed_true_when_merged
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/merged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "merged.txt" ), "merged" )
		system( "git", "-C", @repo_path, "add", "merged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on merged branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "merge", "feature/merged", "--no-ff", "-m", "merge", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		assert vault.absorbed?( "feature/merged" )
	end

	def test_absorbed_true_when_rebase_merged
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/rebased", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "rebased.txt" ), "rebased" )
		system( "git", "-C", @repo_path, "add", "rebased.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on rebased branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "cherry-pick", "feature/rebased", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		assert vault.absorbed?( "feature/rebased" ),
			"absorbed? should detect rebase-merged branches by content, not ancestry"
	end

	def test_absorbed_false_when_not_merged
		system( "git", "-C", @repo_path, "checkout", "-b", "feature/unmerged", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "unmerged.txt" ), "unmerged" )
		system( "git", "-C", @repo_path, "add", "unmerged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "on unmerged branch", out: File::NULL, err: File::NULL )

		vault = Carson::Warehouse::Vault.new( path: @repo_path, main_label: "main" )
		refute vault.absorbed?( "feature/unmerged" )
	end
end
