require "fileutils"
require "json"
require "time"

module Butler
	class Runtime
		# Shared exit-code contract used by all commands and CI smoke assertions.
		EXIT_OK = 0
		EXIT_ERROR = 1
		EXIT_BLOCK = 2

		REPORT_MD = "pr_report_latest.md".freeze
		REPORT_JSON = "pr_report_latest.json".freeze
		REVIEW_GATE_REPORT_MD = "review_gate_latest.md".freeze
		REVIEW_GATE_REPORT_JSON = "review_gate_latest.json".freeze
		REVIEW_SWEEP_REPORT_MD = "review_sweep_latest.md".freeze
		REVIEW_SWEEP_REPORT_JSON = "review_sweep_latest.json".freeze
		DISPOSITION_TOKENS = %w[accepted rejected deferred].freeze

		# Runtime wiring for repository context, tool paths, and output streams.
		def initialize( repo_root:, tool_root:, out:, err: )
			@repo_root = repo_root
			@tool_root = tool_root
			@out = out
			@err = err
			@config = Config.load( repo_root: repo_root )
			@git_adapter = Adapters::Git.new( repo_root: repo_root, out: out, err: err )
			@github_adapter = Adapters::GitHub.new( repo_root: repo_root )
		end

		private

		attr_reader :repo_root, :tool_root, :out, :err, :config, :git_adapter, :github_adapter

		# Current local branch name.
		def current_branch
			git_capture!( "rev-parse", "--abbrev-ref", "HEAD" ).strip
		end

		# Checks local branch existence before restore attempts in ensure blocks.
		def branch_exists?( branch_name: )
			_, _, success, = git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{branch_name}" )
			success
		end

		# Human-readable plural suffix helper for audit messaging.
		def plural_suffix( count: )
			count.to_i == 1 ? "" : "s"
		end

		# Section heading printer for command output.
		def print_header( title )
			puts_line ""
			puts_line "[#{title}]"
		end

		# Single output funnel to keep messaging style consistent.
		def puts_line( message )
			out.puts message
		end

		# Converts absolute paths into repo-relative output paths.
		def relative_path( absolute_path )
			absolute_path.sub( "#{repo_root}/", "" )
		end

		# Resolves a repo-relative path and blocks traversal outside repository root.
		def resolve_repo_path!( relative_path:, label: )
			path = File.expand_path( relative_path.to_s, repo_root )
			repo_root_prefix = File.join( repo_root, "" )
			raise ConfigError, "#{label} must stay within repository root" unless path.start_with?( repo_root_prefix )
			path
		end

		# Fixed global report output directory for outsider runtime artefacts.
		def report_dir_path
			File.expand_path( "~/.cache/butler" )
		end

		# Soft capability check for GitHub CLI presence.
		def gh_available?
			_, _, success, = gh_run( "--version" )
			success
		end

		# Keeps check output fields stable even when gh returns blanks.
		def normalise_check_entries( entries: )
			Array( entries ).map do |entry|
				{
					workflow: blank_to( value: entry[ "workflow" ], default: "workflow" ),
					name: blank_to( value: entry[ "name" ], default: "check" ),
					state: blank_to( value: entry[ "state" ], default: "UNKNOWN" ),
					link: entry[ "link" ].to_s
				}
			end
		end

		# Coalesces blank strings to explicit defaults.
		def blank_to( value:, default: )
			text = value.to_s.strip
			text.empty? ? default : text
		end

		# Chooses best available error text from gh stderr/stdout.
		def gh_error_text( stdout_text:, stderr_text:, fallback: )
			combined = [ stderr_text.to_s.strip, stdout_text.to_s.strip ].reject( &:empty? ).join( " | " )
			combined.empty? ? fallback : combined
		end

		# Runs gh command and raises with best available stderr/stdout details on failure.
		def gh_system!( *args )
			stdout_text, stderr_text, success, = gh_run( *args )
			raise gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "gh #{args.join( ' ' )} failed" ) unless success
			stdout_text
		end

		# Captures gh output without raising so callers can fall back when host metadata is unavailable.
		def gh_capture_soft( *args )
			stdout_text, stderr_text, success, = gh_run( *args )
			[ stdout_text, stderr_text, success ]
		end

		# Runs git command, streams outputs, and raises on non-zero exit.
		def git_system!( *args )
			stdout_text, stderr_text, success, = git_run( *args )
			out.print stdout_text unless stdout_text.empty?
			err.print stderr_text unless stderr_text.empty?
			raise "git #{args.join( ' ' )} failed" unless success
		end

		# Captures git stdout and raises on non-zero exit.
		def git_capture!( *args )
			stdout_text, stderr_text, success, = git_run( *args )
			unless success
				err.print stderr_text unless stderr_text.empty?
				raise "git #{args.join( ' ' )} failed"
			end
			stdout_text
		end

		# Captures git output without raising so caller can decide behaviour.
		def git_capture_soft( *args )
			stdout_text, stderr_text, success, = git_run( *args )
			[ stdout_text, stderr_text, success ]
		end

		# Low-level git invocation wrapper.
		def git_run( *args )
			git_adapter.run( *args )
		end

		# Low-level gh invocation wrapper.
		def gh_run( *args )
			github_adapter.run( *args )
		end
	end
end

require_relative "runtime/local_ops"
require_relative "runtime/audit_ops"
require_relative "runtime/review_ops"
