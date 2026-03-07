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

		def sync!( json_output: false )
			@calls << [ :sync, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def deliver!( merge: false, title: nil, body_file: nil, json_output: false )
			@calls << [ :deliver, { merge: merge, title: title, body_file: body_file, json_output: json_output } ]
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

		def housekeep!( json_output: false )
			@calls << [ :housekeep, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep_target!( target:, json_output: false )
			@calls << [ :housekeep_target, { target: target, json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def housekeep_all!( json_output: false )
			@calls << [ :housekeep_all, { json_output: json_output } ]
			Carson::Runtime::EXIT_OK
		end

		def puts_line( message )
			@messages << message
		end
	end

	def test_parse_args_defaults_to_audit_with_no_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
	end

	def test_parse_args_help_returns_help_command_and_prints_usage
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "--help" ], out: out, err: err )
		assert_equal :help, parsed.fetch( :command )
		assert_includes out.string, "Usage: carson"
	end

	def test_parse_args_version_returns_version_command
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "--version" ], out: out, err: err )
		assert_equal "version", parsed.fetch( :command )
	end

	def test_parse_args_template_and_review_subcommands
		out = StringIO.new
		err = StringIO.new

		template = Carson::CLI.parse_args( argv: [ "template", "check" ], out: out, err: err )
		review = Carson::CLI.parse_args( argv: [ "review", "gate" ], out: out, err: err )

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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "refresh" ], out: out, err: err )
		assert_equal "refresh", parsed.fetch( :command )
		assert_nil parsed.fetch( :repo_root )
	end

	def test_parse_args_refresh_with_path
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "refresh", "/some/path" ], out: out, err: err )
		assert_equal "refresh", parsed.fetch( :command )
		assert_equal "/some/path", parsed.fetch( :repo_root )
	end

	def test_parse_args_refresh_too_many_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "refresh", "/a", "/b" ], out: out, err: err )
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "audit" ], out: out, err: err )
		assert_equal false, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_command
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "--verbose", "audit" ], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_after_command
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "audit", "--verbose" ], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_verbose_flag_with_no_args_defaults_to_audit
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "--verbose" ], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :verbose )
	end

	def test_parse_args_v_flag_remains_version
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "-v" ], out: out, err: err )
		assert_equal "version", parsed.fetch( :command )
	end

	# --- refresh --all tests ---

	def test_parse_args_refresh_all_parses_to_refresh_all_command
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "refresh", "--all" ], out: out, err: err )
		assert_equal "refresh:all", parsed.fetch( :command )
	end

	def test_parse_args_refresh_all_with_path_is_invalid
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "refresh", "--all", "/some/path" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "mutually exclusive"
	end

	def test_parse_args_refresh_all_with_verbose_preserves_both_flags
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "--verbose", "refresh", "--all" ], out: out, err: err )
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal( {}, parsed.fetch( :cli_choices ) )
	end

	def test_parse_args_setup_with_remote_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--remote", "github" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "github", parsed.fetch( :cli_choices )[ "git.remote" ]
	end

	def test_parse_args_setup_with_main_branch_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--main-branch", "develop" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "develop", parsed.fetch( :cli_choices )[ "git.main_branch" ]
	end

	def test_parse_args_setup_with_workflow_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--workflow", "trunk" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "trunk", parsed.fetch( :cli_choices )[ "workflow.style" ]
	end

	def test_parse_args_setup_with_merge_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--merge", "squash" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "squash", parsed.fetch( :cli_choices )[ "govern.merge.method" ]
	end

	def test_parse_args_setup_with_canonical_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--canonical", "/tmp/my-templates" ], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		assert_equal "/tmp/my-templates", parsed.fetch( :cli_choices )[ "template.canonical" ]
	end

	def test_parse_args_setup_with_all_flags
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [
			"setup",
			"--remote", "github",
			"--main-branch", "main",
			"--workflow", "branch",
			"--merge", "squash",
			"--canonical", "/tmp/templates"
		], out: out, err: err )
		assert_equal "setup", parsed.fetch( :command )
		choices = parsed.fetch( :cli_choices )
		assert_equal "github", choices[ "git.remote" ]
		assert_equal "main", choices[ "git.main_branch" ]
		assert_equal "branch", choices[ "workflow.style" ]
		assert_equal "squash", choices[ "govern.merge.method" ]
		assert_equal "/tmp/templates", choices[ "template.canonical" ]
	end

	def test_parse_args_setup_with_unexpected_positional_args
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "extra-arg" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for setup"
	end

	def test_parse_args_setup_with_unknown_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "setup", "--unknown-flag" ], out: out, err: err )
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "status" ], out: out, err: err )
		assert_equal "status", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_status_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "status", "--json" ], out: out, err: err )
		assert_equal "status", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_status_rejects_unexpected_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "status", "extra" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for status"
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "worktree", "create", "my-feature" ], out: out, err: err )
		assert_equal "worktree:create", parsed.fetch( :command )
		assert_equal "my-feature", parsed.fetch( :worktree_name )
	end

	def test_parse_args_worktree_create_missing_name
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "worktree", "create" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Missing name"
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "worktree", "--json", "create", "my-feature" ], out: out, err: err )
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver" ], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :merge )
		assert_equal false, parsed.fetch( :json )
		assert_nil parsed[ :title ]
		assert_nil parsed[ :body_file ]
	end

	def test_parse_args_deliver_with_merge_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver", "--merge" ], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :merge )
	end

	def test_parse_args_deliver_with_title
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver", "--title", "My PR" ], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "My PR", parsed.fetch( :title )
	end

	def test_parse_args_deliver_with_body_file
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver", "--body-file", "/tmp/body.md" ], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal "/tmp/body.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_with_all_flags
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [
			"deliver", "--merge", "--title", "Fix bug", "--body-file", "/tmp/b.md"
		], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :merge )
		assert_equal "Fix bug", parsed.fetch( :title )
		assert_equal "/tmp/b.md", parsed.fetch( :body_file )
	end

	def test_parse_args_deliver_rejects_unexpected_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver", "extra" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for deliver"
	end

	def test_parse_args_deliver_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "deliver", "--json" ], out: out, err: err )
		assert_equal "deliver", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_dispatch_routes_deliver_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", merge: false, title: nil, body_file: nil
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { merge: false, title: nil, body_file: nil, json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_deliver_with_merge_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", merge: true, title: "T", body_file: "/tmp/b.md"
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { merge: true, title: "T", body_file: "/tmp/b.md", json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_deliver_with_json_to_runtime
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: {
			command: "deliver", merge: false, json: true, title: nil, body_file: nil
		}, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :deliver, { merge: false, title: nil, body_file: nil, json_output: true } ] ], runtime.calls
	end

	# --- audit CLI tests ---

	def test_parse_args_audit_defaults
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "audit" ], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_audit_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "audit", "--json" ], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_audit_rejects_unexpected_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "audit", "extra" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for audit"
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [], out: out, err: err )
		assert_equal "audit", parsed.fetch( :command )
	end

	# --- repos CLI tests ---

	def test_parse_args_repos_defaults
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "repos" ], out: out, err: err )
		assert_equal "repos", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_repos_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "repos", "--json" ], out: out, err: err )
		assert_equal "repos", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_repos_rejects_unexpected_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "repos", "extra" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for repos"
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "sync" ], out: out, err: err )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_sync_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "sync", "--json" ], out: out, err: err )
		assert_equal "sync", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_sync_rejects_unexpected_arguments
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "sync", "extra" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Unexpected arguments for sync"
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "prune" ], out: out, err: err )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_prune_with_json_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "prune", "--json" ], out: out, err: err )
		assert_equal "prune", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_prune_with_all_flag
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "prune", "--all" ], out: out, err: err )
		assert_equal "prune:all", parsed.fetch( :command )
	end

	def test_parse_args_prune_with_all_and_json_flags
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "prune", "--all", "--json" ], out: out, err: err )
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
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep" ], out: out, err: err )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_target
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "AI" ], out: out, err: err )
		assert_equal "housekeep:target", parsed.fetch( :command )
		assert_equal "AI", parsed.fetch( :target )
	end

	def test_parse_args_housekeep_with_all
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "--all" ], out: out, err: err )
		assert_equal "housekeep:all", parsed.fetch( :command )
		assert_equal false, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_json
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "--json" ], out: out, err: err )
		assert_equal "housekeep", parsed.fetch( :command )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_with_target_and_json
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "--json", "AI" ], out: out, err: err )
		assert_equal "housekeep:target", parsed.fetch( :command )
		assert_equal "AI", parsed.fetch( :target )
		assert_equal true, parsed.fetch( :json )
	end

	def test_parse_args_housekeep_all_with_target_is_invalid
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "--all", "AI" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "mutually exclusive"
	end

	def test_parse_args_housekeep_too_many_args
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "housekeep", "a", "b" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Too many arguments for housekeep"
	end

	def test_dispatch_routes_housekeep_current_repo
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep, { json_output: false } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_targeted
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep:target", target: "AI", json: true }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep_target, { target: "AI", json_output: true } ] ], runtime.calls
	end

	def test_dispatch_routes_housekeep_all
		runtime = FakeRuntime.new
		result = Carson::CLI.dispatch( parsed: { command: "housekeep:all", json: false }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ [ :housekeep_all, { json_output: false } ] ], runtime.calls
	end

end
