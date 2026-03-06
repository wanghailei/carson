require_relative "test_helper"
require "open3"

class RuntimeWorktreeLifecycleTest < Minitest::Test
	include CarsonTestSupport

	# --- worktree create ---

	def test_worktree_create_creates_worktree_and_branch
		runtime, repo_root = build_runtime
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "test-feature" )
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "test-feature" )
		assert Dir.exist?( wt_path ), "Worktree directory should exist"

		# Branch should exist.
		_, _, success, = Open3.capture3( "git", "branch", "--list", "test-feature", chdir: repo_root )
		branch_output, = Open3.capture3( "git", "branch", "--list", "test-feature", chdir: repo_root )
		assert_includes branch_output, "test-feature"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_prints_path_and_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "my-work" )
		output = output_string( runtime )
		assert_includes output, "Worktree created: my-work"
		assert_includes output, "Branch: my-work"

		wt_path = File.join( repo_root, ".claude", "worktrees", "my-work" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_refuses_duplicate_name
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "dupe" )
		result = runtime.worktree_create!( name: "dupe" )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "already exists"

		wt_path = File.join( repo_root, ".claude", "worktrees", "dupe" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree done ---

	def test_worktree_done_succeeds_on_clean_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "clean-work" )

		result = runtime.worktree_done!( name: "clean-work" )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "Worktree done: clean-work"

		# Worktree should still exist (deferred deletion).
		wt_path = File.join( repo_root, ".claude", "worktrees", "clean-work" )
		assert Dir.exist?( wt_path ), "Worktree should persist after done"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_blocks_on_uncommitted_changes
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "dirty-work" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "dirty-work" )
		File.write( File.join( wt_path, "uncommitted.txt" ), "dirty" )

		result = runtime.worktree_done!( name: "dirty-work" )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "uncommitted changes"

		cleanup_worktree( repo_root, wt_path, force: true )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_errors_on_missing_name
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_done!( name: nil )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "missing worktree name"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_errors_on_unregistered_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_done!( name: "nonexistent" )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "not a registered worktree"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- JSON output tests ---

	def test_worktree_create_json_success
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "json-feat", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "worktree create", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal "json-feat", json[ "name" ]
		assert_equal "json-feat", json[ "branch" ]
		assert json[ "path" ], "should include path"
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-feat" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_json_duplicate_error_with_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "json-dupe" )

		# Reset output buffer for second call.
		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind

		result = runtime.worktree_create!( name: "json-dupe", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "error", json[ "status" ]
		assert_includes json[ "error" ], "already exists"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_ERROR, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-dupe" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_json_success
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "json-done" )

		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind

		result = runtime.worktree_done!( name: "json-done", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "worktree done", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal "json-done", json[ "name" ]
		assert json[ "next_step" ], "should include next_step"
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-done" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_json_dirty_blocks_with_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "json-dirty" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-dirty" )
		File.write( File.join( wt_path, "uncommitted.txt" ), "dirty" )

		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind

		result = runtime.worktree_done!( name: "json-dirty", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "error" ], "uncommitted"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_BLOCK, result

		cleanup_worktree( repo_root, wt_path, force: true )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_json_missing_name_error_with_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_done!( name: nil, json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "error", json[ "status" ]
		assert_includes json[ "error" ], "missing worktree name"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_ERROR, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree done push guard ---

	def test_worktree_done_blocks_when_branch_never_pushed
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "unpushed-branch" )

		# Make a commit so the branch has unique work that hasn't been pushed.
		wt_path = File.join( repo_root, ".claude", "worktrees", "unpushed-branch" )
		File.write( File.join( wt_path, "work.txt" ), "local-only work" )
		system( "git", "-C", wt_path, "add", "work.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", wt_path, "commit", "-m", "local work", out: File::NULL, err: File::NULL )

		# No remote configured, so the branch has never been pushed.
		reset_output( runtime )
		result = runtime.worktree_done!( name: "unpushed-branch", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "error" ], "not been pushed"
		assert json[ "recovery" ], "should include push recovery command"
		assert_includes json[ "recovery" ], "push"
		assert_equal Carson::Runtime::EXIT_BLOCK, result

		cleanup_worktree( repo_root, wt_path, force: true )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_done_allows_empty_branch_without_remote
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "empty-branch" )

		# No commits made, no remote — branch has no unique work, so done is safe.
		reset_output( runtime )
		result = runtime.worktree_done!( name: "empty-branch" )
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "empty-branch" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree create excludes .claude/ from git status ---

	def test_worktree_create_adds_claude_dir_to_git_exclude
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "exclude-test" )

		exclude_path = File.join( repo_root, ".git", "info", "exclude" )
		assert File.exist?( exclude_path ), ".git/info/exclude should exist"
		exclude_content = File.read( exclude_path )
		assert_includes exclude_content, ".claude/", ".claude/ should be in git exclude"

		# Verify git status does not show .claude/ as untracked.
		status_output, = Open3.capture3( "git", "status", "--porcelain", chdir: repo_root )
		refute_includes status_output, ".claude/", "git status should not show .claude/"

		wt_path = File.join( repo_root, ".claude", "worktrees", "exclude-test" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_does_not_duplicate_exclude_entry
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		# Create two worktrees — .claude/ should appear in exclude only once.
		runtime.worktree_create!( name: "first-wt" )
		runtime.worktree_create!( name: "second-wt" )

		exclude_path = File.join( repo_root, ".git", "info", "exclude" )
		exclude_content = File.read( exclude_path )
		matches = exclude_content.lines.count { |line| line.strip == ".claude/" }
		assert_equal 1, matches, ".claude/ should appear exactly once in exclude"

		wt1 = File.join( repo_root, ".claude", "worktrees", "first-wt" )
		wt2 = File.join( repo_root, ".claude", "worktrees", "second-wt" )
		cleanup_worktree( repo_root, wt1 )
		cleanup_worktree( repo_root, wt2 )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- CWD safety ---

	def test_worktree_remove_blocks_when_cwd_inside_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "cwd-trap" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "cwd-trap" )

		# Simulate the caller's shell being inside the worktree.
		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( wt_path )
		result = runtime.worktree_remove!( worktree_path: "cwd-trap", json_output: true )
		Dir.chdir( original_dir )

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "error" ], "current working directory"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_BLOCK, result

		# Worktree should still exist — removal was blocked.
		assert Dir.exist?( wt_path ), "Worktree should NOT be removed"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_remove_succeeds_when_cwd_outside
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "safe-remove" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "safe-remove" )

		# CWD is the repo root (outside the worktree) — should succeed.
		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( repo_root )
		result = runtime.worktree_remove!( worktree_path: "safe-remove" )
		Dir.chdir( original_dir )

		assert_equal Carson::Runtime::EXIT_OK, result
		refute Dir.exist?( wt_path ), "Worktree should be removed"

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

	def reset_output( runtime )
		runtime.instance_variable_get( :@out ).truncate( 0 )
		runtime.instance_variable_get( :@out ).rewind
	end

	def cleanup_worktree( repo_root, wt_path, force: false )
		args = [ "git", "-C", repo_root, "worktree", "remove" ]
		args << "--force" if force
		args << wt_path
		system( *args, out: File::NULL, err: File::NULL )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@out ).string
	end
end
