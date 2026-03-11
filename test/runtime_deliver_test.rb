# Tests for the deliver command (push, PR, merge).
require_relative "test_helper"
require "open3"

class RuntimeDeliverTest < Minitest::Test
	include CarsonTestSupport

	# --- deliver! basic ---

	def test_deliver_blocks_on_main_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "cannot deliver from main"
		assert_includes output_string( runtime ), "carson worktree create <name>"
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

	def test_deliver_creates_new_pr_when_previous_pr_merged
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "merged_pr" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/stale-pr" )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		# Should create PR #99 (from pr create mock), not reuse merged PR #42.
		assert_includes output, "PR: #99"
		refute_includes output, "PR: #42"
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

	def test_deliver_merge_prints_next_step
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/next-step" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Next:"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_json_includes_next_step
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/json-next" )

		result = runtime.deliver!( merge: true, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "next_step" ), "JSON should include next_step field"
		assert_kind_of String, json[ "next_step" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_blocks_when_ci_fails
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_fail" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/ci-failing" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "CI: not passing yet"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_succeeds_when_no_ci_checks
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_none" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/no-ci" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "CI: none"
		assert_includes output, "Merged PR"
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

	# --- JSON output ---

	def test_deliver_json_on_main_includes_error_and_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		result = runtime.deliver!( json_output: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "cannot deliver from main", json[ "error" ]
		assert_equal "carson worktree create <name>", json[ "recovery" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_json_includes_pr_number_and_url
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "existing_pr" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/json-test" )

		result = runtime.deliver!( json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal 42, json[ "pr_number" ]
		assert_includes json[ "pr_url" ], "pull/42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_json_merge_includes_ci_and_merged
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/json-merge" )

		result = runtime.deliver!( merge: true, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "pass", json[ "ci" ]
		assert_equal true, json[ "merged" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- deliver! with merge + review gate ---

	def test_deliver_merge_blocks_when_changes_requested
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass_changes_requested" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/review-block" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "review changes requested"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_blocks_when_unresolved_thread_remains
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass_unresolved_thread" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/thread-block" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "review gate blocked"
		assert_includes output, "unresolved review threads remain"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_succeeds_when_risk_comment_is_acknowledged
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass_acknowledged_risk" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/review-acknowledged" )

		result = runtime.deliver!( merge: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Merged PR"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_json_includes_review_field
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/review-json" )

		result = runtime.deliver!( merge: true, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "review" ), "JSON should include review field"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_json_includes_synced_field
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pass" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/sync-json" )

		result = runtime.deliver!( merge: true, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		# synced field should be present after merge (may be true or false depending on test setup).
		assert json.key?( "synced" ), "JSON should include synced field after merge"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- Recovery messages ---

	def test_deliver_main_branch_shows_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		runtime.deliver!
		output = output_string( runtime )
		assert_includes output, "→"
		assert_includes output, "carson worktree create <name>"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_ci_fail_shows_recovery
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_fail" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/ci-fail-recover" )

		runtime.deliver!( merge: true )
		output = output_string( runtime )
		assert_includes output, "→"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_merge_ci_pending_shows_recovery
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "ci_pending" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/ci-pending-recover" )

		runtime.deliver!( merge: true )
		output = output_string( runtime )
		assert_includes output, "→"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- non-fast-forward handling (force-with-lease) ---

	def test_deliver_force_pushes_with_lease_on_non_fast_forward
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/rebased" )

		# Push the branch so the remote has it.
		system( "git", "-C", repo_root, "push", "-u", "origin", "feature/rebased", out: File::NULL, err: File::NULL )

		# Simulate rebase by amending the commit (creates a new SHA, diverging from remote).
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended feature", out: File::NULL, err: File::NULL )

		# deliver should detect non-fast-forward and retry with --force-with-lease.
		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR: #"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_force_pushes_with_lease_on_non_fast_forward_with_open_pr
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false, scenario: "existing_pr" )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/rebased-with-pr" )

		# Push the branch so the remote has it.
		system( "git", "-C", repo_root, "push", "-u", "origin", "feature/rebased-with-pr", out: File::NULL, err: File::NULL )

		# Simulate rebase by amending the commit.
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended feature", out: File::NULL, err: File::NULL )

		# deliver should detect non-fast-forward and retry with --force-with-lease.
		# Same behaviour regardless of PR state.
		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR: #42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_errors_when_force_with_lease_rejected
		# Tests the safety guarantee: --force-with-lease rejects when another actor
		# has pushed to the remote branch since our last fetch. We test
		# force_push_with_lease! directly because git's initial push rejection
		# distinguishes "non-fast-forward" (local diverged) from "fetch first"
		# (remote advanced) — and when both conditions are true, git reports
		# "fetch first", bypassing the non-fast-forward detection path.
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/contested" )

		# Push the branch so the remote has it.
		system( "git", "-C", repo_root, "push", "-u", "origin", "feature/contested", out: File::NULL, err: File::NULL )

		# Simulate another actor pushing to the same branch via a second clone.
		remote_path = @remote_path
		actor_b = File.join( File.dirname( repo_root ), "actor-b-#{File.basename( repo_root )}" )
		system( "git", "clone", remote_path, actor_b, out: File::NULL, err: File::NULL )
		system( "git", "-C", actor_b, "config", "user.email", "b@test", out: File::NULL, err: File::NULL )
		system( "git", "-C", actor_b, "config", "user.name", "B", out: File::NULL, err: File::NULL )
		system( "git", "-C", actor_b, "checkout", "feature/contested", out: File::NULL, err: File::NULL )
		File.write( File.join( actor_b, "b.txt" ), "B was here" )
		system( "git", "-C", actor_b, "add", "b.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", actor_b, "commit", "-m", "B's commit", out: File::NULL, err: File::NULL )
		system( "git", "-C", actor_b, "push", "origin", "feature/contested", out: File::NULL, err: File::NULL )

		# Amend locally — local tracking ref points to the original SHA,
		# but the remote has B's newer commit.
		system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended feature", out: File::NULL, err: File::NULL )

		# Call force_push_with_lease! directly — the lease check will see that
		# the remote ref (B's commit) doesn't match our tracking ref (original SHA).
		result = {}
		exit_code = runtime.send(
			:force_push_with_lease!,
			branch: "feature/contested", remote: "origin", result: result
		)
		assert_equal Carson::Runtime::EXIT_ERROR, exit_code
		assert_includes result[ :error ], "force-with-lease rejected"
		assert_includes result[ :recovery ], "git fetch"

		FileUtils.remove_entry( actor_b ) if File.directory?( actor_b )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- template sync in deliver ---

	def test_deliver_json_output_clean_with_template_sync
		runtime, repo_root = build_runtime_with_mock_gh( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/template-sync" )
		result = runtime.deliver!( json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json_text = output_string( runtime ).strip
		parsed = JSON.parse( json_text )
		assert parsed.is_a?( Hash ), "deliver --json must produce valid JSON"
		refute parsed.key?( "error" ), "template sync should not produce errors"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_pushes_canonical_content_for_drifted_template
		managed_file = ".github/carson.md"
		runtime, repo_root = build_runtime_with_mock_gh(
			verbose: false, managed_files: [ managed_file ]
		)

		# Create the template source under tool_root (= repo_root).
		# template_source_path looks for tool_root/templates/<relative>.
		template_dir = File.join( repo_root, "templates", ".github" )
		FileUtils.mkdir_p( template_dir )
		File.write( File.join( template_dir, "carson.md" ), "canonical content\n" )

		init_git_repo_with_remote( repo_root )

		# Create the managed file with drifted content and commit it on the feature branch.
		create_feature_branch( repo_root, "feature/drift-sync" )
		managed_dir = File.join( repo_root, ".github" )
		FileUtils.mkdir_p( managed_dir )
		File.write( File.join( repo_root, managed_file ), "drifted content\n" )
		system( "git", "-C", repo_root, "add", managed_file, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "add drifted managed file", out: File::NULL, err: File::NULL )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_OK, result

		# The regression: drift must not reach the remote.
		# Inspect the pushed branch in the bare remote to confirm canonical content was pushed.
		remote_content, = Open3.capture2(
			"git", "-C", @remote_path, "show", "feature/drift-sync:#{managed_file}"
		)
		assert_equal "canonical content\n", remote_content,
			"deliver must push canonical content, not drifted content, to the remote"

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

	def build_runtime_with_mock_gh( verbose: false, scenario: "default", managed_files: nil )
		repo_root = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
		output = StringIO.new
		error = StringIO.new

		# Create a mock gh script.
		mock_bin = File.join( repo_root, ".mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		mock_gh = File.join( mock_bin, "gh" )
		File.write( mock_gh, mock_gh_script( scenario: scenario ) )
		File.chmod( 0o755, mock_gh )

		# Prepend mock bin to PATH for the runtime's GitHub adapter.
		original_path = ENV[ "PATH" ]
		ENV[ "PATH" ] = "#{mock_bin}:#{original_path}"
		previous_review_wait = ENV[ "CARSON_REVIEW_WAIT_SECONDS" ]
		previous_review_poll = ENV[ "CARSON_REVIEW_POLL_SECONDS" ]
		previous_review_max_polls = ENV[ "CARSON_REVIEW_MAX_POLLS" ]
		ENV[ "CARSON_REVIEW_WAIT_SECONDS" ] = "0"
		ENV[ "CARSON_REVIEW_POLL_SECONDS" ] = "0"
		ENV[ "CARSON_REVIEW_MAX_POLLS" ] = "2"

			# Override config so template_apply! processes only what the test sets up.
			# Default: a single placeholder file with matching template source so sync succeeds.
			effective_files = managed_files || [ ".github/placeholder.md" ]
			config_file = File.join( repo_root, "test-carson-config.json" )
			File.write( config_file, JSON.generate( { "template" => { "managed_files" => effective_files } } ) )

		# Create matching template sources for default placeholder so template_apply! returns EXIT_OK.
		if managed_files.nil?
			template_dir = File.join( repo_root, "templates", ".github" )
			FileUtils.mkdir_p( template_dir )
			File.write( File.join( template_dir, "placeholder.md" ), "" )
		end

			runtime = with_env( "CARSON_CONFIG_FILE" => config_file ) do
				Carson::Runtime.new( repo_root: repo_root, tool_root: repo_root, output: output, error: error, verbose: verbose )
			end
			ENV[ "CARSON_REVIEW_WAIT_SECONDS" ] = previous_review_wait
			ENV[ "CARSON_REVIEW_POLL_SECONDS" ] = previous_review_poll
			ENV[ "CARSON_REVIEW_MAX_POLLS" ] = previous_review_max_polls

		# Restore PATH after runtime creation (the adapter shells output at call time, not at init).
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

			if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
				printf '%s\n' '__GRAPHQL_PAYLOAD__'
				exit 0
			fi

			# pr view — check for existing PR or review decision.
			if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
				if [[ "$scenario" == "merged_pr" ]]; then
					printf '%s\n' '{"number":42,"url":"https://github.com/mock/repo/pull/42","state":"MERGED"}'
					exit 0
				fi
				if [[ "$scenario" == "existing_pr" || "$scenario" == "ci_pass" || "$scenario" == "ci_fail" || "$scenario" == "ci_pending" || "$scenario" == "ci_pass_changes_requested" || "$scenario" == "ci_pass_unresolved_thread" || "$scenario" == "ci_pass_acknowledged_risk" || "$scenario" == "ci_none" ]]; then
					printf '%s\n' '{"number":42,"url":"https://github.com/mock/repo/pull/42","state":"OPEN"}'
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
				if [[ "$scenario" == "ci_pass" || "$scenario" == "ci_pass_changes_requested" || "$scenario" == "ci_pass_unresolved_thread" || "$scenario" == "ci_pass_acknowledged_risk" ]]; then
					printf '%s\n' '[{"name":"CI","bucket":"pass"}]'
					exit 0
				elif [[ "$scenario" == "ci_fail" ]]; then
					printf '%s\n' '[{"name":"CI","bucket":"fail"}]'
					exit 0
				elif [[ "$scenario" == "ci_pending" ]]; then
					printf '%s\n' '[{"name":"CI","bucket":"pending"}]'
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
			.gsub( "__GRAPHQL_PAYLOAD__", review_gate_graphql_payload( scenario: scenario ) )
	end

	def review_gate_graphql_payload( scenario: )
		case scenario
		when "ci_pass_changes_requested"
			graphql_pull_request_payload(
				reviews: [
					graphql_review_node(
						author: "reviewer",
						state: "CHANGES_REQUESTED",
						body: "Please address this regression risk.",
						url: "https://github.com/mock/repo/pull/42#pullrequestreview-1",
						submitted_at: "2026-03-12T10:00:01Z"
					)
				]
			)
		when "ci_pass_unresolved_thread"
			graphql_pull_request_payload(
				review_threads: [
					graphql_thread_node(
						is_resolved: false,
						comment_url: "https://github.com/mock/repo/pull/42#discussion_r1",
						comment_body: "This still needs a fix.",
						comment_created_at: "2026-03-12T10:00:01Z"
					)
				]
			)
		when "ci_pass_acknowledged_risk"
			graphql_pull_request_payload(
				comments: [
					graphql_comment_node(
						author: "reviewer",
						body: "There is regression risk here.",
						url: "https://github.com/mock/repo/pull/42#issuecomment-risk",
						created_at: "2026-03-12T10:00:01Z"
					),
					graphql_comment_node(
						author: "owner",
						body: "Disposition: accepted https://github.com/mock/repo/pull/42#issuecomment-risk",
						url: "https://github.com/mock/repo/pull/42#issuecomment-ack",
						created_at: "2026-03-12T10:00:02Z"
					)
				]
			)
		else
			graphql_pull_request_payload
		end
	end

	def graphql_pull_request_payload( comments: [], reviews: [], review_threads: [] )
		JSON.pretty_generate(
			{
				"data" => {
					"repository" => {
						"pullRequest" => {
							"number" => 42,
							"title" => "Mock PR",
							"url" => "https://github.com/mock/repo/pull/42",
							"state" => "OPEN",
							"updatedAt" => "2026-03-12T10:00:00Z",
							"mergedAt" => nil,
							"closedAt" => nil,
							"author" => { "login" => "owner" },
							"reviewThreads" => {
								"pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
								"nodes" => review_threads
							},
							"comments" => {
								"pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
								"nodes" => comments
							},
							"reviews" => {
								"pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
								"nodes" => reviews
							}
						}
					}
				}
			}
		)
	end

	def graphql_comment_node( author:, body:, url:, created_at: )
		{
			"author" => { "login" => author },
			"body" => body,
			"url" => url,
			"createdAt" => created_at
		}
	end

	def graphql_review_node( author:, state:, body:, url:, submitted_at: )
		{
			"author" => { "login" => author },
			"state" => state,
			"body" => body,
			"url" => url,
			"submittedAt" => submitted_at
		}
	end

	def graphql_thread_node( is_resolved:, comment_url:, comment_body:, comment_created_at: )
		{
			"isResolved" => is_resolved,
			"isOutdated" => false,
			"comments" => {
				"nodes" => [
					graphql_comment_node(
						author: "reviewer",
						body: comment_body,
						url: comment_url,
						created_at: comment_created_at
					)
				]
			}
		}
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def destroy_runtime_repo( repo_root: )
		# Clean up mock bin PATH entry.
		mock_bin = File.join( repo_root, ".mock-bin" )
		if ENV[ "PATH" ]&.include?( mock_bin )
			ENV[ "PATH" ] = ENV[ "PATH" ].split( ":" ).reject { |path| path == mock_bin }.join( ":" )
		end

		# Clean up remote repo if it exists.
		remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
		FileUtils.remove_entry( remote_path ) if File.directory?( remote_path )

		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
