# Recovery message regression — the CWD-inside-workbench guard must suggest
# `carson checkout`, not the internal `carson worktree remove`.
require_relative "../../test_helper"

class WorkbenchRecoveryMessageTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-workbench-recovery-test", carson_tmp_root )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		@warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
	end

	def teardown
		FileUtils.rm_rf( @tmpdir ) if @tmpdir && Dir.exist?( @tmpdir )
	end

	def test_assess_removal_recovery_suggests_checkout
		@warehouse.build_workbench!( name: "cwd-inside" )
		workbench = @warehouse.workbench_named( "cwd-inside" )

		original_dir = Dir.pwd
		Dir.chdir( workbench.path )
		assessment = @warehouse.assess_removal( workbench )
		Dir.chdir( original_dir )

		assert_equal :block, assessment[ :status ]
		assert_includes assessment[ :recovery ], "carson checkout",
			"recovery must say 'carson checkout', not 'carson worktree remove'"
	end
end
