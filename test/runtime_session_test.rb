# Tests for session state persistence (carson session).
# Verifies read, write, clear, update_session side effects, and JSON output.
require_relative "test_helper"

class RuntimeSessionTest < Minitest::Test
	include CarsonTestSupport

	# --- session! read ---

	def test_session_returns_empty_state_for_new_repo
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.session!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "No active session state"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_session_json_returns_structured_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "session", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal repo_root, json[ "repo" ]
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- session! with --task ---

	def test_session_with_task_records_task
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.session!( task: "implement feature X" )
		output = output_string( runtime )
		assert_includes output, "Task: implement feature X"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_session_with_task_persists_across_reads
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.session!( task: "persistent task" )

		# Reset output and read again.
		reset_output( runtime )

		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "persistent task", json[ "task" ]

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- session_clear! ---

	def test_session_clear_removes_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.session!( task: "will be cleared" )
		reset_output( runtime )

		result = runtime.session_clear!
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "Session state cleared"

		# Reading again should show empty state.
		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		refute json.key?( "task" ), "task should be gone after clear"
		refute json.key?( "worktree" ), "worktree should be gone after clear"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_session_clear_json_output
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.session_clear!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "session clear", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- update_session side effects ---

	def test_update_session_records_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session, worktree: { name: "my-wt", path: "/tmp/wt", branch: "my-wt" } )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "my-wt", json[ "worktree" ][ "name" ]
		assert_equal "my-wt", json[ "worktree" ][ "branch" ]

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_update_session_records_pr
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session, pr: { number: 42, url: "https://github.com/test/repo/pull/42" } )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal 42, json[ "pr" ][ "number" ]
		assert_includes json[ "pr" ][ "url" ], "pull/42"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_update_session_clear_sentinel_removes_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session, worktree: { name: "temp", branch: "temp" } )
		runtime.send( :update_session, worktree: :clear )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		refute json.key?( "worktree" ), "worktree should be cleared"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_update_session_preserves_unmentioned_fields
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session, task: "my task" )
		runtime.send( :update_session, pr: { number: 10, url: "http://example.com" } )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "my task", json[ "task" ], "task should be preserved"
		assert_equal 10, json[ "pr" ][ "number" ], "pr should be recorded"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- session file path ---

	def test_session_file_uses_repo_basename_and_hash
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		path = runtime.send( :session_file_path )
		basename = File.basename( repo_root )
		assert_includes File.basename( path ), basename
		assert path.end_with?( ".json" )
		assert_includes path, "sessions"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree_create! side effect ---

	def test_worktree_create_records_session_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "session-wt" )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json[ "worktree" ], "worktree should be recorded in session"
		assert_equal "session-wt", json[ "worktree" ][ "name" ]
		assert_equal "session-wt", json[ "worktree" ][ "branch" ]

		wt_path = File.join( repo_root, ".claude", "worktrees", "session-wt" )
		cleanup_worktree( repo_root, wt_path )
		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree_done! side effect ---

	def test_worktree_done_clears_session_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "done-wt" )

		reset_output( runtime )
		runtime.worktree_done!( name: "done-wt" )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		refute json.key?( "worktree" ), "worktree should be cleared after done"

		wt_path = File.join( repo_root, ".claude", "worktrees", "done-wt" )
		cleanup_worktree( repo_root, wt_path )
		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- human output formatting ---

	def test_session_human_shows_worktree_and_pr
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session,
			worktree: { name: "feat-1", branch: "feat-1" },
			pr: { number: 99, url: "https://github.com/test/repo/pull/99" }
		)

		reset_output( runtime )
		runtime.session!
		output = output_string( runtime )
		assert_includes output, "Worktree: feat-1"
		assert_includes output, "PR: #99"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def cleanup_worktree( repo_root, wt_path, force: false )
		args = [ "git", "-C", repo_root, "worktree", "remove" ]
		args << "--force" if force
		args << wt_path
		system( *args, out: File::NULL, err: File::NULL )
	end

	def cleanup_session( repo_root )
		basename = File.basename( repo_root )
		short_hash = Digest::SHA256.hexdigest( repo_root )[ 0, 8 ]
		session_file = File.join( Dir.home, ".carson", "sessions", "#{basename}-#{short_hash}.json" )
		File.delete( session_file ) if File.exist?( session_file )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@out ).string
	end

	def reset_output( runtime )
		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind
	end
end
