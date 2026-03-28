# Recovery message regression — the CWD-inside-worktree guard must suggest
# `carson checkout`, not the internal `carson worktree remove`.
require_relative "../test_helper"

class WorktreeRecoveryMessageTest < Minitest::Test
	include CarsonTestSupport

	def test_cwd_inside_worktree_recovery_suggests_checkout
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "recovery-msg" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "recovery-msg" )

		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( wt_path )
		runtime.worktree_remove!( worktree_path: "recovery-msg", json_output: true )
		Dir.chdir( original_dir )

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "recovery" ], "carson checkout",
			"recovery should say 'carson checkout', not 'carson worktree remove'"

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
