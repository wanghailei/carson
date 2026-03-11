require_relative "test_helper"

class BranchTest < Minitest::Test
	include CarsonTestSupport

	def test_current_returns_branch_instance
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		branch = Carson::Branch.current( runtime: runtime )

		assert_instance_of Carson::Branch, branch
		assert_equal "main", branch.name
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_current_returns_nil_for_detached_head
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		sha = `git -C #{repo_root} rev-parse HEAD`.strip
		system( "git", "-C", repo_root, "checkout", sha, out: File::NULL, err: File::NULL )

		branch = Carson::Branch.current( runtime: runtime )

		assert_nil branch
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_exists_returns_true_for_existing_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		assert Carson::Branch.exists?( name: "main", runtime: runtime )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_exists_returns_false_for_missing_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		refute Carson::Branch.exists?( name: "nonexistent", runtime: runtime )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_stale_returns_branches_with_gone_upstream
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		system( "git", "-C", repo_root, "checkout", "-b", "stale-branch", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "f.txt" ), "x" )
		system( "git", "-C", repo_root, "add", "f.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "x", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "stale-branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", @remote_path, "branch", "-D", "stale-branch", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "fetch", "--prune", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

		stale = Carson::Branch.stale( remote_name: "origin", runtime: runtime )

		branch_names = stale.map( &:name )
		assert_includes branch_names, "stale-branch"
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

	def init_git_repo_with_remote( repo_root )
		@remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "add", "origin", @remote_path, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def destroy_runtime_repo( repo_root: )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )
		super
	end
end
