# Tests for CLI argument parsing and command dispatch.
require_relative "test_helper"

class CLITest < Minitest::Test
	class FakeRuntime
		attr_reader :calls, :messages

		def initialize
			@calls = []
			@messages = []
		end

		def setup!( cli_choices: {} )
			@calls << [ :setup, cli_choices ]
			Carson::Runtime::EXIT_OK
		end

		def audit!( json_output: false )
			@calls << [ :audit, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def refresh_all!
			@calls << :refresh_all
			Carson::Runtime::EXIT_OK
		end

		def template_check!
			@calls << :template_check
			Carson::Runtime::EXIT_OK
		end

		def template_apply!( push_prep: false )
			@calls << :template_apply
			Carson::Runtime::EXIT_OK
		end

		def review_gate!
			@calls << :review_gate
			Carson::Runtime::EXIT_OK
		end

		def review_sweep!
			@calls << :review_sweep
			Carson::Runtime::EXIT_OK
		end

		def status!( json_output: false )
			@calls << [ :status, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def worktree_create!( name:, json_output: false )
			@calls << [ :worktree_create, { name: name, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def worktree_remove!( worktree_path:, force: false, json_output: false )
			@calls << [ :worktree_remove, { worktree_path: worktree_path, force: force, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def worktree_list!( json_output: false )
			@calls << [ :worktree_list, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def sync!( json_output: false )
			@calls << [ :sync, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def deliver!( title: nil, body_file: nil, commit_message: nil, json_output: false )
			@calls << [ :deliver, { title: title, body_file: body_file, commit_message: commit_message, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def recover!( check_name:, json_output: false )
			@calls << [ :recover, { check_name: check_name, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def abandon!( target:, json_output: false )
			@calls << [ :abandon, { target: target, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def prune!( json_output: false )
			@calls << [ :prune, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep!( json_output: false, dry_run: false )
			@calls << [ :housekeep, { json_output: json_output, dry_run: dry_run } ]
			Carson::Runtime::EXIT_OK
		end

		def list!( json_output: false )
			@calls << [ :list, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def receive!( dry_run: false, json_output: false, loop_seconds: nil )
			@calls << [ :receive, { dry_run: dry_run, json_output: json_output, loop_seconds: loop_seconds } ]
			Carson::Runtime::EXIT_OK
		end

		def onboard!
			@calls << :onboard
			Carson::Runtime::EXIT_OK
		end

		def offboard!
			@calls << :offboard
			Carson::Runtime::EXIT_OK
		end

		def puts_line( message )
			@messages << message
		end
	end

	# --- helpers ---

	# Parses arguments and dispatches to a FakeRuntime, returning the runtime's calls.
	def parse_with_dispatch( arguments )
		runtime = FakeRuntime.new
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: arguments, output: output, error: error )
		Carson::CLI.dispatch( parsed: parsed, runtime: runtime )
		runtime.calls
	end

	# Parses arguments and returns the parsed hash (for testing parse_args directly).
	def parse_args_from( arguments )
		output = StringIO.new
		error = StringIO.new
		Carson::CLI.parse_args( arguments: arguments, output: output, error: error )
	end

	# Parses arguments and returns [parsed_hash, error_string].
	def parse_args_with_error( arguments )
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: arguments, output: output, error: error )
		[ parsed, error.string ]
	end

	# --- bare carson / defaults ---

	def test_parse_args_defaults_to_audit_with_no_arguments
		parsed = parse_args_from( [] )
		assert_equal "audit", parsed.fetch( :command )
	end

	def test_parse_args_help_returns_help_command_and_prints_usage
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "--help" ], output: output, error: error )
		assert_equal :help, parsed.fetch( :command )
		assert_includes output.string, "Usage: carson"
	end

	def test_parse_args_version_returns_version_command
		parsed = parse_args_from( [ "--version" ] )
		assert_equal "version", parsed.fetch( :command )
	end

	def test_parse_args_v_flag_remains_version
		parsed = parse_args_from( [ "-v" ] )
		assert_equal "version", parsed.fetch( :command )
	end

	# --- verbose flag ---

	def test_parse_args_verbose_flag_defaults_to_false
		parsed = parse_args_from( [ "audit" ] )
		assert_equal false, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_command
		parsed = parse_args_from( [ "--verbose", "audit" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_after_command
		parsed = parse_args_from( [ "audit", "--verbose" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_no_args_defaults_to_audit
		parsed = parse_args_from( [ "--verbose" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	# --- dispatch helpers ---

	def test_dispatch_rejects_unknown_command
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "review:unknown" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_ERROR, status
		assert_includes runtime.messages, "Unknown command: review:unknown"
	end

	def test_dispatch_routes_to_expected_runtime_method
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "template:apply" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :template_apply ], runtime.calls
	end

	# --- portfolio: list ---

	def test_list_dispatches_to_list
		calls = parse_with_dispatch( [ "list" ] )
		assert_equal [ [ :list, { json_output: false } ] ], calls
	end

	def test_list_json_dispatches
		calls = parse_with_dispatch( [ "list", "--json" ] )
		assert_equal [ [ :list, { json_output: true } ] ], calls
	end

	# --- portfolio: refresh ---

	def test_refresh_dispatches_to_refresh_all
		calls = parse_with_dispatch( [ "refresh" ] )
		assert_equal [ :refresh_all ], calls
	end

	def test_parse_args_refresh_returns_refresh_all_command
		parsed = parse_args_from( [ "refresh" ] )
		assert_equal "refresh:all", parsed.fetch( :command )
	end

	def test_dispatch_routes_refresh_all_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "refresh:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :refresh_all ], runtime.calls
	end

	# --- portfolio: onboard ---

	def test_parse_args_onboard_missing_arg
		parsed, error = parse_args_with_error( [ "onboard" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Missing repo path"
	end

	def test_parse_args_onboard_with_path
		parsed = parse_args_from( [ "onboard", "/some/path" ] )
		assert_equal "onboard", parsed.fetch( :command )
		assert_equal "/some/path", parsed.fetch( :repo_root )
	end

	def test_parse_args_onboard_too_many_args
		parsed, error = parse_args_with_error( [ "onboard", "/a", "/b" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Too many arguments for onboard"
	end

	# --- portfolio: offboard ---

	def test_parse_args_offboard_missing_arg
		parsed, error = parse_args_with_error( [ "offboard" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Missing repo path"
	end

	def test_parse_args_offboard_with_path
		parsed = parse_args_from( [ "offboard", "/some/path" ] )
		assert_equal "offboard", parsed.fetch( :command )
		assert_equal "/some/path", parsed.fetch( :repo_root )
	end

	def test_parse_args_offboard_too_many_args
		parsed, error = parse_args_with_error( [ "offboard", "/a", "/b" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Too many arguments for offboard"
	end

	# --- repo from CWD: status ---

	def test_status_from_cwd
		calls = parse_with_dispatch( [ "status" ] )
		assert_equal [ [ :status, { json_output: false } ] ], calls
	end

	def test_parse_args_status_returns_status_command
		parsed = parse_args_from( [ "status" ] )
		assert_equal "status", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_status_with_json_flag
		parsed = parse_args_from( [ "status", "--json" ] )
		assert_equal "status", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_status_rejects_unexpected_arguments
		parsed, error = parse_args_with_error( [ "status", "extra" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Unexpected arguments for status"
	end

	def test_dispatch_routes_status_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "status", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :status, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_status_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "status", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :status, { json_output: true } ] ], runtime.calls
	end

	# --- repo from CWD: audit ---

	def test_audit_from_cwd
		calls = parse_with_dispatch( [ "audit" ] )
		assert_equal [ [ :audit, { json_output: false } ] ], calls
	end

	def test_parse_args_audit_defaults
		parsed = parse_args_from( [ "audit" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_audit_with_json_flag
		parsed = parse_args_from( [ "audit", "--json" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_audit_rejects_unexpected_arguments
		parsed, error = parse_args_with_error( [ "audit", "extra" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Unexpected arguments for audit"
	end

	def test_dispatch_routes_audit_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "audit", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :audit, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_audit_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "audit", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :audit, { json_output: true } ] ], runtime.calls
	end

	def test_parse_args_no_args_defaults_to_audit_with_json_false
		parsed = parse_args_from( [] )
		assert_equal "audit", parsed.fetch( :command )
	end

	# --- explicit repo subject ---

	def test_explicit_repo_status
		parsed = parse_args_from( [ "nexus", "status" ] )
		assert_equal "status", parsed.fetch( :command )
		assert_equal "nexus", parsed.fetch( :repo_subject )
	end

	def test_explicit_repo_audit
		parsed = parse_args_from( [ "nexus", "audit" ] )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal "nexus", parsed.fetch( :repo_subject )
	end

	def test_explicit_repo_sync
		parsed = parse_args_from( [ "nexus", "sync" ] )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal "nexus", parsed.fetch( :repo_subject )
	end

	# --- receive command ---

	def test_receive_dispatches
		calls = parse_with_dispatch( [ "receive" ] )
		assert_equal [ [ :receive, { dry_run: false, json_output: false, loop_seconds: nil } ] ], calls
	end

	def test_receive_dry_run
		calls = parse_with_dispatch( [ "receive", "--dry-run" ] )
		assert_equal [ [ :receive, { dry_run: true, json_output: false, loop_seconds: nil } ] ], calls
	end

	def test_receive_loop
		calls = parse_with_dispatch( [ "receive", "--loop", "300" ] )
		assert_equal [ [ :receive, { dry_run: false, json_output: false, loop_seconds: 300 } ] ], calls
	end

	def test_parse_args_receive_defaults
		parsed = parse_args_from( [ "receive" ] )
		assert_equal "receive", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :dry_run )
		assert_equal false, parsed.fetch( :json )
		assert_nil parsed.fetch( :loop_seconds )
	end

	def test_parse_args_receive_with_json
		parsed = parse_args_from( [ "receive", "--json" ] )
		assert_equal "receive", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_receive_loop_rejects_non_positive_seconds
		parsed, error = parse_args_with_error( [ "receive", "--loop", "0" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "--loop expects a positive integer"
	end

	def test_dispatch_routes_receive_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "receive", dry_run: true, json: true, loop_seconds: 60 }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :receive, { dry_run: true, json_output: true, loop_seconds: 60 } ] ], runtime.calls
	end

	# --- migration errors ---

	def test_legacy_govern_returns_migration_error
		parsed, error = parse_args_with_error( [ "govern" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "carson govern has been replaced"
	end

	def test_legacy_repos_returns_migration_error
		parsed, error = parse_args_with_error( [ "repos" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "carson repos has been replaced"
	end

	def test_legacy_all_flag_returns_migration_error
		parsed, error = parse_args_with_error( [ "status", "--all" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "--all has been removed"
	end

	def test_legacy_repo_refresh_returns_migration_error
		parsed, error = parse_args_with_error( [ "nexus", "refresh" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "portfolio command"
	end

	# --- reserved word / ambiguity ---

	def test_command_wins_ambiguity
		# If someone has a repo named "status", ["status"] still parses as the status command.
		parsed = parse_args_from( [ "status" ] )
		assert_equal "status", parsed.fetch( :command )
		refute parsed.key?( :repo_subject )
	end

	# --- setup CLI flag tests ---

	def test_parse_args_setup_with_no_flags_returns_empty_cli_choices
		parsed = parse_args_from( [ "setup" ] )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal( {}, parsed.fetch( :cli_choices ) )
	end

	def test_parse_args_setup_with_remote_flag
		parsed = parse_args_from( [ "setup", "--remote", "github" ] )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "github", parsed.fetch( :cli_choices )[ "git.remote" ]
	end

	def test_parse_args_setup_with_main_branch_flag
		parsed = parse_args_from( [ "setup", "--main-branch", "develop" ] )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "develop", parsed.fetch( :cli_choices )[ "git.main_branch" ]
	end

	def test_parse_args_setup_with_workflow_flag
		parsed = parse_args_from( [ "setup", "--workflow", "trunk" ] )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "trunk", parsed.fetch( :cli_choices )[ "workflow.style" ]
	end

	def test_parse_args_setup_rejects_merge_flag
		parsed = parse_args_from( [ "setup", "--merge", "squash" ] )
		assert_equal :invalid, parsed.fetch( :command )
	end

	def test_parse_args_setup_with_canonical_flag
		parsed = parse_args_from( [ "setup", "--canonical", "/tmp/my-templates" ] )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "/tmp/my-templates", parsed.fetch( :cli_choices )[ "lint.canonical" ]
	end

	def test_parse_args_setup_with_all_flags
		parsed = parse_args_from( [
			"setup",
			"--remote", "github",
			"--main-branch", "main",
			"--workflow", "branch",
			"--canonical", "/tmp/templates"
		] )
		assert_equal "setup", parsed.fetch( :command )
		choices = parsed.fetch( :cli_choices )
		assert_equal "github", choices[ "git.remote" ]
		assert_equal "main", choices[ "git.main_branch" ]
		assert_equal "branch", choices[ "workflow.style" ]
		assert_equal "/tmp/templates", choices[ "lint.canonical" ]
	end

	def test_parse_args_setup_with_unexpected_positional_args
		parsed, error = parse_args_with_error( [ "setup", "extra-arg" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Unexpected arguments for setup"
	end

	def test_parse_args_setup_with_unknown_flag
		parsed = parse_args_from( [ "setup", "--unknown-flag" ] )
		assert_equal :invalid, parsed.fetch( :command )
	end

	def test_dispatch_routes_setup_with_cli_choices_to_runtime
		runtime = FakeRuntime.new
		choices = { "git.remote" => "github" }
		status = Carson::CLI.dispatch( parsed: { command: "setup", cli_choices: choices }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :setup, choices ] ], runtime.calls
	end

	def test_dispatch_routes_setup_without_cli_choices_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "setup" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :setup, {} ] ], runtime.calls
	end

	# --- template and review subcommands ---

	def test_parse_args_template_and_review_subcommands
		template = parse_args_from( [ "template", "check" ] )
		review = parse_args_from( [ "review", "gate" ] )

		assert_equal "template:check", template.fetch( :command )
		assert_equal "review:gate", review.fetch( :command )
	end

	def test_dispatch_routes_template_check_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "template:check" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :template_check ], runtime.calls
	end

	def test_dispatch_routes_review_gate_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "review:gate" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :review_gate ], runtime.calls
	end

	def test_dispatch_routes_review_sweep_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "review:sweep" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :review_sweep ], runtime.calls
	end

	# --- worktree CLI tests ---

	def test_parse_args_worktree_create
		parsed = parse_args_from( [ "worktree", "create", "my-feature" ] )
		assert_equal "worktree:create", parsed.fetch( :command )
		assert_equal "my-feature", parsed.fetch( :worktree_name )
	end

	def test_parse_args_worktree_create_missing_name
		parsed, error = parse_args_with_error( [ "worktree", "create" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Missing name"
	end

	def test_parse_args_worktree_create_with_json
		parsed = parse_args_from( [ "worktree", "--json", "create", "my-feature" ] )
		assert_equal "worktree:create", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_worktree_list
		parsed = parse_args_from( [ "worktree", "list", "--json" ] )
		assert_equal "worktree:list", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_worktree_create
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "worktree:create", worktree_name: "feat" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :worktree_create, { name: "feat", json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_worktree_create_with_json
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "worktree:create", worktree_name: "feat", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :worktree_create, { name: "feat", json_output: true } ] ], runtime.calls
	end

	def test_dispatch_routes_worktree_list_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "worktree:list", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :worktree_list, { json_output: true } ] ], runtime.calls
	end

	def test_dispatch_routes_worktree_remove
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "worktree:remove", worktree_path: "feat", force: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :worktree_remove, { worktree_path: "feat", force: false, json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_worktree_remove_with_json
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "worktree:remove", worktree_path: "feat", force: true, json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :worktree_remove, { worktree_path: "feat", force: true, json_output: true } ] ], runtime.calls
	end

	# --- deliver CLI tests ---

	def test_parse_args_deliver_defaults
		parsed = parse_args_from( [ "deliver" ] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
		assert_nil parsed[ :title ]
		assert_nil parsed[ :body_file ]
	end

	def test_parse_args_deliver_with_commit_message
		parsed = parse_args_from( [ "deliver", "--commit", "fix: harden deliver" ] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "fix: harden deliver", parsed.fetch( :commit_message )
	end

	def test_parse_args_deliver_rejects_merge_flag
		parsed, error = parse_args_with_error( [ "deliver", "--merge" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "use carson deliver"
	end

	def test_parse_args_deliver_with_title
		parsed = parse_args_from( [ "deliver", "--title", "My PR" ] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "My PR", parsed.fetch( :title )
	end

	def test_parse_args_deliver_with_body_file
		parsed = parse_args_from( [ "deliver", "--body-file", "/tmp/body.md" ] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "/tmp/body.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_with_all_flags
		parsed = parse_args_from( [
			"deliver", "--title", "Fix bug", "--body-file", "/tmp/b.md"
		] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "Fix bug", parsed.fetch( :title )
		assert_equal "/tmp/b.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_rejects_unexpected_arguments
		parsed, error = parse_args_with_error( [ "deliver", "extra" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Unexpected arguments for deliver"
	end

	def test_parse_args_deliver_with_json_flag
		parsed = parse_args_from( [ "deliver", "--json" ] )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_deliver_rejects_blank_commit_message
		parsed, error = parse_args_with_error( [ "deliver", "--commit", "   " ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "--commit requires a non-empty message"
	end

	def test_dispatch_routes_deliver_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", title: nil, body_file: nil
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { title: nil, body_file: nil, commit_message: nil, json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_deliver_with_title_and_body_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", title: "T", body_file: "/tmp/b.md"
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { title: "T", body_file: "/tmp/b.md", commit_message: nil, json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_deliver_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", json: true, title: nil, body_file: nil
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { title: nil, body_file: nil, commit_message: nil, json_output: true } ] ], runtime.calls
	end

	def test_dispatch_routes_deliver_commit_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch(
			parsed: {
				command: "deliver",
				title: nil,
				body_file: nil,
				commit_message: "fix: harden deliver",
				json: false
			},
			runtime: runtime
		)
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :deliver, { title: nil, body_file: nil, commit_message: "fix: harden deliver", json_output: false } ] ], runtime.calls
	end

	# --- abandon CLI tests ---

	def test_parse_args_abandon_with_json
		parsed = parse_args_from( [ "abandon", "291", "--json" ] )
		assert_equal "abandon", parsed.fetch( :command )
		assert_equal "291", parsed.fetch( :target )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_abandon_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "abandon", target: "feature/stale", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :abandon, { target: "feature/stale", json_output: false } ] ], runtime.calls
	end

	# --- recover CLI tests ---

	def test_parse_args_recover_with_json
		parsed = parse_args_from( [ "recover", "--check", "Carson governance", "--json" ] )
		assert_equal "recover", parsed.fetch( :command )
		assert_equal "Carson governance", parsed.fetch( :check_name )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_recover_requires_check_name
		parsed, error = parse_args_with_error( [ "recover" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "--check requires a non-empty governance check name"
	end

	def test_dispatch_routes_recover_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "recover", check_name: "Carson governance", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :recover, { check_name: "Carson governance", json_output: true } ] ], runtime.calls
	end

	# --- sync CLI tests ---

	def test_parse_args_sync_defaults
		parsed = parse_args_from( [ "sync" ] )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_sync_with_json_flag
		parsed = parse_args_from( [ "sync", "--json" ] )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_sync_rejects_unexpected_arguments
		parsed, error = parse_args_with_error( [ "sync", "extra" ] )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error, "Unexpected arguments for sync"
	end

	def test_dispatch_routes_sync_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "sync", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :sync, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_sync_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "sync", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :sync, { json_output: true } ] ], runtime.calls
	end

	# --- prune CLI tests ---

	def test_parse_args_prune_defaults
		parsed = parse_args_from( [ "prune" ] )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_prune_with_json_flag
		parsed = parse_args_from( [ "prune", "--json" ] )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_prune_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "prune", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :prune, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_prune_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "prune", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :prune, { json_output: true } ] ], runtime.calls
	end

	# --- housekeep CLI tests ---

	def test_parse_args_housekeep_no_args
		parsed = parse_args_from( [ "housekeep" ] )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_json
		parsed = parse_args_from( [ "housekeep", "--json" ] )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_dry_run
		parsed = parse_args_from( [ "housekeep", "--dry-run" ] )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :dry_run )
		assert_equal false, parsed.fetch( :json )
	end

	def test_dispatch_routes_housekeep_current_repo
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep, { json_output: false, dry_run: false } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_with_dry_run
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep", json: true, dry_run: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep, { json_output: true, dry_run: true } ] ], runtime.calls
	end

	# --- ensure_global_artefacts! tests ---

	def test_ensure_global_artefacts_installs_command_guard_when_missing
		tool_root = Dir.mktmpdir( "carson-cli-test" )
		hooks_dir = File.join( tool_root, "hooks" )
		FileUtils.mkdir_p( hooks_dir )
		File.write( File.join( hooks_dir, "command-guard" ), "#!/usr/bin/env bash\nexit 0\n" )

		stable_dir = File.join( Dir.home, ".carson", "hooks" )
		target = File.join( stable_dir, "command-guard" )
		backup = File.read( target ) if File.file?( target )
		FileUtils.rm_f( target )

		Carson::CLI.ensure_global_artefacts!( tool_root: tool_root )

		assert File.file?( target ), "command-guard should be installed"
		assert File.executable?( target ), "command-guard should be executable"
	ensure
		FileUtils.remove_entry( tool_root ) if tool_root
		if backup
			File.write( target, backup )
			FileUtils.chmod( 0o755, target )
		end
	end

	def test_ensure_global_artefacts_skips_when_template_missing
		tool_root = Dir.mktmpdir( "carson-cli-test" )
		# No hooks/command-guard in tool_root — should silently skip.
		Carson::CLI.ensure_global_artefacts!( tool_root: tool_root )
		# No assertion needed — just confirm it does not raise.
	ensure
		FileUtils.remove_entry( tool_root ) if tool_root
	end

	def test_ensure_global_artefacts_skips_when_target_is_identical
		tool_root = Dir.mktmpdir( "carson-cli-test" )
		hooks_dir = File.join( tool_root, "hooks" )
		FileUtils.mkdir_p( hooks_dir )
		source_content = "#!/usr/bin/env bash\nexit 0\n"
		source = File.join( hooks_dir, "command-guard" )
		File.write( source, source_content )

		# Pre-install an identical file at the stable path.
		stable_dir = File.join( Dir.home, ".carson", "hooks" )
		target = File.join( stable_dir, "command-guard" )
		original_mtime = nil
		if File.file?( target )
			# Back up existing file and restore after test.
			backup = File.read( target )
		end
		FileUtils.mkdir_p( stable_dir )
		FileUtils.cp( source, target )
		FileUtils.chmod( 0o755, target )
		original_mtime = File.mtime( target )

		sleep 0.05
		Carson::CLI.ensure_global_artefacts!( tool_root: tool_root )

		assert_equal original_mtime, File.mtime( target ), "identical file should not be overwritten"
	ensure
		FileUtils.remove_entry( tool_root ) if tool_root
		if backup
			File.write( target, backup )
		elsif target && File.file?( target )
			FileUtils.rm_f( target )
		end
	end

	def test_ensure_global_artefacts_updates_when_content_differs
		tool_root = Dir.mktmpdir( "carson-cli-test" )
		hooks_dir = File.join( tool_root, "hooks" )
		FileUtils.mkdir_p( hooks_dir )
		File.write( File.join( hooks_dir, "command-guard" ), "#!/usr/bin/env bash\n# v2\nexit 0\n" )

		stable_dir = File.join( Dir.home, ".carson", "hooks" )
		target = File.join( stable_dir, "command-guard" )
		if File.file?( target )
			backup = File.read( target )
		end
		FileUtils.mkdir_p( stable_dir )
		File.write( target, "#!/usr/bin/env bash\n# v1\nexit 0\n" )

		Carson::CLI.ensure_global_artefacts!( tool_root: tool_root )

		assert_includes File.read( target ), "# v2", "stale command-guard should be updated"
	ensure
		FileUtils.remove_entry( tool_root ) if tool_root
		if backup
			File.write( target, backup )
		elsif target && File.file?( target )
			FileUtils.rm_f( target )
		end
	end

	# --- CWD enforcement ---

	def test_repo_command_outside_governed_repo_returns_error
		Dir.mktmpdir( "carson-cwd-test" ) do |tmp_dir|
			output = StringIO.new
			error = StringIO.new
			exit_code = Carson::CLI.start(
				arguments: [ "status" ],
				repo_root: tmp_dir,
				tool_root: tmp_dir,
				output: output,
				error: error
			)
			assert_equal Carson::Runtime::EXIT_ERROR, exit_code
			assert_includes error.string, "Not inside a governed repo"
			assert_includes error.string, "carson list"
		end
	end

	def test_repo_command_outside_git_repo_returns_error
		Dir.mktmpdir( "carson-non-git-test" ) do |tmp_dir|
			output = StringIO.new
			error = StringIO.new
			exit_code = Carson::CLI.start(
				arguments: [ "audit" ],
				repo_root: tmp_dir,
				tool_root: tmp_dir,
				output: output,
				error: error
			)
			assert_equal Carson::Runtime::EXIT_ERROR, exit_code
			assert_includes error.string, "Not inside a governed repo"
		end
	end

	# --- :invalid early return ---

	def test_invalid_command_returns_error_without_extra_output
		output = StringIO.new
		error = StringIO.new
		exit_code = Carson::CLI.start(
			arguments: [ "onboard" ],
			repo_root: Dir.pwd,
			tool_root: Dir.pwd,
			output: output,
			error: error
		)
		assert_equal Carson::Runtime::EXIT_ERROR, exit_code
		assert_includes error.string, "Missing repo path"
		refute_includes error.string, "Not inside a governed repo"
	end

	def test_legacy_govern_returns_error_without_extra_output
		output = StringIO.new
		error = StringIO.new
		exit_code = Carson::CLI.start(
			arguments: [ "govern" ],
			repo_root: Dir.pwd,
			tool_root: Dir.pwd,
			output: output,
			error: error
		)
		assert_equal Carson::Runtime::EXIT_ERROR, exit_code
		assert_includes error.string, "carson govern has been replaced"
		refute_includes error.string, "Not inside a governed repo"
	end

end
