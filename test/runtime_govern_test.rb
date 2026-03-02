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
end
