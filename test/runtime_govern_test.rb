require_relative "test_helper"

class RuntimeGovernTest < Minitest::Test
	include CarsonTestSupport

	def test_govern_dry_run_reports_no_open_prs
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					echo "[]"
					exit 0
				fi
				if [[ "$1" == "--version" ]]; then
					echo "gh version mock"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "no open PRs"
			end
		end
	end

	def test_govern_dry_run_classifies_ready_pr
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					cat <<'JSON'
				[{"number":1,"title":"Test PR","headRefName":"feature/test","url":"https://github.com/test/repo/pull/1","statusCheckRollup":[{"state":"SUCCESS","conclusion":"SUCCESS"}],"reviewDecision":"APPROVED"}]
				JSON
					exit 0
				fi
				if [[ "$1" == "--version" ]]; then
					echo "gh version mock"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "ready"
				assert_includes output, "would_merge"
			end
		end
	end

	def test_govern_dry_run_classifies_ci_failing_pr
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					cat <<'JSON'
				[{"number":2,"title":"Failing PR","headRefName":"feature/fail","url":"https://github.com/test/repo/pull/2","statusCheckRollup":[{"state":"FAILURE","conclusion":"FAILURE"}],"reviewDecision":"APPROVED"}]
				JSON
					exit 0
				fi
				if [[ "$1" == "--version" ]]; then
					echo "gh version mock"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "ci_failing"
				assert_includes output, "would_dispatch_ci_fix"
			end
		end
	end

	def test_govern_dry_run_classifies_review_blocked_pr
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					cat <<'JSON'
				[{"number":3,"title":"Review blocked PR","headRefName":"feature/review","url":"https://github.com/test/repo/pull/3","statusCheckRollup":[{"state":"SUCCESS","conclusion":"SUCCESS"}],"reviewDecision":"CHANGES_REQUESTED"}]
				JSON
					exit 0
				fi
				if [[ "$1" == "--version" ]]; then
					echo "gh version mock"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "review_blocked"
				assert_includes output, "would_dispatch_review_fix"
			end
		end
	end

	def test_govern_json_output
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					echo "[]"
					exit 0
				fi
				if [[ "$1" == "--version" ]]; then
					echo "gh version mock"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.govern!( dry_run: true, json_output: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "\"cycle_at\""
				assert_includes output, "\"dry_run\": true"
			end
		end
	end

	def test_housekeep_calls_sync_and_prune
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			remote_repo = File.join( tmp_dir, "remote.git" )
			work_repo = File.join( tmp_dir, "work" )
			system( "git", "init", "--bare", remote_repo, out: File::NULL, err: File::NULL )
			system( "git", "clone", remote_repo, work_repo, out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "switch", "-c", "main", out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "remote", "rename", "origin", "github", out: File::NULL, err: File::NULL )
			File.write( File.join( work_repo, "README.md" ), "test\n" )
			system( "git", "-C", work_repo, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", work_repo, "push", "-u", "github", "main", out: File::NULL, err: File::NULL )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => ""
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: work_repo,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.housekeep!
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "Housekeep"
				assert_includes output, "in sync"
			end
		end
	end

	def test_cli_parses_govern_dry_run
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "govern", "--dry-run" ], out: out, err: err )
		assert_equal "govern", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :dry_run )
		assert_equal false, parsed.fetch( :json )
	end

	def test_cli_parses_govern_json
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "govern", "--json" ], out: out, err: err )
		assert_equal "govern", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :dry_run )
		assert_equal true, parsed.fetch( :json )
	end

	def test_cli_parses_govern_combined_flags
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "govern", "--dry-run", "--json" ], out: out, err: err )
		assert_equal "govern", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :dry_run )
		assert_equal true, parsed.fetch( :json )
	end

	def test_cli_parses_housekeep
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep" ], out: out, err: err )
		assert_equal "housekeep", parsed.fetch( :command )
	end

	def test_cli_dispatches_govern
		runtime = Object.new
		def runtime.govern!( dry_run:, json_output: )
			@govern_args = { dry_run: dry_run, json_output: json_output }
			Carson::Runtime::EXIT_OK
		end
		def runtime.govern_args
			@govern_args
		end
		def runtime.puts_line( msg ); end
		status = Carson::CLI.dispatch(
			parsed: { command: "govern", dry_run: true, json: false },
			runtime: runtime
		)
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal( { dry_run: true, json_output: false }, runtime.govern_args )
	end

	def test_cli_dispatches_housekeep
		runtime = Object.new
		def runtime.housekeep!
			Carson::Runtime::EXIT_OK
		end
		def runtime.puts_line( msg ); end
		status = Carson::CLI.dispatch( parsed: { command: "housekeep" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
	end

	def test_config_govern_defaults
		with_env( "CARSON_CONFIG_FILE" => "" ) do
			c = Carson::Config.load( repo_root: "." )
			assert_equal [], c.govern_repos
			assert_equal true, c.govern_merge_authority
			assert_equal "merge", c.govern_merge_method
			assert_equal "auto", c.govern_agent_provider
		end
	end

	def test_config_govern_env_overrides
		with_env(
			"CARSON_CONFIG_FILE" => "",
			"CARSON_GOVERN_REPOS" => "~/Dev/a,~/Dev/b",
			"CARSON_GOVERN_MERGE_AUTHORITY" => "true",
			"CARSON_GOVERN_MERGE_METHOD" => "squash",
			"CARSON_GOVERN_AGENT_PROVIDER" => "codex"
		) do
			c = Carson::Config.load( repo_root: "." )
			assert_equal 2, c.govern_repos.length
			assert_equal true, c.govern_merge_authority
			assert_equal "squash", c.govern_merge_method
			assert_equal "codex", c.govern_agent_provider
		end
	end

	def test_config_govern_invalid_merge_method
		with_env( "CARSON_CONFIG_FILE" => "", "CARSON_GOVERN_MERGE_METHOD" => "invalid" ) do
			assert_raises Carson::ConfigError do
				Carson::Config.load( repo_root: "." )
			end
		end
	end

	def test_config_govern_invalid_agent_provider
		with_env( "CARSON_CONFIG_FILE" => "", "CARSON_GOVERN_AGENT_PROVIDER" => "invalid" ) do
			assert_raises Carson::ConfigError do
				Carson::Config.load( repo_root: "." )
			end
		end
	end

	def test_dispatch_state_round_trip
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			state_path = File.join( tmp_dir, "state.json" )
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => ""
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)

				state = { "test#1" => { "objective" => "fix_ci", "status" => "running" } }
				runtime.send( :save_dispatch_state, state: state )
				loaded = runtime.send( :load_dispatch_state )
				assert_equal "fix_ci", loaded[ "test#1" ][ "objective" ]
			end
		end
	end

	def test_agent_work_order_data_define
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo",
			branch: "feature/test",
			pr_number: 42,
			objective: "fix_ci",
			context: "CI failed",
			acceptance_checks: "tests pass"
		)
		assert_equal "/tmp/repo", wo.repo
		assert_equal "fix_ci", wo.objective
	end

	def test_agent_result_data_define
		r = Carson::Adapters::Agent::Result.new(
			status: "done",
			summary: "fixed",
			evidence: "commit abc",
			commit_sha: "abc123"
		)
		assert_equal "done", r.status
		assert_equal "abc123", r.commit_sha
	end

	# --- Prompt module tests ---

	def test_prompt_string_context_backward_compatible
		adapter = Carson::Adapters::Codex.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/thing", pr_number: 1,
			objective: "fix_ci", context: "My PR title",
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		assert_includes prompt, "<pr_title>My PR title</pr_title>"
		refute_includes prompt, "<ci_failure_log"
	end

	def test_prompt_hash_context_with_ci_logs
		adapter = Carson::Adapters::Claude.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/ci", pr_number: 2,
			objective: "fix_ci",
			context: {
				title: "Fix CI",
				ci_logs: "ERROR: test_foo failed",
				ci_run_url: "https://github.com/test/repo/actions/runs/123"
			},
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		assert_includes prompt, "<pr_title>Fix CI</pr_title>"
		assert_includes prompt, "<ci_failure_log"
		assert_includes prompt, "ERROR: test_foo failed"
		assert_includes prompt, "runs/123"
	end

	def test_prompt_hash_context_with_review_findings
		adapter = Carson::Adapters::Codex.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/review", pr_number: 3,
			objective: "address_review",
			context: {
				title: "Address review",
				review_findings: [
					{ kind: "unresolved_thread", url: "https://github.com/test/repo/pull/3#discussion_r1", body: "Please fix naming" }
				]
			},
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		assert_includes prompt, "<review_finding"
		assert_includes prompt, "Please fix naming"
	end

	def test_prompt_hash_context_with_prior_attempt
		adapter = Carson::Adapters::Codex.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/ci", pr_number: 4,
			objective: "fix_ci",
			context: {
				title: "Fix CI again",
				ci_logs: "ERROR: still broken",
				ci_run_url: "https://github.com/test/repo/actions/runs/456",
				prior_attempt: { summary: "first attempt failed", dispatched_at: "2025-01-01T00:00:00Z" }
			},
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		assert_includes prompt, "<previous_attempt"
		assert_includes prompt, "first attempt failed"
	end

	def test_prompt_empty_hash_context_degrades_gracefully
		adapter = Carson::Adapters::Codex.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/ci", pr_number: 5,
			objective: "fix_ci", context: {},
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		assert_includes prompt, "investigate locally"
	end

	def test_prompt_sanitizes_xml_in_context
		adapter = Carson::Adapters::Codex.new( repo_root: "/tmp/repo" )
		wo = Carson::Adapters::Agent::WorkOrder.new(
			repo: "/tmp/repo", branch: "fix/ci", pr_number: 6,
			objective: "fix_ci", context: "<script>alert(1)</script>",
			acceptance_checks: nil
		)
		prompt = adapter.send( :build_prompt, work_order: wo )
		refute_includes prompt, "<script>"
	end

	# --- Log truncation tests ---

	def test_truncate_log_short_text_unchanged
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				result = rt.send( :truncate_log, text: "short" )
				assert_equal "short", result
			end
		end
	end

	def test_truncate_log_long_text_keeps_tail
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				long_text = "x" * 10_000 + "TAIL_MARKER"
				result = rt.send( :truncate_log, text: long_text )
				assert_equal 8_000, result.length
				assert_includes result, "TAIL_MARKER"
			end
		end
	end

	# --- CI evidence tests ---

	def test_ci_evidence_gathers_logs
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "run" && "$2" == "list" ]]; then
					echo '[{"databaseId":999,"url":"https://github.com/test/repo/actions/runs/999"}]'
					exit 0
				fi
				if [[ "$1" == "run" && "$2" == "view" ]]; then
					echo "ERROR: test_something failed at line 42"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "", "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				pr = { "headRefName" => "fix/ci", "number" => 1 }
				result = rt.send( :ci_evidence, pr: pr, repo_path: repo_root )
				assert_equal "https://github.com/test/repo/actions/runs/999", result[ :ci_run_url ]
				assert_includes result[ :ci_logs ], "test_something failed"
			end
		end
	end

	def test_ci_evidence_returns_empty_on_no_failures
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "run" && "$2" == "list" ]]; then
					echo '[]'
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "", "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				pr = { "headRefName" => "fix/ci", "number" => 1 }
				result = rt.send( :ci_evidence, pr: pr, repo_path: repo_root )
				assert_equal( {}, result )
			end
		end
	end

	# --- Prior attempt tests ---

	def test_prior_attempt_returns_info_on_failed_dispatch
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				state = { "repo#1" => { "status" => "failed", "summary" => "codex crashed", "dispatched_at" => "2025-01-01T00:00:00Z" } }
				rt.send( :save_dispatch_state, state: state )
				pr = { "number" => 1 }
				result = rt.send( :prior_attempt, pr: pr, repo_path: repo_root )
				assert_equal "codex crashed", result[ :summary ]
				assert_equal "2025-01-01T00:00:00Z", result[ :dispatched_at ]
			end
		end
	end

	def test_prior_attempt_returns_nil_on_done_dispatch
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				state = { "repo#1" => { "status" => "done", "summary" => "fixed", "dispatched_at" => "2025-01-01T00:00:00Z" } }
				rt.send( :save_dispatch_state, state: state )
				pr = { "number" => 1 }
				result = rt.send( :prior_attempt, pr: pr, repo_path: repo_root )
				assert_nil result
			end
		end
	end

	# --- Check wait tests ---

	def test_check_wait_pending_within_window_skipped
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			# PR with pending checks, recently updated
			pr_json = [
				{
					"number" => 10,
					"title" => "Pending PR",
					"headRefName" => "feature/pending",
					"url" => "https://github.com/test/repo/pull/10",
					"statusCheckRollup" => [ { "state" => "PENDING", "conclusion" => "" } ],
					"reviewDecision" => "APPROVED",
					"updatedAt" => Time.now.utc.iso8601
				}
			]
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					cat <<'JSON'
				#{JSON.generate( pr_json )}
				JSON
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_GOVERN_CHECK_WAIT" => "300",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: out, err: StringIO.new
				)
				status = rt.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "pending"
				assert_includes output, "skip"
			end
		end
	end

	def test_check_wait_pending_past_window_classified_as_failing
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			# PR with pending checks, updated long ago
			pr_json = [
				{
					"number" => 11,
					"title" => "Old pending PR",
					"headRefName" => "feature/old-pending",
					"url" => "https://github.com/test/repo/pull/11",
					"statusCheckRollup" => [ { "state" => "PENDING", "conclusion" => "" } ],
					"reviewDecision" => "APPROVED",
					"updatedAt" => ( Time.now.utc - 600 ).iso8601
				}
			]
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "pr" && "$2" == "list" ]]; then
					cat <<'JSON'
				#{JSON.generate( pr_json )}
				JSON
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_GOVERN_CHECK_WAIT" => "30",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: out, err: StringIO.new
				)
				status = rt.govern!( dry_run: true )
				assert_equal Carson::Runtime::EXIT_OK, status
				output = out.string
				assert_includes output, "ci_failing"
				assert_includes output, "would_dispatch_ci_fix"
			end
		end
	end

	# --- Config check_wait tests ---

	def test_config_govern_check_wait_default
		with_env( "CARSON_CONFIG_FILE" => "" ) do
			c = Carson::Config.load( repo_root: "." )
			assert_equal 30, c.govern_check_wait
		end
	end

	def test_config_govern_check_wait_env_override
		with_env( "CARSON_CONFIG_FILE" => "", "CARSON_GOVERN_CHECK_WAIT" => "120" ) do
			c = Carson::Config.load( repo_root: "." )
			assert_equal 120, c.govern_check_wait
		end
	end

	# --- Evidence integration test ---

	def test_evidence_builds_hash_for_fix_ci
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				if [[ "$1" == "run" && "$2" == "list" ]]; then
					echo '[{"databaseId":100,"url":"https://github.com/test/repo/actions/runs/100"}]'
					exit 0
				fi
				if [[ "$1" == "run" && "$2" == "view" ]]; then
					echo "Build failed: undefined method foo"
					exit 0
				fi
				echo "unsupported: $*" >&2
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "", "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				pr = { "title" => "Fix the thing", "headRefName" => "fix/thing", "number" => 42 }
				ctx = rt.send( :evidence, pr: pr, repo_path: repo_root, objective: "fix_ci" )
				assert_kind_of Hash, ctx
				assert_equal "Fix the thing", ctx[ :title ]
				assert_includes ctx[ :ci_logs ], "undefined method foo"
				assert_equal "https://github.com/test/repo/actions/runs/100", ctx[ :ci_run_url ]
			end
		end
	end

	def test_evidence_degrades_gracefully_on_failure
		Dir.mktmpdir( "carson-govern-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			# gh always fails
			File.write( File.join( mock_bin, "gh" ), <<~BASH )
				#!/usr/bin/env bash
				exit 1
			BASH
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "", "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				rt = Carson::Runtime.new(
					repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
					out: StringIO.new, err: StringIO.new
				)
				pr = { "title" => "My PR", "headRefName" => "fix/x", "number" => 1 }
				ctx = rt.send( :evidence, pr: pr, repo_path: repo_root, objective: "fix_ci" )
				assert_kind_of Hash, ctx
				assert_equal "My PR", ctx[ :title ]
			end
		end
	end
end
