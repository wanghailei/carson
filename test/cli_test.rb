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

		def refresh!
			@calls << :refresh
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

		def abandon!( target:, json_output: false )
			@calls << [ :abandon, { target: target, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def prune!( json_output: false )
			@calls << [ :prune, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def prune_all!
			@calls << :prune_all
			Carson::Runtime::EXIT_OK
		end


		def repos!( json_output: false )
			@calls << [ :repos, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep!( json_output: false, dry_run: false )
			@calls << [ :housekeep, { json_output: json_output, dry_run: dry_run } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep_target!( target:, json_output: false, dry_run: false )
			@calls << [ :housekeep_target, { target: target, json_output: json_output, dry_run: dry_run } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep_all!( json_output: false, dry_run: false )
			@calls << [ :housekeep_all, { json_output: json_output, dry_run: dry_run } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep_loop!( json_output:, dry_run:, loop_seconds: )
			@calls << [ :housekeep_loop, { json_output: json_output, dry_run: dry_run, loop_seconds: loop_seconds } ]
			Carson::Runtime::EXIT_OK
		end

		def template_check_all!
			@calls << :template_check_all
			Carson::Runtime::EXIT_OK
		end

		def audit_all!
			@calls << :audit_all
			Carson::Runtime::EXIT_OK
		end

		def sync_all!
			@calls << :sync_all
			Carson::Runtime::EXIT_OK
		end

		def status_all!( json_output: false )
			@calls << [ :status_all, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def govern!( dry_run: false, json_output: false, loop_seconds: nil )
			@calls << [ :govern, { dry_run: dry_run, json_output: json_output, loop_seconds: loop_seconds } ]
			Carson::Runtime::EXIT_OK
		end

		def puts_line( message )
			@messages << message
		end
	end

	def test_parse_args_defaults_to_audit_with_no_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [], output: output, error: error )
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
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "--version" ], output: output, error: error )
		assert_equal "version", parsed.fetch( :command )
	end

	def test_parse_args_template_and_review_subcommands
		output = StringIO.new
		error = StringIO.new

		template = Carson::CLI.parse_args( arguments: [ "template", "check" ], output: output, error: error )
		review = Carson::CLI.parse_args( arguments: [ "review", "gate" ], output: output, error: error )

		assert_equal "template:check", template.fetch( :command )
		assert_equal "review:gate", review.fetch( :command )
	end

	def test_dispatch_routes_to_expected_runtime_method
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "template:apply" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :template_apply ], runtime.calls
	end

	def test_parse_args_refresh_without_path
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "refresh" ], output: output, error: error )
		assert_equal "refresh", parsed.fetch( :command )
		assert_nil parsed.fetch( :repo_root )
	end

	def test_parse_args_refresh_with_path
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "refresh", "/some/path" ], output: output, error: error )
		assert_equal "refresh", parsed.fetch( :command )
		assert_equal "/some/path", parsed.fetch( :repo_root )
	end

	def test_parse_args_refresh_too_many_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "refresh", "/a", "/b" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
	end

	def test_dispatch_routes_refresh_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "refresh" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :refresh ], runtime.calls
	end

	def test_dispatch_rejects_unknown_command
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "review:unknown" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_ERROR, status
		assert_includes runtime.messages, "Unknown command: review:unknown"
	end

	def test_parse_args_verbose_flag_defaults_to_false
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit" ], output: output, error: error )
		assert_equal false, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_command
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "--verbose", "audit" ], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_after_command
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit", "--verbose" ], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_no_args_defaults_to_audit
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "--verbose" ], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_v_flag_remains_version
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "-v" ], output: output, error: error )
		assert_equal "version", parsed.fetch( :command )
	end

	def test_parse_args_deliver_with_commit_message
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--commit", "fix: harden deliver" ], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "fix: harden deliver", parsed.fetch( :commit_message )
	end

	def test_parse_args_abandon_with_json
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "abandon", "291", "--json" ], output: output, error: error )
		assert_equal "abandon", parsed.fetch( :command )
		assert_equal "291", parsed.fetch( :target )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_worktree_list
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "worktree", "list", "--json" ], output: output, error: error )
		assert_equal "worktree:list", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_worktree_list_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "worktree:list", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :worktree_list, { json_output: true } ] ], runtime.calls
	end

	def test_dispatch_routes_abandon_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "abandon", target: "feature/stale", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ [ :abandon, { target: "feature/stale", json_output: false } ] ], runtime.calls
	end

	def test_parse_args_deliver_rejects_blank_commit_message
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--commit", "   " ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "--commit requires a non-empty message"
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

	# --- refresh --all tests ---

	def test_parse_args_refresh_all_parses_to_refresh_all_command
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "refresh", "--all" ], output: output, error: error )
		assert_equal "refresh:all", parsed.fetch( :command )
	end

	def test_parse_args_refresh_all_with_path_is_invalid
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "refresh", "--all", "/some/path" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "mutually exclusive"
	end

	def test_parse_args_refresh_all_with_verbose_preserves_both_flags
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "--verbose", "refresh", "--all" ], output: output, error: error )
		assert_equal "refresh:all", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_dispatch_routes_refresh_all_to_runtime
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "refresh:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :refresh_all ], runtime.calls
	end

	# --- setup CLI flag tests ---

	def test_parse_args_setup_with_no_flags_returns_empty_cli_choices
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup" ], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal( {}, parsed.fetch( :cli_choices ) )
	end

	def test_parse_args_setup_with_remote_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--remote", "github" ], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "github", parsed.fetch( :cli_choices )[ "git.remote" ]
	end

	def test_parse_args_setup_with_main_branch_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--main-branch", "develop" ], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "develop", parsed.fetch( :cli_choices )[ "git.main_branch" ]
	end

	def test_parse_args_setup_with_workflow_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--workflow", "trunk" ], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "trunk", parsed.fetch( :cli_choices )[ "workflow.style" ]
	end

	def test_parse_args_setup_rejects_merge_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--merge", "squash" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
	end

	def test_parse_args_setup_with_canonical_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--canonical", "/tmp/my-templates" ], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "/tmp/my-templates", parsed.fetch( :cli_choices )[ "lint.canonical" ]
	end

	def test_parse_args_setup_with_all_flags
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [
			"setup",
			"--remote", "github",
			"--main-branch", "main",
			"--workflow", "branch",
			"--canonical", "/tmp/templates"
		], output: output, error: error )
		assert_equal "setup", parsed.fetch( :command )
		choices = parsed.fetch( :cli_choices )
		assert_equal "github", choices[ "git.remote" ]
		assert_equal "main", choices[ "git.main_branch" ]
		assert_equal "branch", choices[ "workflow.style" ]
		assert_equal "/tmp/templates", choices[ "lint.canonical" ]
	end

	def test_parse_args_setup_with_unexpected_positional_args
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "extra-arg" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for setup"
	end

	def test_parse_args_setup_with_unknown_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "setup", "--unknown-flag" ], output: output, error: error )
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

	# --- status CLI tests ---

	def test_parse_args_status_returns_status_command
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "status" ], output: output, error: error )
		assert_equal "status", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_status_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "status", "--json" ], output: output, error: error )
		assert_equal "status", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_status_rejects_unexpected_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "status", "extra" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for status"
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

	# --- worktree create CLI tests ---

	def test_parse_args_worktree_create
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "worktree", "create", "my-feature" ], output: output, error: error )
		assert_equal "worktree:create", parsed.fetch( :command )
		assert_equal "my-feature", parsed.fetch( :worktree_name )
	end

	def test_parse_args_worktree_create_missing_name
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "worktree", "create" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Missing name"
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

	def test_parse_args_worktree_create_with_json
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "worktree", "--json", "create", "my-feature" ], output: output, error: error )
		assert_equal "worktree:create", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
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
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver" ], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
		assert_nil parsed[ :title ]
		assert_nil parsed[ :body_file ]
	end

	def test_parse_args_deliver_rejects_merge_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--merge" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "use carson deliver"
	end

	def test_parse_args_deliver_with_title
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--title", "My PR" ], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "My PR", parsed.fetch( :title )
	end

	def test_parse_args_deliver_with_body_file
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--body-file", "/tmp/body.md" ], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "/tmp/body.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_with_all_flags
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [
			"deliver", "--title", "Fix bug", "--body-file", "/tmp/b.md"
		], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "Fix bug", parsed.fetch( :title )
		assert_equal "/tmp/b.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_rejects_unexpected_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "extra" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for deliver"
	end

	def test_parse_args_deliver_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "deliver", "--json" ], output: output, error: error )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
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

	# --- audit CLI tests ---

	def test_parse_args_audit_defaults
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit" ], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_audit_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit", "--json" ], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_audit_rejects_unexpected_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit", "extra" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for audit"
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
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [], output: output, error: error )
		assert_equal "audit", parsed.fetch( :command )
	end

	# --- repos CLI tests ---

	def test_parse_args_repos_defaults
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "repos" ], output: output, error: error )
		assert_equal "repos", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_repos_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "repos", "--json" ], output: output, error: error )
		assert_equal "repos", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_repos_rejects_unexpected_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "repos", "extra" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for repos"
	end

	def test_dispatch_routes_repos_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "repos", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :repos, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_repos_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "repos", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :repos, { json_output: true } ] ], runtime.calls
	end

	# --- sync CLI tests ---

	def test_parse_args_sync_defaults
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "sync" ], output: output, error: error )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_sync_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "sync", "--json" ], output: output, error: error )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_sync_rejects_unexpected_arguments
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "sync", "extra" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Unexpected arguments for sync"
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
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "prune" ], output: output, error: error )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_prune_with_json_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "prune", "--json" ], output: output, error: error )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_prune_with_all_flag
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "prune", "--all" ], output: output, error: error )
		assert_equal "prune:all", parsed.fetch( :command )
	end

	def test_parse_args_prune_with_all_and_json_flags
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "prune", "--all", "--json" ], output: output, error: error )
		assert_equal "prune:all", parsed.fetch( :command )
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

	def test_dispatch_routes_prune_all_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "prune:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ :prune_all ], runtime.calls
	end

	# --- housekeep CLI tests ---

	def test_parse_args_housekeep_no_args
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep" ], output: output, error: error )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_target
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "AI" ], output: output, error: error )
		assert_equal "housekeep:target", parsed.fetch( :command )
		assert_equal "AI", parsed.fetch( :target )
	end

	def test_parse_args_housekeep_with_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--all" ], output: output, error: error )
		assert_equal "housekeep:all", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_json
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--json" ], output: output, error: error )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_target_and_json
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--json", "AI" ], output: output, error: error )
		assert_equal "housekeep:target", parsed.fetch( :command )
		assert_equal "AI", parsed.fetch( :target )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_all_with_target_is_invalid
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--all", "AI" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "mutually exclusive"
	end

	def test_parse_args_housekeep_too_many_args
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "a", "b" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "Too many arguments for housekeep"
	end

	def test_parse_args_housekeep_dry_run
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--dry-run" ], output: output, error: error )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :dry_run )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_all_dry_run
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--all", "--dry-run" ], output: output, error: error )
		assert_equal "housekeep:all", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :dry_run )
	end

	def test_parse_args_housekeep_all_loop
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--all", "--loop", "300" ], output: output, error: error )
		assert_equal "housekeep:all", parsed.fetch( :command )
		assert_equal 300, parsed.fetch( :loop_seconds )
	end

	def test_parse_args_housekeep_loop_requires_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--loop", "300" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "--loop requires --all"
	end

	def test_parse_args_housekeep_loop_rejects_non_positive_seconds
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "housekeep", "--all", "--loop", "0" ], output: output, error: error )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes error.string, "--loop expects a positive integer"
	end

	def test_dispatch_routes_housekeep_current_repo
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep, { json_output: false, dry_run: false } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_targeted
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep:target", target: "AI", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep_target, { target: "AI", json_output: true, dry_run: false } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_all
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep:all", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep_all, { json_output: false, dry_run: false } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_all_loop
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep:all", json: true, dry_run: true, loop_seconds: 300 }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep_loop, { json_output: true, dry_run: true, loop_seconds: 300 } ] ], runtime.calls
	end

	# --- audit --all CLI tests ---

	def test_parse_args_audit_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "audit", "--all" ], output: output, error: error )
		assert_equal "audit:all", parsed.fetch( :command )
	end

	def test_dispatch_routes_audit_all_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "audit:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ :audit_all ], runtime.calls
	end

	# --- sync --all CLI tests ---

	def test_parse_args_sync_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "sync", "--all" ], output: output, error: error )
		assert_equal "sync:all", parsed.fetch( :command )
	end

	def test_dispatch_routes_sync_all_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "sync:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ :sync_all ], runtime.calls
	end

	# --- status --all CLI tests ---

	def test_parse_args_status_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "status", "--all" ], output: output, error: error )
		assert_equal "status:all", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_status_all_with_json
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "status", "--all", "--json" ], output: output, error: error )
		assert_equal "status:all", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_status_all_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "status:all", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :status_all, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_status_all_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "status:all", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :status_all, { json_output: true } ] ], runtime.calls
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

	# --- template check --all CLI tests ---

	def test_parse_args_template_check_all
		output = StringIO.new
		error = StringIO.new
		parsed = Carson::CLI.parse_args( arguments: [ "template", "check", "--all" ], output: output, error: error )
		assert_equal "template:check:all", parsed.fetch( :command )
	end

	def test_dispatch_routes_template_check_all_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "template:check:all" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ :template_check_all ], runtime.calls
	end

end
