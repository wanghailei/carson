require_relative "test_helper"
require "open3"

class RuntimeDeliverTest < Minitest::Test
	include CarsonTestSupport

	# --- deliver! basic ---

	def test_deliver_blocks_on_main_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "cannot deliver from main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_pushes_and_creates_pr
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/test-deliver" )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR: #"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_uses_existing_pr_if_found
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "existing_pr" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/existing" )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR: #42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_passes_title_to_pr_create
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/titled" )

		result = runtime.deliver!( title: "Custom Title" )
		assert_equal Carson::Runtime::EXIT_OK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- deliver! with merge ---

	def test_deliver_merge_succeeds_when_ci_passes
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/merge-ready" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Merged PR"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_blocks_when_ci_fails
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_fail" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/ci-failing" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "CI: failing"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_reports_pending_ci
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pending" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/ci-pending" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "CI: pending"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- default_pr_title ---

	def test_default_pr_title_from_branch_name
		runtime, repo_root = build_runtime( verbose: false )
		title = runtime.send( :default_pr_title, branch: "feature/add-deliver-command" )
		assert_equal "Feature: add deliver command", title
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

	def build_runtime_with_mock_gh( verbose: false, scenario: "default" )
		repo_root = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
		out = StringIO.new
		err = StringIO.new

		# Create a mock gh script.
		mock_bin = File.join( repo_root, ".mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		mock_gh = File.join( mock_bin, "gh" )
		File.write( mock_gh, mock_gh_script( scenario: scenario ) )
		File.chmod( 0o755, mock_gh )

		# Prepend mock bin to PATH for the runtime's GitHub adapter.
		original_path = ENV[ "PATH" ]
		ENV[ "PATH" ] = "#{mock_bin}:#{original_path}"

		runtime = Carson::Runtime.new( repo_root: repo_root, tool_root: repo_root, out: out, err: err, verbose: verbose )

		# Restore PATH after runtime creation (the adapter shells out at call time, not at init).
		# We keep mock_bin in PATH for the duration of the test.
		# Cleanup will restore it via destroy_runtime_repo.

		[ runtime, repo_root ]
	end

	def mock_gh_script( scenario: "default" )
		<<~'BASH'
			#!/usr/bin/env bash
			set -euo pipefail

			scenario="__SCENARIO__"

			if [[ "${1:-}" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi

			# pr view — check for existing PR.
			if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
				if [[ "$scenario" == "existing_pr" || "$scenario" == "ci_pass" || "$scenario" == "ci_fail" || "$scenario" == "ci_pending" ]]; then
					cat <<'JSON'
			{"number":42,"url":"https://github.com/mock/repo/pull/42"}
			JSON
					exit 0
				fi
				echo "no pull requests found" >&2
				exit 1
			fi

			# pr create — create a new PR.
			if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
				echo "https://github.com/mock/repo/pull/99"
				exit 0
			fi

			# pr checks — CI status.
			if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
				if [[ "$scenario" == "ci_pass" ]]; then
					cat <<'JSON'
			[{"name":"CI","state":"SUCCESS","conclusion":"SUCCESS"}]
			JSON
					exit 0
				elif [[ "$scenario" == "ci_fail" ]]; then
					cat <<'JSON'
			[{"name":"CI","state":"FAILURE","conclusion":"FAILURE"}]
			JSON
					exit 0
				elif [[ "$scenario" == "ci_pending" ]]; then
					cat <<'JSON'
			[{"name":"CI","state":"PENDING","conclusion":""}]
			JSON
					exit 0
				fi
				echo "[]"
				exit 0
			fi

			# pr merge — merge the PR.
			if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
				echo "merged"
				exit 0
			fi

			# pr list — for status.
			if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
				echo "[]"
				exit 0
			fi

			echo "unsupported gh: $*" >&2
			exit 1
		BASH
			.gsub( "__SCENARIO__", scenario )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@out ).string
	end

	def destroy_runtime_repo( repo_root: )
		# Clean up mock bin PATH entry.
		mock_bin = File.join( repo_root, ".mock-bin" )
		if ENV[ "PATH" ]&.include?( mock_bin )
			ENV[ "PATH" ] = ENV[ "PATH" ].split( ":" ).reject { |p| p == mock_bin }.join( ":" )
		end

		# Clean up remote repo if it exists.
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )

		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
