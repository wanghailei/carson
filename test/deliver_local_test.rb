# Tests for local-centred delivery — the full flow.
# Warehouse.prepare! → Warehouse.accept! → Courier.deliver (local gesture).
# Tests real git operations against temporary repositories. No mocking.
require_relative "test_helper"
require_relative "../lib/carson/parcel"
require_relative "../lib/carson/courier"
require "open3"

class DeliverLocalTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-local-deliver-test", carson_tmp_root )
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

	# --- Warehouse.prepare! ---

	def test_prepare_packs_when_message_provided
		worktree_path = create_worktree( "prep-pack" )
		File.write( File.join( worktree_path, "new.txt" ), "new content" )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "prep-pack", head: warehouse.current_head )
		result = warehouse.prepare!( parcel, message: "pack this" )

		assert_equal "ok", result[ :status ]

		# Verify the commit exists on the branch.
		log, = Open3.capture3( "git", "-C", worktree_path, "log", "--oneline", "-1" )
		assert_includes log, "pack this"
	end

	def test_prepare_skips_pack_when_no_message
		worktree_path = create_worktree( "prep-nopack" )
		File.write( File.join( worktree_path, "staged.txt" ), "staged" )
		system( "git", "-C", worktree_path, "add", "staged.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "pre-packed", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "prep-nopack", head: warehouse.current_head )
		result = warehouse.prepare!( parcel )

		assert_equal "ok", result[ :status ]
	end

	def test_prepare_auto_rebases_when_behind
		worktree_path = create_worktree( "prep-rebase" )
		File.write( File.join( worktree_path, "branch.txt" ), "branch work" )
		system( "git", "-C", worktree_path, "add", "branch.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "branch work", out: File::NULL, err: File::NULL )

		# Advance main on the remote so the branch is behind.
		File.write( File.join( @repo_path, "advance.txt" ), "advance" )
		system( "git", "-C", @repo_path, "add", "advance.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "origin", "main", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "prep-rebase", head: warehouse.current_head )
		result = warehouse.prepare!( parcel )

		assert_equal "ok", result[ :status ]
	end

	# --- Courier local gesture ---

	def test_courier_local_pushes_main_to_remote
		worktree_path = create_worktree( "local-push" )
		File.write( File.join( worktree_path, "local.txt" ), "local work" )
		system( "git", "-C", worktree_path, "add", "local.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "local work", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "local-push", head: warehouse.current_head )

		# Accept into vault first.
		vault_result = warehouse.accept!( parcel )
		assert_equal "ok", vault_result[ :status ]

		# Courier delivers (local gesture = push backup).
		courier = Carson::Courier.new( warehouse, workstyle: :local, output: StringIO.new )
		result = courier.deliver( parcel )

		assert_equal "delivered", result[ :outcome ]
		assert_equal true, result[ :synced ]

		# Verify remote main has the new commit.
		remote_log, = Open3.capture3( "git", "-C", @remote_path, "log", "--oneline", "main" )
		assert_includes remote_log, "local work"
	end

	# --- End-to-end local deliver ---

	def test_full_local_deliver_flow
		worktree_path = create_worktree( "e2e" )
		File.write( File.join( worktree_path, "feature.txt" ), "end to end" )
		system( "git", "-C", worktree_path, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "e2e feature", out: File::NULL, err: File::NULL )

		warehouse = Carson::Warehouse.new( path: worktree_path, bureau_address: "origin" )
		parcel = Carson::Parcel.new( label: "e2e", head: warehouse.current_head )

		# Step 1: Prepare.
		prep = warehouse.prepare!( parcel )
		assert_equal "ok", prep[ :status ]

		# Step 2: Accept into vault.
		accept = warehouse.accept!( prep[ :parcel ] || parcel )
		assert_equal "ok", accept[ :status ]

		# Step 3: Courier delivers backup.
		courier = Carson::Courier.new( warehouse, workstyle: :local, output: StringIO.new )
		deliver = courier.deliver( parcel )
		assert_equal "delivered", deliver[ :outcome ]

		# Verify: file on local main.
		main_files, = Open3.capture3( "git", "-C", @repo_path, "ls-tree", "--name-only", "main" )
		assert_includes main_files, "feature.txt"

		# Verify: file on remote main.
		remote_log, = Open3.capture3( "git", "-C", @remote_path, "log", "--oneline", "main" )
		assert_includes remote_log, "e2e feature"
	end

private

	def create_worktree( name )
		worktree_path = File.join( @tmpdir, name )
		system( "git", "-C", @repo_path, "worktree", "add", "-b", name, worktree_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		worktree_path
	end
end
