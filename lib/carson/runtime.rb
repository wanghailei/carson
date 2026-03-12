# Carson runtime wiring and shared helper layer.
# Centralises command-neutral concerns such as output contracts, path resolution,
# adapter invocation, and report-location policy.
require "fileutils"
require "json"
require "open3"
require "stringio"
require "time"

module Carson
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
		def initialize( repo_root:, tool_root:, output:, error:, in_stream: $stdin, verbose: false )
			@repo_root = repo_root
			@tool_root = tool_root
			@output = output
			@error = error
			@in = in_stream
			@verbose = verbose
			@config = Config.load( repo_root: repo_root )
			@git_adapter = Adapters::Git.new( repo_root: repo_root )
			@github_adapter = Adapters::GitHub.new( repo_root: repo_root )
			@template_sync_result = nil
		end

		attr_reader :template_sync_result

	private

		attr_reader :repo_root, :tool_root, :output, :error, :in, :config, :git_adapter, :github_adapter

		# Returns true when full diagnostic output is enabled via --verbose.
		def verbose?
			@verbose
		end

		# Prints a line only when verbose mode is active.
		def puts_verbose( message )
			puts_line( message ) if verbose?
		end

		# Runs a block with all output captured (suppressed from the user).
		# Returns the block's return value; output is silently discarded.
		def with_captured_output
			saved_output, saved_error = @output, @error
			@output = StringIO.new
			@error = StringIO.new
			yield
		ensure
			@output, @error = saved_output, saved_error
		end

		# Returns true when the repository has at least one commit (HEAD exists).
		def head_exists?
			_, _, success, = git_run( "rev-parse", "--verify", "HEAD" )
			success
		end

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
		# Prefixes non-empty lines with the Carson badge (⧓).
		def puts_line( message )
			if message.to_s.strip.empty?
				output.puts ""
			else
				output.puts "#{BADGE} #{message}"
			end
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

		# Resolves report output precedence:
		# 1) ~/.carson/cache when HOME is an absolute path
		# 2) TMPDIR/carson when HOME is invalid and TMPDIR is absolute
		# 3) /tmp/carson as final safety fallback
		def report_dir_path
			home = ENV.fetch( "HOME", "" ).to_s
			return File.join( home, ".carson", "cache" ) if absolute_env_path?( path: home )

			tmpdir = ENV.fetch( "TMPDIR", "" ).to_s
			return File.join( tmpdir, "carson" ) if absolute_env_path?( path: tmpdir )

			"/tmp/carson"
		rescue StandardError
			"/tmp/carson"
		end

		# Treats empty or non-absolute environment paths as invalid.
		def absolute_env_path?( path: )
			text = path.to_s
			!text.empty? && text.start_with?( "/" )
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

		# Temporarily sets an environment variable for the duration of the block.
		# Restores the previous value (or deletes the key) when the block completes.
		def with_env_var( key, value )
			previous = ENV.key?( key ) ? ENV.fetch( key ) : nil
			ENV[ key ] = value
			yield
		ensure
			if previous.nil?
				ENV.delete( key )
			else
				ENV[ key ] = previous
			end
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
			output.print stdout_text unless stdout_text.empty?
			error.print stderr_text unless stderr_text.empty?
			raise "git #{args.join( ' ' )} failed" unless success
		end

		# Captures git stdout and raises on non-zero exit.
		def git_capture!( *args )
			stdout_text, stderr_text, success, = git_run( *args )
			unless success
				error.print stderr_text unless stderr_text.empty?
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

		# --- Batch pending tracking (shared by all --all commands) ---

		# Path to the persistent pending log for batch operations.
		def batch_pending_path
			File.join( report_dir_path, "batch_pending.json" )
		end

		# Reads and parses the pending log. Returns empty hash if missing or corrupt.
		def load_batch_pending
			path = batch_pending_path
			return {} unless File.file?( path )

			JSON.parse( File.read( path ) )
		rescue StandardError
			{}
		end

		# Writes the pending log atomically.
		def save_batch_pending( data )
			path = batch_pending_path
			FileUtils.mkdir_p( File.dirname( path ) )
			temporary_path = "#{path}.tmp"
			File.write( temporary_path, JSON.pretty_generate( data ) )
			File.rename( temporary_path, path )
		end

		# Adds or updates an entry in the pending log, incrementing attempts.
		def record_batch_skip( command:, repo_path:, reason: )
			data = load_batch_pending
			data[ command ] ||= {}
			existing = data[ command ][ repo_path ]
			attempts = existing ? existing.fetch( "attempts", 0 ) + 1 : 1
			data[ command ][ repo_path ] = {
				"skipped_at" => Time.now.utc.iso8601,
				"reason" => reason,
				"attempts" => attempts
			}
			save_batch_pending( data )
		end

		# Removes an entry from the pending log after successful completion.
		def clear_batch_success( command:, repo_path: )
			data = load_batch_pending
			return unless data.key?( command )

			data[ command ].delete( repo_path )
			data.delete( command ) if data[ command ].empty?
			save_batch_pending( data )
		end

		# Returns array of pending repo info hashes for a command.
		def pending_repos_for( command: )
			data = load_batch_pending
			entries = data.fetch( command, {} )
			entries.map do |path, info|
				{
					path: path,
					reason: info.fetch( "reason", "unknown" ),
					skipped_at: info.fetch( "skipped_at", nil ),
					attempts: info.fetch( "attempts", 0 )
				}
			end
		end

		# --- Portfolio helpers (shared by all --all commands) ---

		# Checks whether a governed repo is safe for batch operations.
		# Returns { safe: true/false, reasons: [...] }.
		# Safe means: no active worktrees beyond main, no uncommitted changes.
		# Non-git directories pass through as safe — let the command handle the error.
		def portfolio_repo_safety( repo_path: )
			git = Adapters::Git.new( repo_root: repo_path )

			# Non-git directories pass through — the calling command reports the real error.
			stdout, _, git_ok, = git.run( "rev-parse", "--is-inside-work-tree" )
			return { safe: true, reasons: [] } unless git_ok && stdout.to_s.strip == "true"

			reasons = []

			# Sweep stale worktrees (merged branches) before counting active ones
			# so only genuinely active worktrees block the operation.
			scoped_runtime = build_scoped_runtime( repo_path: repo_path )
			scoped_runtime.sweep_stale_worktrees!
			worktrees = scoped_runtime.worktree_list
			main_root = scoped_runtime.realpath_safe( repo_path )
			active = worktrees.reject { |worktree| worktree.path == main_root }
			if active.any?
				reasons << "#{active.count} active worktree#{active.count == 1 ? '' : 's'}"
			end

			# Uncommitted changes in the main working tree.
			stdout, _, success, = git.run( "status", "--porcelain" )
			if success && !stdout.strip.empty?
				reasons << "uncommitted changes"
			end

			{ safe: reasons.empty?, reasons: reasons }
		rescue StandardError => exception
			{ safe: false, reasons: [ exception.message ] }
		end

		# Creates a scoped Runtime for a governed repo with captured output.
		def build_scoped_runtime( repo_path: )
			buffer = verbose? ? output : StringIO.new
			error_buffer = verbose? ? error : StringIO.new
			Runtime.new( repo_root: repo_path, tool_root: tool_root, output: buffer, error: error_buffer, verbose: verbose? )
		end
	end
end

require_relative "runtime/local"
require_relative "runtime/audit"
require_relative "runtime/housekeep"
require_relative "runtime/repos"
require_relative "runtime/review"
require_relative "runtime/govern"
require_relative "runtime/setup"
require_relative "runtime/status"
require_relative "runtime/deliver"
require_relative "runtime/realign"
require_relative "runtime/release"
require_relative "runtime/revert"
require_relative "runtime/track"

# Infrastructure interface for domain objects.
# Carson::Worktree and future domain objects call these methods
# on a runtime reference — the way ActiveRecord models use a connection.
# Defined private for internal use, exposed here for domain object access.
module Carson
	class Runtime
		public :config, :output, :verbose?, :puts_verbose, :puts_line,
			:git_run, :git_capture!, :main_worktree_root, :realpath_safe,
			:block_if_outsider_fingerprints!, :branch_absorbed_into_main?
	end
end
