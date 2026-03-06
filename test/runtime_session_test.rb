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

	def test_session_file_lives_in_repo_slug_directory
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		path = runtime.send( :session_file_path )
		# File is <session_id>.json inside a per-repo directory.
		assert path.end_with?( ".json" )
		assert_includes path, "sessions"
		# Parent directory should include repo basename.
		parent = File.basename( File.dirname( path ) )
		assert_includes parent, File.basename( repo_root )

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- session_id ---

	def test_session_id_includes_pid
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		sid = runtime.send( :session_id )
		assert_includes sid, Process.pid.to_s

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_session_id_is_stable_across_calls
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		id1 = runtime.send( :session_id )
		id2 = runtime.send( :session_id )
		assert_equal id1, id2

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- session_list ---

	def test_session_list_returns_active_sessions
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.send( :update_session, task: "my task" )

		sessions = runtime.session_list
		assert_equal 1, sessions.size
		assert_equal "my task", sessions.first[ :task ]
		assert_equal false, sessions.first[ :stale ]

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_session_list_detects_stale_sessions
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		# Write a session file with a dead PID and old timestamp.
		dir = runtime.send( :session_repo_dir )
		stale_data = {
			"repo" => repo_root,
			"session_id" => "99999-20250101000000",
			"pid" => 99999,
			"task" => "old task",
			"updated_at" => "2025-01-01T00:00:00Z"
		}
		File.write( File.join( dir, "99999-20250101000000.json" ), JSON.pretty_generate( stale_data ) )

		sessions = runtime.session_list
		stale = sessions.find { |s| s[ :session_id ] == "99999-20250101000000" }
		assert stale, "should find stale session"
		assert_equal true, stale[ :stale ]

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

	# --- worktree_remove! side effect ---

	def test_worktree_remove_clears_session_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "remove-wt" )

		reset_output( runtime )
		runtime.worktree_remove!( worktree_path: "remove-wt" )

		reset_output( runtime )
		runtime.session!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		refute json.key?( "worktree" ), "worktree should be cleared after remove"

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree ownership coordination ---

	def test_session_records_session_id_and_pid
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.session!( task: "test", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json[ "session_id" ], "should include session_id"
		assert_includes json[ "session_id" ], Process.pid.to_s

		cleanup_session( repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_records_ownership_in_session
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "owned-wt" )

		# Session should record this worktree.
		sessions = runtime.session_list
		assert_equal 1, sessions.size
		wt = sessions.first[ :worktree ]
		assert wt, "session should have worktree"
		assert_equal "owned-wt", ( wt[ :name ] || wt[ "name" ] )

		wt_path = File.join( repo_root, ".claude", "worktrees", "owned-wt" )
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
		# New per-session directory format.
		session_dir = File.join( Dir.home, ".carson", "sessions", "#{basename}-#{short_hash}" )
		FileUtils.remove_entry( session_dir ) if Dir.exist?( session_dir )
		# Old single-file format (migration).
		old_file = File.join( Dir.home, ".carson", "sessions", "#{basename}-#{short_hash}.json" )
		File.delete( old_file ) if File.exist?( old_file )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@out ).string
	end

	def reset_output( runtime )
		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind
	end
end
