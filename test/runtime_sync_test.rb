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
		assert_includes json[ "error" ], "dirty"
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
		assert_includes output, "BLOCK:"
		assert_includes output, "dirty"
		assert_includes output, "Recovery:"
		destroy_runtime_repo( repo_root: repo_root )
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
		runtime.instance_variable_get( :@out ).string
	end

	def destroy_runtime_repo( repo_root: )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
