# Tests for Carson::Remote initialisation and URL parsing.
require_relative "test_helper"

class RemoteTest < Minitest::Test
	include CarsonTestSupport

	def test_parses_ssh_remote_url
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "git@github.com:wanghailei/carson.git", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "origin", remote.name
		assert_equal "wanghailei", remote.owner
		assert_equal "carson", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_parses_https_remote_url
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "https://github.com/wanghailei/carson.git", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "wanghailei", remote.owner
		assert_equal "carson", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_parses_https_without_dot_git
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "https://github.com/owner/repo", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "owner", remote.owner
		assert_equal "repo", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- push! tests ---

	def test_push_success
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_bare_remote( repo_root )
		create_feature_branch( repo_root, "feat/push-test" )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )
		result = remote.push!( branch: "feat/push-test" )

		assert_equal remote, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_push_raises_on_failure
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_bare_remote( repo_root )
		create_feature_branch( repo_root, "feat/push-fail" )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		# Point origin at a non-existent path so push fails.
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "/tmp/no-such-remote.git", out: File::NULL, err: File::NULL )

		error = assert_raises( Carson::Remote::Error ) { remote.push!( branch: "feat/push-fail" ) }
		refute_nil error.message
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_force_push_with_lease_success_after_rebase
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_bare_remote( repo_root )
		create_feature_branch( repo_root, "feat/rebase-test" )

		# Push the branch once so remote has it.
		system( "git", "-C", repo_root, "push", "-u", "origin", "feat/rebase-test", out: File::NULL, err: File::NULL )

		# Amend the commit to simulate a rebase (SHA changes, non-fast-forward).
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended feature", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )
		result = remote.force_push_with_lease!( branch: "feat/rebase-test" )

		assert_equal remote, result
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", "git@github.com:test/test.git", out: File::NULL, err: File::NULL )
	end

	def init_git_repo_with_bare_remote( repo_root )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", remote_path, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), "feature work" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "add feature", out: File::NULL, err: File::NULL )
	end
end
