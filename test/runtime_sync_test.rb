# Tests for sync! --json output and recovery messages.
require_relative "test_helper"

class RuntimeSyncTest < Minitest::Test
	include CarsonTestSupport

	def test_sync_json_includes_command_and_status
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		result = runtime.sync!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "sync", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_sync_json_includes_sync_counts
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		runtime.sync!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal 0, json[ "ahead" ]
		assert_equal 0, json[ "behind" ]
		assert_equal "main", json[ "main_branch" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_sync_json_dirty_tree_blocks_with_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		# Make the working tree dirty.
		File.write( File.join( repo_root, "dirty.txt" ), "uncommitted" )

		result = runtime.sync!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_equal "main working tree has uncommitted changes", json[ "error" ]
		assert_includes json[ "recovery" ], "carson worktree create <name>"
		refute_includes json[ "recovery" ], "git add -A && git commit"
		assert json[ "recovery" ], "Should include recovery command"
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_sync_human_output_dirty_tree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		File.write( File.join( repo_root, "dirty.txt" ), "uncommitted" )

		runtime.sync!( json_output: false )
		output = output_string( runtime )
		assert_includes output, "main working tree has uncommitted changes"
		assert_includes output, "carson worktree create <name>"
		assert_includes output, "→"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_sync_from_dirty_worktree_redirects_to_main_tree
		with_feature_worktree_runtime do |runtime, _repo_root, worktree_path|
			File.write( File.join( worktree_path, "dirty.txt" ), "uncommitted" )

			result = runtime.sync!( json_output: true )
			json = JSON.parse( output_string( runtime ).strip )
			assert_equal "ok", json[ "status" ], "dirty worktree should not block main sync"
			assert_equal Carson::Runtime::EXIT_OK, result
		end
	end

	def test_sync_human_output_success
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		runtime.sync!( json_output: false )
		output = output_string( runtime )
		assert_includes output, "OK:"
		assert_includes output, "in sync"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo_with_remote( repo_root )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", remote_path, out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
		@remote_path = remote_path
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def with_feature_worktree_runtime
		Dir.mktmpdir( "carson-sync-worktree-test", carson_tmp_root ) do |tmp_dir|
			remote_path = File.join( tmp_dir, "remote.git" )
			repo_root = File.join( tmp_dir, "repo" )
			worktree_path = File.join( repo_root, ".claude", "worktrees", "sync-dirty" )
			branch_name = "codex/sync-dirty"

			system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
			system( "git", "clone", remote_path, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "README.md" ), "# Test" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, out: File::NULL, err: File::NULL )
			# Exclude .claude/ from main tree status, as Carson's real worktree create does.
			exclude_path = File.join( repo_root, ".git", "info", "exclude" )
			FileUtils.mkdir_p( File.dirname( exclude_path ) )
			File.open( exclude_path, "a" ) { |file| file.puts ".claude/" }

			output = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: worktree_path,
				tool_root: File.expand_path( "..", __dir__ ),
				output: output,
				error: StringIO.new,
				verbose: false
			)

			yield runtime, repo_root, worktree_path
		end
	end

	def destroy_runtime_repo( repo_root: )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
