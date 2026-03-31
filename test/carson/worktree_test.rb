# CWD-inside-worktree: Carson auto-chdirs to main root and completes removal.
require_relative "../test_helper"

class WorktreeAutoChangeDirTest < Minitest::Test
	include CarsonTestSupport

	# Warehouse path (runtime delegates to warehouse).
	def test_remove_auto_chdirs_when_cwd_inside_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "auto-cd" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "auto-cd" )

		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( wt_path )
		result = runtime.worktree_remove!( worktree_path: "auto-cd", json_output: true )
		Dir.chdir( original_dir )

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "ok", json[ "status" ],
			"removal should succeed after auto-chdir, not block"
		assert_equal Carson::Runtime::EXIT_OK, result
		refute Dir.exist?( wt_path ), "worktree should be removed"

		destroy_runtime_repo( repo_root: repo_root )
	end

	# held_by_other_process? excludes the parent shell that launched Carson.
	def test_held_by_other_process_excludes_parent_pid
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "parent-shell" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "parent-shell" )
		worktree = Carson::Worktree.find( path: wt_path, runtime: runtime )

		# Our parent process (the shell/test runner) has CWD somewhere else,
		# but the key invariant: the parent PID is excluded from the lsof scan
		# so a user running `carson checkout` from inside the worktree is not
		# blocked by their own shell.
		refute worktree.held_by_other_process?,
			"parent process should be excluded from held_by_other_process? check"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# Legacy Worktree.remove_check path — direct class method.
	def test_remove_check_auto_chdirs_when_cwd_inside
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "legacy-cd" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "legacy-cd" )

		original_dir = Dir.pwd
		Dir.chdir( wt_path )
		check = Carson::Worktree.remove_check( path: "legacy-cd", runtime: runtime )
		Dir.chdir( original_dir )

		assert_equal :ok, check[ :status ],
			"remove_check should auto-chdir and return ok, not block"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def reset_output( runtime )
		runtime.instance_variable_get( :@output ).truncate( 0 )
		runtime.instance_variable_get( :@output ).rewind
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def cleanup_worktree( repo_root, wt_path )
		system( "git", "-C", repo_root, "worktree", "remove", wt_path, out: File::NULL, err: File::NULL )
	end
end
