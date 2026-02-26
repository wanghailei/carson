require_relative "test_helper"

class CLITest < Minitest::Test
	class FakeRuntime
		attr_reader :calls, :messages, :lint_args

		def initialize
			@calls = []
			@messages = []
			@lint_args = nil
		end

		def audit!
			@calls << :audit
			Carson::Runtime::EXIT_OK
		end

		def refresh!
			@calls << :refresh
			Carson::Runtime::EXIT_OK
		end

		def template_check!
			@calls << :template_check
			Carson::Runtime::EXIT_OK
		end

		def template_apply!
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

		def lint_setup!( source:, ref:, force: )
			@calls << :lint_setup
			@lint_args = { source: source, ref: ref, force: force }
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

	def test_parse_args_lint_setup_requires_source
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args( argv: [ "lint", "setup" ], out: out, err: err )
		assert_equal :invalid, parsed.fetch( :command )
		assert_includes err.string, "Missing required --source"
	end

	def test_parse_args_lint_setup_with_options
		out = StringIO.new
		err = StringIO.new
		parsed = Carson::CLI.parse_args(
			argv: [ "lint", "setup", "--source", "https://example.com/repo.git", "--ref", "stable", "--force" ],
			out: out,
			err: err
		)

		assert_equal "lint:setup", parsed.fetch( :command )
		assert_equal "https://example.com/repo.git", parsed.fetch( :source )
		assert_equal "stable", parsed.fetch( :ref )
		assert_equal true, parsed.fetch( :force )
	end

	def test_dispatch_routes_to_expected_runtime_method
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch( parsed: { command: "template:apply" }, runtime: runtime )
		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :template_apply ], runtime.calls
	end

	def test_dispatch_passes_lint_setup_arguments
		runtime = FakeRuntime.new
		status = Carson::CLI.dispatch(
			parsed: {
				command: "lint:setup",
				source: "/tmp/source",
				ref: "main",
				force: true
			},
			runtime: runtime
		)

		assert_equal Carson::Runtime::EXIT_OK, status
		assert_equal [ :lint_setup ], runtime.calls
		assert_equal(
			{
				source: "/tmp/source",
				ref: "main",
				force: true
			},
			runtime.lint_args
		)
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
end
