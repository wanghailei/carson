# Tests for the Tier 1 stream additions beyond deliver/review gate.
require_relative "test_helper"
require "open3"

class RuntimeStreamsTest < Minitest::Test
	include CarsonTestSupport

	def test_realign_blocks_on_main_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		result = runtime.realign!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "cannot realign main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_realign_blocks_on_dirty_tree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/dirty-realign" )
		File.write( File.join( repo_root, "dirty.txt" ), "uncommitted" )

		result = runtime.realign!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "working tree is dirty"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_realign_rebases_and_updates_remote_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/realign-me" )
		system( "git", "-C", repo_root, "push", "-u", "origin", "feature/realign-me", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended feature", out: File::NULL, err: File::NULL )

		result = runtime.realign!
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "Realigned feature/realign-me onto main"

		local_sha = git_output( repo_root, "rev-parse", "feature/realign-me" ).strip
		remote_sha = git_output( repo_root, "ls-remote", @remote_path, "refs/heads/feature/realign-me" ).split.first.to_s
		assert_equal local_sha, remote_sha
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_release_blocks_when_not_on_main
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/release-off-main" )

		result = runtime.release!( version: "1.2.3" )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "release must run from main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_release_blocks_when_working_tree_is_dirty
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		File.write( File.join( repo_root, "dirty.txt" ), "uncommitted" )

		result = runtime.release!( version: "1.2.3" )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "working tree is dirty"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_release_publishes_tag_and_release
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )

		result = runtime.release!( version: "1.2.3" )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "Release published: v1.2.3"

		tag_line = git_output( repo_root, "ls-remote", "--tags", @remote_path, "refs/tags/v1.2.3" )
		refute_empty tag_line.strip
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_track_open_returns_issue_details
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )

		result = runtime.track_open!( title: "Bug", body: "Details", json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "track", json[ "command" ]
		assert_equal "open", json[ "action" ]
		assert_equal "ok", json[ "status" ]
		assert_equal 17, json[ "issue_number" ]
		assert_includes json[ "issue_url" ], "/issues/17"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_track_comment_requires_body
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )

		result = runtime.track_comment!( issue_number: 17 )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "body cannot be blank"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_track_close_and_reopen_issue
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )

		close_result = runtime.track_close!( issue_number: 17 )
		assert_equal Carson::Runtime::EXIT_OK, close_result
		assert_includes output_string( runtime ), "Issue closed"

		reset_output( runtime )
		reopen_result = runtime.track_reopen!( issue_number: 17 )
		assert_equal Carson::Runtime::EXIT_OK, reopen_result
		assert_includes output_string( runtime ), "Issue reopened"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_revert_blocks_for_commit_not_on_main
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/not-on-main" )
		feature_sha = git_output( repo_root, "rev-parse", "HEAD" ).strip

		result = runtime.revert!( target: feature_sha )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "is not on main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_revert_creates_revert_worktree_and_hands_off_to_deliver
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		reverted_sha = create_main_commit( repo_root, file_name: "bugfix.txt", content: "bad change", message: "introduce bug" )

		result = runtime.revert!( target: reverted_sha, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "revert", json[ "command" ]
		assert_equal reverted_sha, json[ "commit" ]
		assert_equal "merged", json[ "status" ]
		assert_equal true, json.dig( "deliver", "merged" )
		assert_equal 99, json.dig( "deliver", "pr_number" )
		assert File.directory?( json.fetch( "worktree_path" ) ), "revert worktree should remain for housekeep"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo_with_remote( repo_root )
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", remote_path, out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
		@remote_path = remote_path
	end

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		feature_file = File.join( repo_root, "feature.txt" )
		File.write( feature_file, "feature work" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "add feature", out: File::NULL, err: File::NULL )
	end

	def create_main_commit( repo_root, file_name:, content:, message: )
		system( "git", "-C", repo_root, "switch", "main", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, file_name ), content )
		system( "git", "-C", repo_root, "add", file_name, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", message, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )
		git_output( repo_root, "rev-parse", "HEAD" ).strip
	end

	def build_runtime_with_mock_gh( verbose: false )
		repo_root = Dir.mktmpdir( "carson-stream-test", carson_tmp_root )
		output = StringIO.new
		error = StringIO.new

		mock_bin = File.join( File.dirname( repo_root ), "mock-bin-#{File.basename( repo_root )}" )
		FileUtils.mkdir_p( mock_bin )
		mock_gh = File.join( mock_bin, "gh" )
		File.write( mock_gh, mock_gh_script )
		File.chmod( 0o755, mock_gh )

		ENV[ "PATH" ] = "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
		runtime = Carson::Runtime.new( repo_root: repo_root, tool_root: repo_root, output: output, error: error, verbose: verbose )
		[ runtime, repo_root ]
	end

	def mock_gh_script
		<<~'BASH'
			#!/usr/bin/env bash
			set -euo pipefail

			if [[ "${1:-}" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi

			if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
				cat <<'JSON'
			{"data":{"repository":{"pullRequest":{"number":99,"title":"Mock PR","url":"https://github.com/mock/repo/pull/99","state":"OPEN","updatedAt":"2026-03-12T00:00:00Z","mergedAt":"","closedAt":"","author":{"login":"octocat"},"comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}},"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
			JSON
				exit 0
			fi

			if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
				if echo "$*" | grep -q "reviewDecision"; then
					echo '{"reviewDecision":"APPROVED"}'
					exit 0
				fi
				if [[ "${3:-}" =~ ^[0-9]+$ ]]; then
					echo '{"number":99,"url":"https://github.com/mock/repo/pull/99","state":"OPEN"}'
					exit 0
				fi
				echo "no pull requests found" >&2
				exit 1
			fi

			if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
				echo "https://github.com/mock/repo/pull/99"
				exit 0
			fi

			if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
				echo '[{"name":"CI","bucket":"pass"}]'
				exit 0
			fi

			if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
				echo "merged"
				exit 0
			fi

			if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
				echo "https://github.com/mock/repo/issues/17"
				exit 0
			fi

			if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
				echo "commented"
				exit 0
			fi

			if [[ "${1:-}" == "issue" && ( "${2:-}" == "close" || "${2:-}" == "reopen" ) ]]; then
				echo "${2:-}d"
				exit 0
			fi

			if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
				echo '{"url":"https://github.com/mock/repo/issues/17"}'
				exit 0
			fi

			if [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
				echo "https://github.com/mock/repo/releases/tag/${3:-}"
				exit 0
			fi

			echo "unsupported gh: $*" >&2
			exit 1
		BASH
	end

	def git_output( repo_root, *args )
		stdout, stderr, status = Open3.capture3( "git", "-C", repo_root, *args )
		raise stderr unless status.success?
		stdout
	end

	def reset_output( runtime )
		buffer = runtime.instance_variable_get( :@output )
		buffer.truncate( 0 )
		buffer.rewind
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def destroy_runtime_repo( repo_root: )
		mock_bin = File.join( File.dirname( repo_root ), "mock-bin-#{File.basename( repo_root )}" )
		if ENV[ "PATH" ]&.include?( mock_bin )
			ENV[ "PATH" ] = ENV[ "PATH" ].split( ":" ).reject { |path| path == mock_bin }.join( ":" )
		end
		FileUtils.remove_entry( mock_bin ) if File.directory?( mock_bin )

		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
