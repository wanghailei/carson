require "optparse"

module Carson
	class CLI
		def self.start( argv:, repo_root:, tool_root:, out:, err: )
			parsed = parse_args( argv: argv, out: out, err: err )
			command = parsed.fetch( :command )
			return Runtime::EXIT_OK if command == :help

			if command == "version"
				out.puts "#{BADGE} #{Carson::VERSION}"
				return Runtime::EXIT_OK
			end

			if %w[repos refresh:all prune:all housekeep:all housekeep:target template:check:all audit:all sync:all status:all].include?( command )
				verbose = parsed.fetch( :verbose, false )
				runtime = Runtime.new( repo_root: repo_root, tool_root: tool_root, out: out, err: err, verbose: verbose )
				return dispatch( parsed: parsed, runtime: runtime )
			end

			target_repo_root = parsed.fetch( :repo_root, nil )
			target_repo_root = repo_root if target_repo_root.to_s.strip.empty?
			unless Dir.exist?( target_repo_root )
				err.puts "#{BADGE} ERROR: repository path does not exist: #{target_repo_root}"
				return Runtime::EXIT_ERROR
			end

			verbose = parsed.fetch( :verbose, false )
			runtime = Runtime.new( repo_root: target_repo_root, tool_root: tool_root, out: out, err: err, verbose: verbose )
			dispatch( parsed: parsed, runtime: runtime )
		rescue ConfigError => e
			err.puts "#{BADGE} CONFIG ERROR: #{e.message}"
			Runtime::EXIT_ERROR
		rescue StandardError => e
			err.puts "#{BADGE} ERROR: #{e.message}"
			Runtime::EXIT_ERROR
		end

		def self.parse_args( argv:, out:, err: )
			verbose = argv.delete( "--verbose" ) ? true : false
			parser = build_parser
			preset = parse_preset_command( argv: argv, out: out, parser: parser )
			return preset.merge( verbose: verbose ) unless preset.nil?

			command = argv.shift
			result = parse_command( command: command, argv: argv, err: err )
			result.merge( verbose: verbose )
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			err.puts parser
			{ command: :invalid }
		end

		def self.build_parser
			OptionParser.new do |opts|
				opts.banner = "Usage: carson <command> [options]"
				opts.separator ""
				opts.separator "Repository governance and workflow automation for coding agents."
				opts.separator ""
				opts.separator "Commands:"
				opts.separator "    status       Show repository state (branch, PRs, worktrees)"
				opts.separator "    setup        Initialise Carson configuration"
				opts.separator "    audit        Run pre-commit health checks"
				opts.separator "    sync         Sync local main with remote"
				opts.separator "    deliver      Push, create PR, and optionally merge"
				opts.separator "    prune        Remove stale local branches"
				opts.separator "    worktree     Manage isolated coding worktrees"
				opts.separator "    housekeep    Sync, reap worktrees, and prune branches"
				opts.separator "    repos        List governed repositories"
				opts.separator "    onboard      Register a repository for governance"
				opts.separator "    offboard     Remove a repository from governance"
				opts.separator "    refresh      Re-install hooks and configuration"
				opts.separator "    template     Manage canonical template files"
				opts.separator "    review       Manage PR review workflow"
				opts.separator "    govern       Portfolio-level PR triage loop"
				opts.separator "    version      Show Carson version"
				opts.separator ""
				opts.separator "Run `carson <command> --help` for details on a specific command."
			end
		end

		def self.parse_preset_command( argv:, out:, parser: )
			first = argv.first
			if [ "--help", "-h" ].include?( first )
				out.puts parser
				return { command: :help }
			end
			return { command: "version" } if [ "--version", "-v" ].include?( first )
			return { command: "audit" } if argv.empty?

			nil
		end

		def self.parse_command( command:, argv:, err: )
			case command
			when "version"
				{ command: "version" }
			when "setup"
				parse_setup_command( argv: argv, err: err )
			when "onboard"
				parse_onboard_command( argv: argv, err: err )
			when "offboard"
				parse_offboard_command( argv: argv, err: err )
			when "refresh"
				parse_refresh_command( argv: argv, err: err )
			when "template"
				parse_template_subcommand( argv: argv, err: err )
			when "prune"
				parse_prune_command( argv: argv, err: err )
			when "worktree"
				parse_worktree_subcommand( argv: argv, err: err )
			when "repos"
				parse_repos_command( argv: argv, err: err )
			when "housekeep"
				parse_housekeep_command( argv: argv, err: err )
			when "review"
				parse_review_subcommand( argv: argv, err: err )
			when "audit"
				parse_audit_command( argv: argv, err: err )
			when "sync"
				parse_sync_command( argv: argv, err: err )
			when "status"
				parse_status_command( argv: argv, err: err )
			when "deliver"
				parse_deliver_command( argv: argv, err: err )
			when "govern"
				parse_govern_subcommand( argv: argv, err: err )
			else
				{ command: command }
			end
		end

		# --- setup ---

		def self.parse_setup_command( argv:, err: )
			options = {}
			setup_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson setup [--remote NAME] [--main-branch NAME] [--workflow STYLE] [--merge METHOD] [--canonical PATH]"
				opts.separator ""
				opts.separator "Initialise Carson configuration for the current repository."
				opts.separator "Detects git remote, main branch, and workflow style, then writes .carson.yml."
				opts.separator "Pass flags to override detected values."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--remote NAME", "Git remote name" ) { |v| options[ "git.remote" ] = v }
				opts.on( "--main-branch NAME", "Main branch name" ) { |v| options[ "git.main_branch" ] = v }
				opts.on( "--workflow STYLE", "Workflow style (branch or trunk)" ) { |v| options[ "workflow.style" ] = v }
				opts.on( "--merge METHOD", "Merge method (squash, rebase, or merge)" ) { |v| options[ "govern.merge.method" ] = v }
				opts.on( "--canonical PATH", "Canonical template directory path" ) { |v| options[ "template.canonical" ] = v }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson setup                            Auto-detect and write config"
				opts.separator "    carson setup --remote github            Use 'github' as the git remote"
				opts.separator "    carson setup --merge squash             Set squash as the merge method"
			end
			setup_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for setup: #{argv.join( ' ' )}"
				err.puts setup_parser
				return { command: :invalid }
			end
			{ command: "setup", cli_choices: options }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- onboard / offboard ---

		def self.parse_onboard_command( argv:, err: )
			onboard_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson onboard [REPO_PATH]"
				opts.separator ""
				opts.separator "Register a repository for Carson governance."
				opts.separator "Detects the remote, installs hooks, applies templates, and runs initial audit."
				opts.separator "Defaults to the current directory if no path is given."
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson onboard             Onboard the current repository"
				opts.separator "    carson onboard ~/Dev/app   Onboard a specific repository"
			end
			onboard_parser.parse!( argv )
			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for onboard. Use: carson onboard [repo_path]"
				err.puts onboard_parser
				return { command: :invalid }
			end
			repo_path = argv.first
			{
				command: "onboard",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		def self.parse_offboard_command( argv:, err: )
			offboard_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson offboard [REPO_PATH]"
				opts.separator ""
				opts.separator "Remove a repository from Carson governance."
				opts.separator "Unregisters the repo from Carson's portfolio and removes hooks."
				opts.separator "Defaults to the current directory if no path is given."
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson offboard            Offboard the current repository"
			end
			offboard_parser.parse!( argv )
			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for offboard. Use: carson offboard [repo_path]"
				err.puts offboard_parser
				return { command: :invalid }
			end
			repo_path = argv.first
			{
				command: "offboard",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- refresh ---

		def self.parse_refresh_command( argv:, err: )
			options = { all: false }
			refresh_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson refresh [--all] [REPO_PATH]"
				opts.separator ""
				opts.separator "Re-install Carson hooks and configuration for a repository."
				opts.separator "Defaults to the current directory. Use --all to refresh all governed repos."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Refresh all governed repositories" ) { options[ :all ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson refresh             Refresh the current repository"
				opts.separator "    carson refresh --all       Refresh all governed repos"
			end
			refresh_parser.parse!( argv )

			if options[ :all ] && !argv.empty?
				err.puts "#{BADGE} --all and repo_path are mutually exclusive. Use: carson refresh --all OR carson refresh [repo_path]"
				err.puts refresh_parser
				return { command: :invalid }
			end

			return { command: "refresh:all" } if options[ :all ]

			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for refresh. Use: carson refresh [repo_path]"
				err.puts refresh_parser
				return { command: :invalid }
			end

			repo_path = argv.first
			{
				command: "refresh",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- prune ---

		def self.parse_prune_command( argv:, err: )
			options = { all: false, json: false }
			prune_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson prune [--all] [--json]"
				opts.separator ""
				opts.separator "Remove stale local branches."
				opts.separator "Cleans up branches gone from the remote, orphan branches with merged PRs,"
				opts.separator "and absorbed branches whose content is already on main."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Prune all governed repositories" ) { options[ :all ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson prune           Clean up stale branches in this repo"
				opts.separator "    carson prune --all     Clean up across all governed repos"
			end
			prune_parser.parse!( argv )
			return { command: "prune:all", json: options[ :json ] } if options[ :all ]
			{ command: "prune", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- worktree ---

		def self.parse_worktree_subcommand( argv:, err: )
			options = { json: false, force: false }
			worktree_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson worktree <create|remove> <name> [options]"
				opts.separator ""
				opts.separator "Manage isolated worktrees for coding agents."
				opts.separator "Create auto-syncs main before branching. Remove guards against"
				opts.separator "unpushed commits and CWD-inside-worktree by default."
				opts.separator ""
				opts.separator "Subcommands:"
				opts.separator "    create <name>              Create a new worktree with a fresh branch"
				opts.separator "    remove <name> [--force]    Remove a worktree (--force skips safety checks)"
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.on( "--force", "Skip safety checks on remove" ) { options[ :force ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson worktree create feature-x    Create an isolated worktree"
				opts.separator "    carson worktree remove feature-x    Remove after work is pushed"
			end
			worktree_parser.parse!( argv )

			action = argv.shift
			if action.to_s.strip.empty?
				err.puts "#{BADGE} Missing subcommand for worktree. Use: carson worktree create|remove <name>"
				err.puts worktree_parser
				return { command: :invalid }
			end

			case action
			when "create"
				name = argv.shift
				if name.to_s.strip.empty?
					err.puts "#{BADGE} Missing name for worktree create. Use: carson worktree create <name>"
					return { command: :invalid }
				end
				{ command: "worktree:create", worktree_name: name, json: options[ :json ] }
			when "remove"
				worktree_path = argv.shift
				if worktree_path.to_s.strip.empty?
					err.puts "#{BADGE} Missing path for worktree remove. Use: carson worktree remove <name-or-path>"
					return { command: :invalid }
				end
				{ command: "worktree:remove", worktree_path: worktree_path, force: options[ :force ], json: options[ :json ] }
			else
				err.puts "#{BADGE} Unknown worktree subcommand: #{action}. Use: carson worktree create|remove <name>"
				{ command: :invalid }
			end
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- review ---

		def self.parse_review_subcommand( argv:, err: )
			review_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson review <gate|sweep>"
				opts.separator ""
				opts.separator "Manage PR review workflow."
				opts.separator ""
				opts.separator "Subcommands:"
				opts.separator "    gate     Check if review requirements are met for merge"
				opts.separator "    sweep    Scan and resolve pending review threads"
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson review gate     Check merge readiness"
				opts.separator "    carson review sweep    Resolve pending review threads"
			end
			review_parser.parse!( argv )

			action = argv.shift
			if action.to_s.strip.empty?
				err.puts "#{BADGE} Missing subcommand for review. Use: carson review gate|sweep"
				err.puts review_parser
				return { command: :invalid }
			end
			{ command: "review:#{action}" }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- template ---

		def self.parse_template_subcommand( argv:, err: )
			# Handle parent-level help or missing subcommand.
			if argv.empty? || [ "--help", "-h" ].include?( argv.first )
				template_parser = OptionParser.new do |opts|
					opts.banner = "Usage: carson template <check|apply> [options]"
					opts.separator ""
					opts.separator "Manage canonical template files (CI workflows, lint configs)."
					opts.separator ""
					opts.separator "Subcommands:"
					opts.separator "    check                  Show template drift without making changes"
					opts.separator "    apply [--push-prep]    Sync templates into the repository"
					opts.separator ""
					opts.separator "Examples:"
					opts.separator "    carson template check    Check for template drift"
					opts.separator "    carson template apply    Apply canonical templates"
				end

				if argv.empty?
					err.puts "#{BADGE} Missing subcommand for template. Use: carson template check|apply"
					err.puts template_parser
					return { command: :invalid }
				end

				# Let OptionParser handle --help (prints and exits).
				template_parser.parse!( argv )
				return { command: :help }
			end

			action = argv.shift
			return { command: "template:check:all" } if action == "check" && argv.include?( "--all" )
			return { command: "template:#{action}" } unless action == "apply"

			options = { push_prep: false }
			apply_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson template apply [--push-prep]"
				opts.separator ""
				opts.separator "Sync canonical template files (CI workflows, lint configs) into the repository."
				opts.separator "Copies managed files from the configured canonical directory."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--push-prep", "Apply templates and auto-commit any managed file changes (used by pre-push hook)" ) do
					options[ :push_prep ] = true
				end
			end
			apply_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for template apply: #{argv.join( ' ' )}"
				err.puts apply_parser
				return { command: :invalid }
			end
			{ command: "template:apply", push_prep: options.fetch( :push_prep ) }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- audit ---

		def self.parse_audit_command( argv:, err: )
			options = { json: false, all: false }
			audit_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson audit [--all] [--json]"
				opts.separator ""
				opts.separator "Run pre-commit health checks on the repository."
				opts.separator "Validates hooks, main-branch sync, PR status, and CI baseline."
				opts.separator "Exits with a non-zero status when policy violations are found."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Audit all governed repositories" ) { options[ :all ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson audit           Check repository health (also the default command)"
				opts.separator "    carson audit --json    Structured output for agent consumption"
				opts.separator "    carson audit --all     Audit all governed repos"
			end
			audit_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for audit: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "audit:all" } if options[ :all ]
			{ command: "audit", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- sync ---

		def self.parse_sync_command( argv:, err: )
			options = { json: false, all: false }
			sync_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson sync [--all] [--json]"
				opts.separator ""
				opts.separator "Sync the local main branch with the remote."
				opts.separator "Fetches and fast-forwards main without switching branches."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Sync all governed repositories" ) { options[ :all ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson sync            Pull latest changes from remote main"
				opts.separator "    carson sync --json     Structured output for agent consumption"
				opts.separator "    carson sync --all      Sync all governed repos"
			end
			sync_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for sync: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "sync:all" } if options[ :all ]
			{ command: "sync", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- status ---

		def self.parse_status_command( argv:, err: )
			options = { json: false, all: false }
			status_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson status [--all] [--json]"
				opts.separator ""
				opts.separator "Show the current state of the repository."
				opts.separator "Reports branch, worktrees, open PRs, stale branches, and version."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Show status for all governed repositories" ) { options[ :all ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson status           Quick overview of repository state"
				opts.separator "    carson status --json    Structured output for agent consumption"
				opts.separator "    carson status --all     Portfolio-wide status overview"
			end
			status_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for status: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			return { command: "status:all", json: options[ :json ] } if options[ :all ]
			{ command: "status", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- deliver ---

		def self.parse_deliver_command( argv:, err: )
			options = { merge: false, json: false, title: nil, body_file: nil }
			deliver_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson deliver [--merge] [--json] [--title TITLE] [--body-file PATH]"
				opts.separator ""
				opts.separator "Push the current branch, create a pull request, and optionally merge."
				opts.separator "Collapses the manual push → PR → merge flow into a single command."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--merge", "Also merge the PR if CI passes" ) { options[ :merge ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.on( "--title TITLE", "PR title (defaults to branch name)" ) { |v| options[ :title ] = v }
				opts.on( "--body-file PATH", "File containing PR body text" ) { |v| options[ :body_file ] = v }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson deliver               Push and open a PR"
				opts.separator "    carson deliver --merge       Push, open a PR, and merge if CI passes"
			end
			deliver_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for deliver: #{argv.join( ' ' )}"
				err.puts deliver_parser
				return { command: :invalid }
			end
			{
				command: "deliver",
				merge: options.fetch( :merge ),
				json: options.fetch( :json ),
				title: options[ :title ],
				body_file: options[ :body_file ]
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- repos ---

		def self.parse_repos_command( argv:, err: )
			options = { json: false }
			repos_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson repos [--json]"
				opts.separator ""
				opts.separator "List all repositories governed by Carson."
				opts.separator "Shows the portfolio of repos registered via carson onboard."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson repos           List governed repositories"
				opts.separator "    carson repos --json    Structured output for agent consumption"
			end
			repos_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for repos: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "repos", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- housekeep ---

		def self.parse_housekeep_command( argv:, err: )
			options = { all: false, json: false }
			housekeep_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson housekeep [REPO] [--all] [--json]"
				opts.separator ""
				opts.separator "Run housekeeping: sync main, reap dead worktrees, and prune stale branches."
				opts.separator "Defaults to the current repository."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--all", "Housekeep all governed repositories" ) { options[ :all ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson housekeep           Housekeep the current repository"
				opts.separator "    carson housekeep nexus     Housekeep a named governed repo"
				opts.separator "    carson housekeep --all     Housekeep all governed repos"
			end
			housekeep_parser.parse!( argv )

			if options[ :all ] && !argv.empty?
				err.puts "#{BADGE} --all and repo target are mutually exclusive. Use: carson housekeep --all OR carson housekeep [repo]"
				return { command: :invalid }
			end

			return { command: "housekeep:all", json: options[ :json ] } if options[ :all ]

			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for housekeep. Use: carson housekeep [repo]"
				return { command: :invalid }
			end

			target = argv.shift
			return { command: "housekeep:target", target: target, json: options[ :json ] } if target

			{ command: "housekeep", json: options[ :json ] }
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			{ command: :invalid }
		end

		# --- govern ---

		def self.parse_govern_subcommand( argv:, err: )
			options = {
				dry_run: false,
				json: false,
				loop_seconds: nil
			}
			govern_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson govern [--dry-run] [--json] [--loop SECONDS]"
				opts.separator ""
				opts.separator "Portfolio-level PR triage loop."
				opts.separator "Scans governed repositories, classifies open PRs, and takes action"
				opts.separator "(merge, request review, or report). Runs once by default."
				opts.separator ""
				opts.separator "Options:"
				opts.on( "--dry-run", "Run all checks but do not merge or dispatch" ) { options[ :dry_run ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.on( "--loop SECONDS", Integer, "Run continuously, sleeping SECONDS between cycles" ) do |s|
					err.puts( "#{BADGE} Error: --loop must be a positive integer" ) || ( return { command: :invalid } ) if s < 1
					options[ :loop_seconds ] = s
				end
				opts.separator ""
				opts.separator "Examples:"
				opts.separator "    carson govern                  Triage all governed repos once"
				opts.separator "    carson govern --dry-run        Preview actions without applying them"
				opts.separator "    carson govern --loop 300       Run continuously every 5 minutes"
			end
			govern_parser.parse!( argv )
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for govern: #{argv.join( ' ' )}"
				err.puts govern_parser
				return { command: :invalid }
			end
			{
				command: "govern",
				dry_run: options.fetch( :dry_run ),
				json: options.fetch( :json ),
				loop_seconds: options[ :loop_seconds ]
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			err.puts govern_parser
			{ command: :invalid }
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
			when "sync"
				runtime.sync!( json_output: parsed.fetch( :json, false ) )
			when "prune"
				runtime.prune!( json_output: parsed.fetch( :json, false ) )
			when "prune:all"
				runtime.prune_all!
			when "worktree:create"
				runtime.worktree_create!( name: parsed.fetch( :worktree_name ), json_output: parsed.fetch( :json, false ) )
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
					merge: parsed.fetch( :merge, false ),
					title: parsed.fetch( :title, nil ),
					body_file: parsed.fetch( :body_file, nil ),
					json_output: parsed.fetch( :json, false )
				)
			when "review:gate"
				runtime.review_gate!
			when "review:sweep"
				runtime.review_sweep!
			when "repos"
				runtime.repos!( json_output: parsed.fetch( :json, false ) )
			when "housekeep"
				runtime.housekeep!( json_output: parsed.fetch( :json, false ) )
			when "housekeep:target"
				runtime.housekeep_target!( target: parsed.fetch( :target ), json_output: parsed.fetch( :json, false ) )
			when "housekeep:all"
				runtime.housekeep_all!( json_output: parsed.fetch( :json, false ) )
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
