# CWD-inside-workbench: assess_removal auto-chdirs and returns ok.
require_relative "../../test_helper"

class WorkbenchAutoChangeDirTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-workbench-auto-cd-test", carson_tmp_root )
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

	def test_assess_removal_auto_chdirs_when_cwd_inside
		@warehouse.build_workbench!( name: "cwd-inside" )
		workbench = @warehouse.workbench_named( "cwd-inside" )

		original_dir = Dir.pwd
		Dir.chdir( workbench.path )
		assessment = @warehouse.assess_removal( workbench )
		Dir.chdir( original_dir )

		assert_equal :ok, assessment[ :status ],
			"assess_removal should auto-chdir and return ok, not block"
	end
end
