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

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", "git@github.com:test/test.git", out: File::NULL, err: File::NULL )
	end
end
