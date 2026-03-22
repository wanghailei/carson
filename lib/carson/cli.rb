# Parses command-line arguments and dispatches to Runtime operations.
require "open3"
require "optparse"

module Carson
	class CLI
		PORTFOLIO_COMMANDS = %w[onboard offboard list refresh version].freeze
		REPO_COMMANDS = %w[deliver receive sync status audit prune housekeep worktree abandon recover review template setup].freeze
		ALL_COMMANDS = ( PORTFOLIO_COMMANDS + REPO_COMMANDS ).freeze

		def self.start( arguments:, repo_root:, tool_root:, output:, error: )
			ensure_global_artefacts!( tool_root: tool_root )

			parsed = parse_args( arguments: arguments, output: output, error: error )
			command = parsed.fetch( :command )
			return Runtime::EXIT_OK if command == :help
			return Runtime::EXIT_ERROR if command == :invalid

			if command == "version"
				output.puts "#{BADGE} #{Carson::VERSION}"
				return Runtime::EXIT_OK
			end

			verbose = parsed.fetch( :verbose, false )

			# Portfolio commands — no repo resolution needed.
			if %w[list refresh:all onboard offboard].include?( command )
				runtime = Runtime.new( repo_root: repo_root, tool_root: tool_root, output: output, error: error, verbose: verbose )
				return dispatch( parsed: parsed, runtime: runtime )
			end

			# Repo commands with an explicit repo subject — resolve it.
			if parsed.key?( :repo_subject )
				config = Config.load( repo_root: repo_root )
				resolved = resolve_repo_target( name: parsed.fetch( :repo_subject ), config: config )
				if resolved.nil?
					error.puts "#{BADGE} Not a governed repo: #{parsed.fetch( :repo_subject )}"
					return Runtime::EXIT_ERROR
				end
				runtime = Runtime.new( repo_root: resolved, tool_root: tool_root, output: output, error: error, verbose: verbose )
				return dispatch( parsed: parsed, runtime: runtime )
			end

			# Repo commands resolved from CWD.
			target_repo_root = parsed.fetch( :repo_root, nil )
			target_repo_root = repo_root if target_repo_root.to_s.strip.empty?
			unless Dir.exist?( target_repo_root )
				error.puts "#{BADGE} Repository path not found: #{target_repo_root}"
				return Runtime::EXIT_ERROR
			end

			config = Config.load( repo_root: target_repo_root )
			resolved = resolve_cwd_repo( repo_root: target_repo_root, config: config )
			unless resolved
				error.puts "#{BADGE} Not inside a governed repo. Use: carson <repo> #{command} or cd into a governed repo."
				error.puts "#{BADGE}   Run carson list to see governed repositories."
				return Runtime::EXIT_ERROR
			end

			runtime = Runtime.new( repo_root: resolved, tool_root: tool_root, output: output, error: error, verbose: verbose )
			dispatch( parsed: parsed, runtime: runtime )
		rescue ConfigError => exception
			error.puts "#{BADGE} Configuration problem: #{exception.message}"
			Runtime::EXIT_ERROR
		rescue StandardError => exception
			error.puts "#{BADGE} #{exception.message}"
			Runtime::EXIT_ERROR
		end

		def self.parse_args( arguments:, output:, error: )
			verbose = arguments.delete( "--verbose" ) ? true : false
			parser = build_parser
			preset = parse_preset_command( arguments: arguments, output: output, parser: parser )
			return preset.merge( verbose: verbose ) unless preset.nil?

			# Pre-scan for legacy grammar before OptionParser can reject tokens.
			legacy = detect_legacy_grammar( arguments: arguments )
			if legacy
				error.puts "#{BADGE} #{legacy}"
				return { command: :invalid, verbose: verbose }
			end

			first = arguments.first

			# Portfolio command as first token.
			if PORTFOLIO_COMMANDS.include?( first )
				arguments.shift
				result = parse_portfolio_command( command: first, arguments: arguments, error: error )
				return result.merge( verbose: verbose )
			end

			# Repo command as first token — resolve from CWD.
			if REPO_COMMANDS.include?( first )
				arguments.shift
				result = parse_repo_command( command: first, arguments: arguments, error: error )
				return result.merge( verbose: verbose )
			end

			# Otherwise: first token is an explicit repo subject, second is the repo command.
			repo_subject = arguments.shift
			repo_command = arguments.shift

			if repo_command.nil? || repo_command.strip.empty?
				error.puts "#{BADGE} Unknown command: #{repo_subject}. Run carson --help for usage."
				return { command: :invalid, verbose: verbose }
			end

			# Catch portfolio commands used with a repo subject.
			if PORTFOLIO_COMMANDS.include?( repo_command ) && !REPO_COMMANDS.include?( repo_command )
				error.puts "#{BADGE} #{repo_command} is a portfolio command. Use: carson #{repo_command}"
				return { command: :invalid, verbose: verbose }
			end

			unless REPO_COMMANDS.include?( repo_command )
				error.puts "#{BADGE} Unknown command: #{repo_command}. Run carson --help for usage."
				return { command: :invalid, verbose: verbose }
			end

			result = parse_repo_command( command: repo_command, arguments: arguments, error: error )
			result.merge( verbose: verbose, repo_subject: repo_subject )
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts parser
			{ command: :invalid }
		end

		def self.build_parser
			OptionParser.new do |parser|
				parser.banner = "Usage: carson <command> [options]\n       carson <repo> <command> [options]"
				parser.separator ""
				parser.separator "Repository governance and workflow automation for coding agents."
				parser.separator ""
				parser.separator "Portfolio commands:"
				parser.separator "    list         List governed repositories"
				parser.separator "    onboard      Register a repository for governance (requires repo path)"
				parser.separator "    offboard     Remove a repository from governance (requires repo path)"
				parser.separator "    refresh      Re-install hooks and configuration (all governed repos)"
				parser.separator "    version      Show Carson version"
				parser.separator ""
				parser.separator "Repository commands (from CWD or with explicit repo):"
				parser.separator "    status       Show repository delivery state"
				parser.separator "    setup        Initialise Carson configuration"
				parser.separator "    audit        Run pre-commit health checks"
				parser.separator "    abandon      Close and clean up abandoned delivery work"
				parser.separator "    sync         Sync local main with remote"
				parser.separator "    deliver      Start autonomous branch delivery"
				parser.separator "    recover      Merge the repair PR for one baseline-red governance check"
				parser.separator "    prune        Remove stale local branches"
				parser.separator "    worktree     Manage isolated coding worktrees"
				parser.separator "    housekeep    Sync, reap worktrees, and prune branches"
				parser.separator "    review       Manage PR review workflow"
				parser.separator "    template     Manage canonical template files"
				parser.separator "    receive      Triage and advance deliveries for one repo"
				parser.separator ""
				parser.separator "Run `carson <command> --help` for details on a specific command."
			end
		end

		def self.parse_preset_command( arguments:, output:, parser: )
			first = arguments.first
			if [ "--help", "-h" ].include?( first )
				output.puts parser
				return { command: :help }
			end
			return { command: "version" } if [ "--version", "-v" ].include?( first )
			return { command: "audit" } if arguments.empty?

			nil
		end

		# Detects legacy grammar patterns and returns a migration message, or nil.
		def self.detect_legacy_grammar( arguments: )
			tokens = arguments.dup

			# Check for --all anywhere.
			if tokens.include?( "--all" )
				return "--all has been removed. Use carson list --json to script batch operations."
			end

			# Check first two tokens for legacy commands.
			first = tokens[0].to_s
			second = tokens[1].to_s

			if first == "govern" || second == "govern"
				return "carson govern has been replaced by carson <repo> receive"
			end

			if first == "repos" || second == "repos"
				return "carson repos has been replaced by carson list"
			end

			nil
		end

		# --- portfolio command routing ---

		def self.parse_portfolio_command( command:, arguments:, error: )
			case command
			when "version"
				{ command: "version" }
			when "list"
				parse_list_command( arguments: arguments, error: error )
			when "onboard"
				parse_onboard_command( arguments: arguments, error: error )
			when "offboard"
				parse_offboard_command( arguments: arguments, error: error )
			when "refresh"
				parse_refresh_command( arguments: arguments, error: error )
			else
				error.puts "#{BADGE} Unknown portfolio command: #{command}"
				{ command: :invalid }
			end
		end

		# --- repo command routing ---

		def self.parse_repo_command( command:, arguments:, error: )
			case command
			when "setup"
				parse_setup_command( arguments: arguments, error: error )
			when "deliver"
				parse_deliver_command( arguments: arguments, error: error )
			when "receive"
				parse_receive_command( arguments: arguments, error: error )
			when "sync"
				parse_sync_command( arguments: arguments, error: error )
			when "status"
				parse_status_command( arguments: arguments, error: error )
			when "audit"
				parse_audit_command( arguments: arguments, error: error )
			when "prune"
				parse_prune_command( arguments: arguments, error: error )
			when "housekeep"
				parse_housekeep_command( arguments: arguments, error: error )
			when "worktree"
				parse_worktree_subcommand( arguments: arguments, error: error )
			when "abandon"
				parse_abandon_command( arguments: arguments, error: error )
			when "recover"
				parse_recover_command( arguments: arguments, error: error )
			when "review"
				parse_review_subcommand( arguments: arguments, error: error )
			when "template"
				parse_template_subcommand( arguments: arguments, error: error )
			else
				error.puts "#{BADGE} Unknown repo command: #{command}"
				{ command: :invalid }
			end
		end

		# --- setup ---

		def self.parse_setup_command( arguments:, error: )
			options = {}
			setup_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson setup [--remote NAME] [--main-branch NAME] [--workflow STYLE] [--canonical PATH]"
				parser.separator ""
				parser.separator "Initialise Carson configuration for the current repository."
				parser.separator "Detects git remote, main branch, and workflow style, then writes .carson.yml."
				parser.separator "Pass flags to override detected values."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--remote NAME", "Git remote name" ) { |value| options[ "git.remote" ] = value }
				parser.on( "--main-branch NAME", "Main branch name" ) { |value| options[ "git.main_branch" ] = value }
				parser.on( "--workflow STYLE", "Workflow style (branch or trunk)" ) { |value| options[ "workflow.style" ] = value }
				parser.on( "--canonical PATH", "Canonical lint policy directory path" ) { |value| options[ "lint.canonical" ] = value }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson setup                            Auto-detect and write config"
				parser.separator "    carson setup --remote github            Use 'github' as the git remote"
			end
			setup_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for setup: #{arguments.join( ' ' )}"
				error.puts setup_parser
				return { command: :invalid }
			end
			{ command: "setup", cli_choices: options }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts setup_parser
			{ command: :invalid }
		end

		# --- onboard / offboard ---

		def self.parse_onboard_command( arguments:, error: )
			onboard_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson onboard <REPO_PATH>"
				parser.separator ""
				parser.separator "Register a repository for Carson governance."
				parser.separator "Detects the remote, installs hooks, applies templates, and runs initial audit."
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson onboard ~/Dev/app   Onboard a specific repository"
			end
			onboard_parser.parse!( arguments )
			if arguments.empty?
				error.puts "#{BADGE} Missing repo path. Use: carson onboard <repo_path>"
				error.puts onboard_parser
				return { command: :invalid }
			end
			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for onboard. Use: carson onboard <repo_path>"
				error.puts onboard_parser
				return { command: :invalid }
			end
			{
				command: "onboard",
				repo_root: File.expand_path( arguments.first )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts onboard_parser
			{ command: :invalid }
		end

		def self.parse_offboard_command( arguments:, error: )
			offboard_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson offboard <REPO_PATH>"
				parser.separator ""
				parser.separator "Remove a repository from Carson governance."
				parser.separator "Unregisters the repo from Carson's portfolio and removes hooks."
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson offboard ~/Dev/app   Offboard a specific repository"
			end
			offboard_parser.parse!( arguments )
			if arguments.empty?
				error.puts "#{BADGE} Missing repo path. Use: carson offboard <repo_path>"
				error.puts offboard_parser
				return { command: :invalid }
			end
			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for offboard. Use: carson offboard <repo_path>"
				error.puts offboard_parser
				return { command: :invalid }
			end
			{
				command: "offboard",
				repo_root: File.expand_path( arguments.first )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts offboard_parser
			{ command: :invalid }
		end

		# --- list ---

		def self.parse_list_command( arguments:, error: )
			options = { json: false }
			list_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson list [--json]"
				parser.separator ""
				parser.separator "List all repositories governed by Carson."
				parser.separator "Shows the portfolio of repos registered via carson onboard."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson list           List governed repositories"
				parser.separator "    carson list --json    Structured output for agent consumption"
			end
			list_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for list: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "list", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts list_parser
			{ command: :invalid }
		end

		# --- refresh ---

		def self.parse_refresh_command( arguments:, error: )
			refresh_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson refresh"
				parser.separator ""
				parser.separator "Re-install Carson hooks and configuration for all governed repositories."
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson refresh    Refresh all governed repos"
			end
			refresh_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for refresh: #{arguments.join( ' ' )}"
				error.puts refresh_parser
				return { command: :invalid }
			end
			{ command: "refresh:all" }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts refresh_parser
			{ command: :invalid }
		end

		# --- receive ---

		def self.parse_receive_command( arguments:, error: )
			options = {
				dry_run: false,
				json: false,
				loop_seconds: nil
			}
			receive_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson <repo> receive [--dry-run] [--json] [--loop SECONDS]"
				parser.separator ""
				parser.separator "Triage and advance deliveries for one repository."
				parser.separator "Scans open PRs, classifies them, and takes action"
				parser.separator "(merge, request review, or report). Runs once by default."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--dry-run", "Run all checks but do not merge or dispatch" ) { options[ :dry_run ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--loop SECONDS", Integer, "Run continuously, sleeping SECONDS between cycles" ) do |seconds|
					error.puts( "#{BADGE} --loop expects a positive integer" ) || ( return { command: :invalid } ) if seconds < 1
					options[ :loop_seconds ] = seconds
				end
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson nexus receive                  Triage deliveries for nexus"
				parser.separator "    carson nexus receive --dry-run        Preview actions without applying them"
				parser.separator "    carson nexus receive --loop 300       Run continuously every 5 minutes"
			end
			receive_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for receive: #{arguments.join( ' ' )}"
				error.puts receive_parser
				return { command: :invalid }
			end
			{
				command: "receive",
				dry_run: options.fetch( :dry_run ),
				json: options.fetch( :json ),
				loop_seconds: options[ :loop_seconds ]
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts receive_parser
			{ command: :invalid }
		end

		# --- prune ---

		def self.parse_prune_command( arguments:, error: )
			options = { json: false }
			prune_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson prune [--json]"
				parser.separator ""
				parser.separator "Remove stale local branches."
				parser.separator "Cleans up branches gone from the remote, orphan branches with merged PRs,"
				parser.separator "and absorbed branches whose content is already on main."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson prune           Clean up stale branches in this repo"
			end
			prune_parser.parse!( arguments )
			{ command: "prune", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts prune_parser
			{ command: :invalid }
		end

		# --- worktree ---

		def self.parse_worktree_subcommand( arguments:, error: )
			options = { json: false, force: false }
			worktree_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson worktree <create|list|remove> <name> [options]"
				parser.separator ""
				parser.separator "Manage isolated worktrees for coding agents."
				parser.separator "Create auto-syncs main before branching. Remove guards against"
				parser.separator "unpushed commits and CWD-inside-worktree by default."
				parser.separator ""
				parser.separator "Subcommands:"
				parser.separator "    create <name>              Create a new worktree with a fresh branch"
				parser.separator "    list                       List registered worktrees with cleanup status"
				parser.separator "    remove <name> [--force]    Remove a worktree (--force skips safety checks)"
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--force", "Skip safety checks on remove" ) { options[ :force ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson worktree create feature-x    Create an isolated worktree"
				parser.separator "    carson worktree list                Show registered worktrees"
				parser.separator "    carson worktree remove feature-x    Remove after work is pushed"
			end
			worktree_parser.parse!( arguments )

			action = arguments.shift
			if action.to_s.strip.empty?
				error.puts "#{BADGE} Missing subcommand for worktree. Use: carson worktree create|remove <name>"
				error.puts worktree_parser
				return { command: :invalid }
			end

			case action
			when "create"
				name = arguments.shift
				if name.to_s.strip.empty?
					error.puts "#{BADGE} Missing name for worktree create. Use: carson worktree create <name>"
					return { command: :invalid }
				end
				{ command: "worktree:create", worktree_name: name, json: options[ :json ] }
			when "list"
				{ command: "worktree:list", json: options[ :json ] }
			when "remove"
				worktree_path = arguments.shift
				if worktree_path.to_s.strip.empty?
					error.puts "#{BADGE} Missing path for worktree remove. Use: carson worktree remove <name-or-path>"
					return { command: :invalid }
				end
				{ command: "worktree:remove", worktree_path: worktree_path, force: options[ :force ], json: options[ :json ] }
			else
				error.puts "#{BADGE} Unknown worktree subcommand: #{action}. Use: carson worktree create|remove <name>"
				{ command: :invalid }
			end
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts worktree_parser
			{ command: :invalid }
		end

		# --- review ---

		def self.parse_review_subcommand( arguments:, error: )
			review_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson review <gate|sweep>"
				parser.separator ""
				parser.separator "Manage PR review workflow."
				parser.separator ""
				parser.separator "Subcommands:"
				parser.separator "    gate     Check if review requirements are met for merge"
				parser.separator "    sweep    Scan and resolve pending review threads"
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson review gate     Check merge readiness"
				parser.separator "    carson review sweep    Resolve pending review threads"
			end
			review_parser.parse!( arguments )

			action = arguments.shift
			if action.to_s.strip.empty?
				error.puts "#{BADGE} Missing subcommand for review. Use: carson review gate|sweep"
				error.puts review_parser
				return { command: :invalid }
			end
			{ command: "review:#{action}" }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts review_parser
			{ command: :invalid }
		end

		# --- template ---

		def self.parse_template_subcommand( arguments:, error: )
			# Handle parent-level help or missing subcommand.
			if arguments.empty? || [ "--help", "-h" ].include?( arguments.first )
				template_parser = OptionParser.new do |parser|
					parser.banner = "Usage: carson template <check|apply> [options]"
					parser.separator ""
					parser.separator "Manage canonical template files (CI workflows, lint configs)."
					parser.separator ""
					parser.separator "Subcommands:"
					parser.separator "    check                  Show template drift without making changes"
					parser.separator "    apply [--push-prep]    Sync templates into the repository"
					parser.separator ""
					parser.separator "Examples:"
					parser.separator "    carson template check    Check for template drift"
					parser.separator "    carson template apply    Apply canonical templates"
				end

				if arguments.empty?
					error.puts "#{BADGE} Missing subcommand for template. Use: carson template check|apply"
					error.puts template_parser
					return { command: :invalid }
				end

				# Let OptionParser handle --help (prints and exits).
				template_parser.parse!( arguments )
				return { command: :help }
			end

			action = arguments.shift
			return { command: "template:#{action}" } unless action == "apply"

			options = { push_prep: false }
			apply_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson template apply [--push-prep]"
				parser.separator ""
				parser.separator "Sync canonical template files (CI workflows, lint configs) into the repository."
				parser.separator "Copies managed files from the configured canonical directory."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--push-prep", "Apply templates and auto-commit any managed file changes (used by pre-push hook)" ) do
					options[ :push_prep ] = true
				end
			end
			apply_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for template apply: #{arguments.join( ' ' )}"
				error.puts apply_parser
				return { command: :invalid }
			end
			{ command: "template:apply", push_prep: options.fetch( :push_prep ) }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts( apply_parser || template_parser )
			{ command: :invalid }
		end

		# --- audit ---

		def self.parse_audit_command( arguments:, error: )
			options = { json: false }
			audit_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson audit [--json]"
				parser.separator ""
				parser.separator "Run pre-commit health checks on the repository."
				parser.separator "Validates hooks, main-branch sync, PR status, and CI baseline."
				parser.separator "Exits with a non-zero status when policy violations are found."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson audit           Check repository health (also the default command)"
				parser.separator "    carson audit --json    Structured output for agent consumption"
			end
			audit_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for audit: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "audit", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts audit_parser
			{ command: :invalid }
		end

		# --- abandon ---

		def self.parse_abandon_command( arguments:, error: )
			options = { json: false }
			abandon_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson abandon <pr-number|pr-url|branch> [--json]"
				parser.separator ""
				parser.separator "Close an abandoned delivery and clean up its worktree and branch when safe."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson abandon 301"
				parser.separator "    carson abandon https://github.com/acme/widgets/pull/301"
				parser.separator "    carson abandon codex/feature-branch"
			end
			abandon_parser.parse!( arguments )
			target = arguments.shift.to_s.strip
			if target.empty? || !arguments.empty?
				error.puts "#{BADGE} Use: carson abandon <pr-number|pr-url|branch>"
				error.puts abandon_parser
				return { command: :invalid }
			end

			{ command: "abandon", target: target, json: options.fetch( :json ) }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts abandon_parser
			{ command: :invalid }
		end

		# --- sync ---

		def self.parse_sync_command( arguments:, error: )
			options = { json: false }
			sync_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson sync [--json]"
				parser.separator ""
				parser.separator "Sync the local main branch with the remote."
				parser.separator "Fetches and fast-forwards main without switching branches."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson sync            Pull latest changes from remote main"
				parser.separator "    carson sync --json     Structured output for agent consumption"
			end
			sync_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for sync: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "sync", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts sync_parser
			{ command: :invalid }
		end

		# --- status ---

		def self.parse_status_command( arguments:, error: )
			options = { json: false }
			status_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson status [--json]"
				parser.separator ""
				parser.separator "Show the current state of the repository."
				parser.separator "Reports branch, worktrees, open PRs, stale branches, and version."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson status           Quick overview of repository state"
				parser.separator "    carson status --json    Structured output for agent consumption"
			end
			status_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for status: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "status", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts status_parser
			{ command: :invalid }
		end

		# --- deliver ---

		def self.parse_deliver_command( arguments:, error: )
			if arguments.include?( "--merge" )
				error.puts "#{BADGE} carson deliver --merge is no longer supported; use carson deliver"
				return { command: :invalid }
			end

			options = { json: false, title: nil, body_file: nil, commit_message: nil }
			deliver_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson deliver [--json] [--title TITLE] [--body-file PATH] [--commit MESSAGE]"
				parser.separator ""
				parser.separator "Push the current branch, create or refresh the pull request, and hand the branch to Carson."
				parser.separator "Use --commit to create one all-dirty delivery commit before Carson pushes and opens the PR."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--title TITLE", "PR title (defaults to branch name)" ) { |value| options[ :title ] = value }
				parser.on( "--body-file PATH", "File containing PR body text" ) { |value| options[ :body_file ] = value }
				parser.on( "--commit MESSAGE", "Commit all dirty user changes before delivery" ) { |value| options[ :commit_message ] = value }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson deliver                               Deliver existing commits"
				parser.separator "    carson deliver --commit \"fix: harden flow\"   Commit dirty changes, then deliver"
			end
			deliver_parser.parse!( arguments )
			if options.fetch( :commit_message, nil ).to_s.strip.empty? && !options.fetch( :commit_message, nil ).nil?
				error.puts "#{BADGE} --commit requires a non-empty message"
				error.puts deliver_parser
				return { command: :invalid }
			end
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for deliver: #{arguments.join( ' ' )}"
				error.puts deliver_parser
				return { command: :invalid }
			end
			{
				command: "deliver",
				json: options.fetch( :json ),
				title: options[ :title ],
				body_file: options[ :body_file ],
				commit_message: options[ :commit_message ]
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts deliver_parser
			{ command: :invalid }
		end

		# --- recover ---

		def self.parse_recover_command( arguments:, error: )
			options = { json: false, check_name: nil }
			recover_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson recover --check NAME [--json]"
				parser.separator ""
				parser.separator "Merge the current repair PR when one governance-owned required check is already red on the default branch."
				parser.separator "Recovery is narrow: Carson verifies the baseline failure, keeps every other gate intact, and records an audit event."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--check NAME", "Name of the governance-owned required check to recover" ) { |value| options[ :check_name ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson recover --check \"Carson governance\""
				parser.separator "    carson recover --check \"Carson governance\" --json"
			end
			recover_parser.parse!( arguments )
			if options.fetch( :check_name, nil ).to_s.strip.empty?
				error.puts "#{BADGE} --check requires a non-empty governance check name"
				error.puts recover_parser
				return { command: :invalid }
			end
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for recover: #{arguments.join( ' ' )}"
				error.puts recover_parser
				return { command: :invalid }
			end

			{
				command: "recover",
				json: options.fetch( :json ),
				check_name: options.fetch( :check_name )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts recover_parser
			{ command: :invalid }
		end

		# --- housekeep ---

		def self.parse_housekeep_command( arguments:, error: )
			options = { json: false, dry_run: false }
			housekeep_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson housekeep [--dry-run] [--json]"
				parser.separator ""
				parser.separator "Run housekeeping: sync main, reap dead worktrees, and prune stale branches."
				parser.separator "Operates on the current repository (or explicit repo via carson <repo> housekeep)."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--dry-run", "Show what would be reaped/deleted without making changes" ) { options[ :dry_run ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson housekeep              Housekeep the current repository"
				parser.separator "    carson housekeep --dry-run    Preview what housekeep would do"
			end
			housekeep_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for housekeep: #{arguments.join( ' ' )}"
				error.puts housekeep_parser
				return { command: :invalid }
			end
			{ command: "housekeep", json: options[ :json ], dry_run: options[ :dry_run ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts housekeep_parser
			{ command: :invalid }
		end

		# --- repo resolution (CLI layer) ---

		# Resolves an explicit repo name/path to a governed repository path.
		# Tries exact configured path first, then basename match (case-insensitive).
		def self.resolve_repo_target( name:, config: )
			repos = config.govern_repos
			expanded = File.expand_path( name )
			return expanded if repos.include?( expanded )

			downcased = File.basename( name ).downcase
			repos.find { |repo_path| File.basename( repo_path ).downcase == downcased }
		end

		# Resolves the CWD repo_root to a governed repository path.
		# Canonicalises worktree vs main-tree via git common-dir, then matches.
		# Compares real paths to handle symlinks (e.g., /tmp → /private/tmp on macOS).
		def self.resolve_cwd_repo( repo_root:, config: )
			canonical = canonicalise_repo_root( repo_root: repo_root )
			repos = config.govern_repos
			repos.find do |repo_path|
				expanded = File.expand_path( repo_path )
				expanded == canonical || ( File.exist?( expanded ) && File.realpath( expanded ) == canonical )
			end
		end

		# Returns the canonical main worktree root for a repo_root.
		# If inside a worktree, follows git-common-dir back to the main tree.
		def self.canonicalise_repo_root( repo_root: )
			stdout, _, status = Open3.capture3( "git", "-C", repo_root, "rev-parse", "--path-format=absolute", "--git-common-dir" )
			if status.success? && !stdout.strip.empty?
				return File.dirname( stdout.strip )
			end

			File.expand_path( repo_root )
		rescue StandardError
			File.expand_path( repo_root )
		end

		# --- global artefacts ---

		# Ensures global (non-repo) artefacts are installed at CLI startup.
		# The command-guard lives at a stable path (~/.carson/hooks/command-guard)
		# referenced by Claude Code's PreToolUse hook. It must exist regardless of
		# whether `carson refresh` has been run in any governed repo.
		def self.ensure_global_artefacts!( tool_root: )
			source = File.join( tool_root, "config", ".github", "hooks", "command-guard" )
			return unless File.file?( source )

			hooks_base = File.expand_path( "~/.carson/hooks" )
			target = File.join( hooks_base, "command-guard" )
			return if File.file?( target ) && FileUtils.identical?( source, target )

			FileUtils.mkdir_p( hooks_base )
			FileUtils.cp( source, target )
			FileUtils.chmod( 0o755, target )
		rescue StandardError
			# Best-effort — do not block any command if this fails.
		end

		# --- dispatch ---

		def self.dispatch( parsed:, runtime: )
			command = parsed.fetch( :command )
			return Runtime::EXIT_ERROR if command == :invalid

			case command
			when "status"
				runtime.status!( json_output: parsed.fetch( :json, false ) )
			when "setup"
				runtime.setup!( cli_choices: parsed.fetch( :cli_choices, {} ) )
			when "audit"
				runtime.audit!( json_output: parsed.fetch( :json, false ) )
			when "abandon"
				runtime.abandon!( target: parsed.fetch( :target ), json_output: parsed.fetch( :json, false ) )
			when "sync"
				runtime.sync!( json_output: parsed.fetch( :json, false ) )
			when "prune"
				runtime.prune!( json_output: parsed.fetch( :json, false ) )
			when "worktree:create"
				runtime.worktree_create!( name: parsed.fetch( :worktree_name ), json_output: parsed.fetch( :json, false ) )
			when "worktree:list"
				runtime.worktree_list!( json_output: parsed.fetch( :json, false ) )
			when "worktree:remove"
				runtime.worktree_remove!( worktree_path: parsed.fetch( :worktree_path ), force: parsed.fetch( :force, false ), json_output: parsed.fetch( :json, false ) )
			when "onboard"
				runtime.onboard!
			when "refresh:all"
				runtime.refresh_all!
			when "offboard"
				runtime.offboard!
			when "template:check"
				runtime.template_check!
			when "template:apply"
				runtime.template_apply!( push_prep: parsed.fetch( :push_prep, false ) )
			when "deliver"
				runtime.deliver!(
					title: parsed.fetch( :title, nil ),
					body_file: parsed.fetch( :body_file, nil ),
					commit_message: parsed.fetch( :commit_message, nil ),
					json_output: parsed.fetch( :json, false )
				)
			when "recover"
				runtime.recover!(
					check_name: parsed.fetch( :check_name ),
					json_output: parsed.fetch( :json, false )
				)
			when "review:gate"
				runtime.review_gate!
			when "review:sweep"
				runtime.review_sweep!
			when "list"
				runtime.list!( json_output: parsed.fetch( :json, false ) )
			when "receive"
				runtime.receive!(
					dry_run: parsed.fetch( :dry_run, false ),
					json_output: parsed.fetch( :json, false ),
					loop_seconds: parsed.fetch( :loop_seconds, nil )
				)
			when "housekeep"
				runtime.housekeep!( json_output: parsed.fetch( :json, false ), dry_run: parsed.fetch( :dry_run, false ) )
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
