# Parses command-line arguments and dispatches to Runtime operations.
require "optparse"

module Carson
	class CLI
		def self.start( arguments:, repo_root:, tool_root:, output:, error: )
			ensure_global_artefacts!( tool_root: tool_root )

			parsed = parse_args( arguments: arguments, output: output, error: error )
			command = parsed.fetch( :command )
			return Runtime::EXIT_OK if command == :help

			if command == "version"
				output.puts "#{BADGE} #{Carson::VERSION}"
				return Runtime::EXIT_OK
			end

			if %w[repos refresh:all prune:all housekeep:all housekeep:target template:check:all audit:all sync:all status:all].include?( command )
				verbose = parsed.fetch( :verbose, false )
				runtime = Runtime.new( repo_root: repo_root, tool_root: tool_root, output: output, error: error, verbose: verbose )
				return dispatch( parsed: parsed, runtime: runtime )
			end

			target_repo_root = parsed.fetch( :repo_root, nil )
			target_repo_root = repo_root if target_repo_root.to_s.strip.empty?
			unless Dir.exist?( target_repo_root )
				error.puts "#{BADGE} Repository path not found: #{target_repo_root}"
				return Runtime::EXIT_ERROR
			end

			verbose = parsed.fetch( :verbose, false )
			runtime = Runtime.new( repo_root: target_repo_root, tool_root: tool_root, output: output, error: error, verbose: verbose )
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

			command = arguments.shift
			result = parse_command( command: command, arguments: arguments, error: error )
			result.merge( verbose: verbose )
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts parser
			{ command: :invalid }
		end

		def self.build_parser
			OptionParser.new do |parser|
				parser.banner = "Usage: carson <command> [options]"
				parser.separator ""
				parser.separator "Repository governance and workflow automation for coding agents."
				parser.separator ""
				parser.separator "Commands:"
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
				parser.separator "    repos        List governed repositories"
				parser.separator "    onboard      Register a repository for governance"
				parser.separator "    offboard     Remove a repository from governance"
				parser.separator "    refresh      Re-install hooks and configuration"
				parser.separator "    template     Manage canonical template files"
				parser.separator "    review       Manage PR review workflow"
				parser.separator "    govern       Portfolio-level PR triage loop"
				parser.separator "    version      Show Carson version"
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

		def self.parse_command( command:, arguments:, error: )
			case command
			when "version"
				{ command: "version" }
			when "setup"
				parse_setup_command( arguments: arguments, error: error )
			when "onboard"
				parse_onboard_command( arguments: arguments, error: error )
			when "offboard"
				parse_offboard_command( arguments: arguments, error: error )
			when "refresh"
				parse_refresh_command( arguments: arguments, error: error )
			when "template"
				parse_template_subcommand( arguments: arguments, error: error )
			when "prune"
				parse_prune_command( arguments: arguments, error: error )
			when "worktree"
				parse_worktree_subcommand( arguments: arguments, error: error )
			when "repos"
				parse_repos_command( arguments: arguments, error: error )
			when "housekeep"
				parse_housekeep_command( arguments: arguments, error: error )
			when "review"
				parse_review_subcommand( arguments: arguments, error: error )
			when "audit"
				parse_audit_command( arguments: arguments, error: error )
			when "abandon"
				parse_abandon_command( arguments: arguments, error: error )
			when "sync"
				parse_sync_command( arguments: arguments, error: error )
			when "status"
				parse_status_command( arguments: arguments, error: error )
			when "deliver"
				parse_deliver_command( arguments: arguments, error: error )
			when "recover"
				parse_recover_command( arguments: arguments, error: error )
			when "govern"
				parse_govern_subcommand( arguments: arguments, error: error )
			else
				{ command: command }
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
				parser.banner = "Usage: carson onboard [REPO_PATH]"
				parser.separator ""
				parser.separator "Register a repository for Carson governance."
				parser.separator "Detects the remote, installs hooks, applies templates, and runs initial audit."
				parser.separator "Defaults to the current directory if no path is given."
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson onboard             Onboard the current repository"
				parser.separator "    carson onboard ~/Dev/app   Onboard a specific repository"
			end
			onboard_parser.parse!( arguments )
			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for onboard. Use: carson onboard [repo_path]"
				error.puts onboard_parser
				return { command: :invalid }
			end
			repo_path = arguments.first
			{
				command: "onboard",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts onboard_parser
			{ command: :invalid }
		end

		def self.parse_offboard_command( arguments:, error: )
			offboard_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson offboard [REPO_PATH]"
				parser.separator ""
				parser.separator "Remove a repository from Carson governance."
				parser.separator "Unregisters the repo from Carson's portfolio and removes hooks."
				parser.separator "Defaults to the current directory if no path is given."
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson offboard            Offboard the current repository"
			end
			offboard_parser.parse!( arguments )
			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for offboard. Use: carson offboard [repo_path]"
				error.puts offboard_parser
				return { command: :invalid }
			end
			repo_path = arguments.first
			{
				command: "offboard",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts offboard_parser
			{ command: :invalid }
		end

		# --- refresh ---

		def self.parse_refresh_command( arguments:, error: )
			options = { all: false }
			refresh_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson refresh [--all] [REPO_PATH]"
				parser.separator ""
				parser.separator "Re-install Carson hooks and configuration for a repository."
				parser.separator "Defaults to the current directory. Use --all to refresh all governed repos."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Refresh all governed repositories" ) { options[ :all ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson refresh             Refresh the current repository"
				parser.separator "    carson refresh --all       Refresh all governed repos"
			end
			refresh_parser.parse!( arguments )

			if options[ :all ] && !arguments.empty?
				error.puts "#{BADGE} --all and repo_path are mutually exclusive. Use: carson refresh --all OR carson refresh [repo_path]"
				error.puts refresh_parser
				return { command: :invalid }
			end

			return { command: "refresh:all" } if options[ :all ]

			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for refresh. Use: carson refresh [repo_path]"
				error.puts refresh_parser
				return { command: :invalid }
			end

			repo_path = arguments.first
			{
				command: "refresh",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts refresh_parser
			{ command: :invalid }
		end

		# --- prune ---

		def self.parse_prune_command( arguments:, error: )
			options = { all: false, json: false }
			prune_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson prune [--all] [--json]"
				parser.separator ""
				parser.separator "Remove stale local branches."
				parser.separator "Cleans up branches gone from the remote, orphan branches with merged PRs,"
				parser.separator "and absorbed branches whose content is already on main."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Prune all governed repositories" ) { options[ :all ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson prune           Clean up stale branches in this repo"
				parser.separator "    carson prune --all     Clean up across all governed repos"
			end
			prune_parser.parse!( arguments )
			return { command: "prune:all", json: options[ :json ] } if options[ :all ]
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
			return { command: "template:check:all" } if action == "check" && arguments.include?( "--all" )
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
			options = { json: false, all: false }
			audit_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson audit [--all] [--json]"
				parser.separator ""
				parser.separator "Run pre-commit health checks on the repository."
				parser.separator "Validates hooks, main-branch sync, PR status, and CI baseline."
				parser.separator "Exits with a non-zero status when policy violations are found."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Audit all governed repositories" ) { options[ :all ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson audit           Check repository health (also the default command)"
				parser.separator "    carson audit --json    Structured output for agent consumption"
				parser.separator "    carson audit --all     Audit all governed repos"
			end
			audit_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for audit: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "audit:all" } if options[ :all ]
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
			options = { json: false, all: false }
			sync_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson sync [--all] [--json]"
				parser.separator ""
				parser.separator "Sync the local main branch with the remote."
				parser.separator "Fetches and fast-forwards main without switching branches."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Sync all governed repositories" ) { options[ :all ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson sync            Pull latest changes from remote main"
				parser.separator "    carson sync --json     Structured output for agent consumption"
				parser.separator "    carson sync --all      Sync all governed repos"
			end
			sync_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for sync: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "sync:all" } if options[ :all ]
			{ command: "sync", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts sync_parser
			{ command: :invalid }
		end

		# --- status ---

		def self.parse_status_command( arguments:, error: )
			options = { json: false, all: false }
			status_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson status [--all] [--json]"
				parser.separator ""
				parser.separator "Show the current state of the repository."
				parser.separator "Reports branch, worktrees, open PRs, stale branches, and version."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Show status for all governed repositories" ) { options[ :all ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson status           Quick overview of repository state"
				parser.separator "    carson status --json    Structured output for agent consumption"
				parser.separator "    carson status --all     Portfolio-wide status overview"
			end
			status_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for status: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "status:all", json: options[ :json ] } if options[ :all ]
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

		# --- repos ---

		def self.parse_repos_command( arguments:, error: )
			options = { json: false }
			repos_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson repos [--json]"
				parser.separator ""
				parser.separator "List all repositories governed by Carson."
				parser.separator "Shows the portfolio of repos registered via carson onboard."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson repos           List governed repositories"
				parser.separator "    carson repos --json    Structured output for agent consumption"
			end
			repos_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for repos: #{arguments.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "repos", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts repos_parser
			{ command: :invalid }
		end

		# --- housekeep ---

		def self.parse_housekeep_command( arguments:, error: )
			options = { all: false, json: false, dry_run: false, loop_seconds: nil }
			housekeep_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson housekeep [REPO] [--all] [--dry-run] [--json] [--loop SECONDS]"
				parser.separator ""
				parser.separator "Run housekeeping: sync main, reap dead worktrees, and prune stale branches."
				parser.separator "Defaults to the current repository."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Housekeep all governed repositories" ) { options[ :all ] = true }
				parser.on( "--dry-run", "Show what would be reaped/deleted without making changes" ) { options[ :dry_run ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--loop SECONDS", Integer, "Run continuously, sleeping SECONDS between cycles (requires --all)" ) do |seconds|
					error.puts( "#{BADGE} --loop expects a positive integer" ) || ( return { command: :invalid } ) if seconds < 1
					options[ :loop_seconds ] = seconds
				end
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson housekeep              Housekeep the current repository"
				parser.separator "    carson housekeep --dry-run    Preview what housekeep would do"
				parser.separator "    carson housekeep nexus        Housekeep a named governed repo"
				parser.separator "    carson housekeep --all        Housekeep all governed repos"
				parser.separator "    carson housekeep --all --loop 300   Housekeep every 5 minutes"
			end
			housekeep_parser.parse!( arguments )

			if options[ :loop_seconds ] && !options[ :all ]
				error.puts "#{BADGE} --loop requires --all"
				return { command: :invalid }
			end

			if options[ :all ] && !arguments.empty?
				error.puts "#{BADGE} --all and repo target are mutually exclusive. Use: carson housekeep --all OR carson housekeep [repo]"
				return { command: :invalid }
			end

			return { command: "housekeep:all", json: options[ :json ], dry_run: options[ :dry_run ], loop_seconds: options[ :loop_seconds ] } if options[ :all ]

			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for housekeep. Use: carson housekeep [repo]"
				return { command: :invalid }
			end

			target = arguments.shift
			return { command: "housekeep:target", target: target, json: options[ :json ], dry_run: options[ :dry_run ] } if target

			{ command: "housekeep", json: options[ :json ], dry_run: options[ :dry_run ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts housekeep_parser
			{ command: :invalid }
		end

		# --- govern ---

		def self.parse_govern_subcommand( arguments:, error: )
			options = {
				dry_run: false,
				json: false,
				loop_seconds: nil
			}
			govern_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson govern [--dry-run] [--json] [--loop SECONDS]"
				parser.separator ""
				parser.separator "Portfolio-level PR triage loop."
				parser.separator "Scans governed repositories, classifies open PRs, and takes action"
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
				parser.separator "    carson govern                  Triage all governed repos once"
				parser.separator "    carson govern --dry-run        Preview actions without applying them"
				parser.separator "    carson govern --loop 300       Run continuously every 5 minutes"
			end
			govern_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for govern: #{arguments.join( ' ' )}"
				error.puts govern_parser
				return { command: :invalid }
			end
			{
				command: "govern",
				dry_run: options.fetch( :dry_run ),
				json: options.fetch( :json ),
				loop_seconds: options[ :loop_seconds ]
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts govern_parser
			{ command: :invalid }
		end

		# --- global artefacts ---

		# Ensures global (non-repo) artefacts are installed at CLI startup.
		# The command-guard lives at a stable path (~/.carson/hooks/command-guard)
		# referenced by Claude Code's PreToolUse hook. It must exist regardless of
		# whether `carson refresh` has been run in any governed repo.
		def self.ensure_global_artefacts!( tool_root: )
			source = File.join( tool_root, "hooks", "command-guard" )
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
			when "prune:all"
				runtime.prune_all!
			when "worktree:create"
				runtime.worktree_create!( name: parsed.fetch( :worktree_name ), json_output: parsed.fetch( :json, false ) )
			when "worktree:list"
				runtime.worktree_list!( json_output: parsed.fetch( :json, false ) )
			when "worktree:remove"
				runtime.worktree_remove!( worktree_path: parsed.fetch( :worktree_path ), force: parsed.fetch( :force, false ), json_output: parsed.fetch( :json, false ) )
			when "onboard"
				runtime.onboard!
			when "refresh"
				runtime.refresh!
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
			when "repos"
				runtime.repos!( json_output: parsed.fetch( :json, false ) )
			when "housekeep"
				runtime.housekeep!( json_output: parsed.fetch( :json, false ), dry_run: parsed.fetch( :dry_run, false ) )
			when "housekeep:target"
				runtime.housekeep_target!( target: parsed.fetch( :target ), json_output: parsed.fetch( :json, false ), dry_run: parsed.fetch( :dry_run, false ) )
			when "housekeep:all"
				loop_seconds = parsed.fetch( :loop_seconds, nil )
				if loop_seconds
					runtime.housekeep_loop!(
						json_output: parsed.fetch( :json, false ),
						dry_run: parsed.fetch( :dry_run, false ),
						loop_seconds: loop_seconds
					)
				else
					runtime.housekeep_all!( json_output: parsed.fetch( :json, false ), dry_run: parsed.fetch( :dry_run, false ) )
				end
			when "govern"
				runtime.govern!(
					dry_run: parsed.fetch( :dry_run, false ),
					json_output: parsed.fetch( :json, false ),
					loop_seconds: parsed.fetch( :loop_seconds, nil )
				)
			when "template:check:all"
				runtime.template_check_all!
			when "audit:all"
				runtime.audit_all!
			when "sync:all"
				runtime.sync_all!
			when "status:all"
				runtime.status_all!( json_output: parsed.fetch( :json, false ) )
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
