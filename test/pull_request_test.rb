# Tests for Carson::PullRequest domain object.
require_relative "test_helper"

class PullRequestTest < Minitest::Test
	include CarsonTestSupport

	# --- find_open ---

	def test_find_open_returns_instance_for_open_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "open_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_instance_of Carson::PullRequest, pr
		assert_equal 42, pr.number
		assert_equal "OPEN", pr.state
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_find_open_returns_nil_for_merged_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "merged_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_nil pr
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_find_open_returns_nil_when_no_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "no_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_nil pr
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- create! ---

	def test_create_returns_instance
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "create_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.create!( branch: "feature/my-work", runtime: runtime )

		assert_instance_of Carson::PullRequest, pr
		assert_equal 99, pr.number
		assert_equal "OPEN", pr.state
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_create_raises_on_failure
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "create_pr_fail" )
		init_git_repo( repo_root )

		error = assert_raises( Carson::PullRequest::Error ) do
			Carson::PullRequest.create!( branch: "feature/bad", runtime: runtime )
		end
		refute_nil error.message
		refute_nil error.recovery
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- default_title ---

	def test_default_title_humanises_branch_name
		assert_equal "Feature: add deliver command", Carson::PullRequest.default_title( branch: "feature/add-deliver-command" )
	end

	def test_default_title_capitalises_first_word
		assert_equal "Docs update", Carson::PullRequest.default_title( branch: "docs-update" )
	end

	# --- merge! ---

	def test_merge_returns_self
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "merge_ok" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "https://github.com/mock/repo/pull/42", state: "OPEN", runtime: runtime )
		result = pr.merge!( method: "squash" )

		assert_same pr, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_raises_on_failure
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "merge_fail" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "https://github.com/mock/repo/pull/42", state: "OPEN", runtime: runtime )
		error = assert_raises( Carson::PullRequest::Error ) do
			pr.merge!( method: "squash" )
		end
		refute_nil error.message
		refute_nil error.recovery
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- ci_status ---

	def test_ci_status_pass
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_pass" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "", state: "OPEN", runtime: runtime )
		assert_equal :pass, pr.ci_status
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_ci_status_fail
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_fail" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "", state: "OPEN", runtime: runtime )
		assert_equal :fail, pr.ci_status
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_ci_status_none_when_no_checks
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_none" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "", state: "OPEN", runtime: runtime )
		assert_equal :none, pr.ci_status
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- review_decision ---

	def test_review_decision_approved
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "review_approved" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "", state: "OPEN", runtime: runtime )
		assert_equal :approved, pr.review_decision
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_review_decision_changes_requested
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "review_changes_requested" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.new( number: 42, url: "", state: "OPEN", runtime: runtime )
		assert_equal :changes_requested, pr.review_decision
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", "git@github.com:owner/repo.git", out: File::NULL, err: File::NULL )
	end

	def build_runtime_with_mock_gh( scenario: "default" )
		repo_root = Dir.mktmpdir( "carson-pr-test", carson_tmp_root )
		output = StringIO.new
		error = StringIO.new

		mock_bin = File.join( repo_root, ".mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		mock_gh = File.join( mock_bin, "gh" )
		File.write( mock_gh, mock_gh_script( scenario: scenario ) )
		File.chmod( 0o755, mock_gh )

		original_path = ENV[ "PATH" ]
		ENV[ "PATH" ] = "#{mock_bin}:#{original_path}"

		runtime = Carson::Runtime.new( repo_root: repo_root, tool_root: repo_root, output: output, error: error, verbose: false )

		[ runtime, repo_root ]
	end

	def destroy_runtime_repo( repo_root: )
		mock_bin = File.join( repo_root, ".mock-bin" )
		if ENV[ "PATH" ]&.include?( mock_bin )
			ENV[ "PATH" ] = ENV[ "PATH" ].split( ":" ).reject { |p| p == mock_bin }.join( ":" )
		end
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
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

			# pr view — used by find_open and for_branch.
			if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
				# reviewDecision query (instance review_decision).
				if echo "$*" | grep -q "reviewDecision"; then
					if [[ "$scenario" == "review_approved" ]]; then
						echo '{"reviewDecision":"APPROVED"}'
						exit 0
					fi
					if [[ "$scenario" == "review_changes_requested" ]]; then
						echo '{"reviewDecision":"CHANGES_REQUESTED"}'
						exit 0
					fi
					echo '{"reviewDecision":""}'
					exit 0
				fi
				# open_pr scenario.
				if [[ "$scenario" == "open_pr" ]]; then
					echo '{"number":42,"url":"https://github.com/mock/repo/pull/42","state":"OPEN"}'
					exit 0
				fi
				# merged_pr scenario — for_branch returns it, find_open returns nil.
				if [[ "$scenario" == "merged_pr" ]]; then
					echo '{"number":42,"url":"https://github.com/mock/repo/pull/42","state":"MERGED"}'
					exit 0
				fi
				# ci scenarios — open PR.
				if [[ "$scenario" == "ci_pass" || "$scenario" == "ci_fail" || "$scenario" == "ci_none" ]]; then
					echo '{"number":42,"url":"https://github.com/mock/repo/pull/42","state":"OPEN"}'
					exit 0
				fi
				# no PR.
				echo "no pull requests found" >&2
				exit 1
			fi

			# pr create.
			if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
				if [[ "$scenario" == "create_pr_fail" ]]; then
					echo "pr create error" >&2
					exit 1
				fi
				echo "https://github.com/mock/repo/pull/99"
				exit 0
			fi

			# pr checks — CI status.
			if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
				if [[ "$scenario" == "ci_pass" ]]; then
					echo '[{"name":"CI","bucket":"pass"}]'
					exit 0
				fi
				if [[ "$scenario" == "ci_fail" ]]; then
					echo '[{"name":"CI","bucket":"fail"}]'
					exit 0
				fi
				echo '[]'
				exit 0
			fi

			# pr merge.
			if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
				if [[ "$scenario" == "merge_fail" ]]; then
					echo "merge error" >&2
					exit 1
				fi
				echo "merged"
				exit 0
			fi

			# api — REST endpoint for open_for_branch? and merged_for_branch.
			if [[ "${1:-}" == "api" ]]; then
				if [[ "$scenario" == "api_open_pr" ]]; then
					echo '[{"number":42}]'
					exit 0
				fi
				if [[ "$scenario" == "api_no_open_pr" ]]; then
					echo '[]'
					exit 0
				fi
				if [[ "$scenario" == "merged_for_branch_match" ]]; then
					cat <<'JSON'
			[{"number":55,"html_url":"https://github.com/owner/repo/pull/55","head":{"ref":"feature/done","sha":"abc123"},"base":{"ref":"main"},"merged_at":"2024-01-15T10:00:00Z"}]
			JSON
					exit 0
				fi
				echo '[]'
				exit 0
			fi

			echo "unsupported gh: $*" >&2
			exit 1
		BASH
			.gsub( "__SCENARIO__", scenario )
	end
end
