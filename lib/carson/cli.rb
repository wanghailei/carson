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
				parser.separator "Tier 1 streams:"
				parser.separator "    deliver      Complete delivery stream: push, PR, merge, sync"
				parser.separator "    realign      Realign the current branch with main"
				parser.separator "    revert       Revert merged work through a dedicated branch/PR"
				parser.separator "    release      Tag and publish a prepared release"
				parser.separator "    track        Manage issue lifecycle"
				parser.separator "    review       Manage PR review workflow"
				parser.separator ""
				parser.separator "Support commands:"
				parser.separator "    status       Show repository state (branch, PRs, worktrees)"
				parser.separator "    setup        Initialise Carson configuration"
				parser.separator "    audit        Run pre-commit health checks"
				parser.separator "    sync         Sync local main with remote"
				parser.separator "    prune        Remove stale local branches"
				parser.separator "    worktree     Manage isolated coding worktrees"
				parser.separator "    housekeep    Sync, reap worktrees, and prune branches"
				parser.separator "    repos        List governed repositories"
				parser.separator "    onboard      Register a repository for governance"
				parser.separator "    offboard     Remove a repository from governance"
				parser.separator "    refresh      Re-install hooks and configuration"
				parser.separator "    template     Manage canonical template files"
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
			when "track"
				parse_track_subcommand( arguments: arguments, error: error )
			when "audit"
				parse_audit_command( arguments: arguments, error: error )
			when "sync"
				parse_sync_command( arguments: arguments, error: error )
			when "status"
				parse_status_command( arguments: arguments, error: error )
			when "deliver"
				parse_deliver_command( arguments: arguments, error: error )
			when "realign"
				parse_realign_command( arguments: arguments, error: error )
			when "revert"
				parse_revert_command( arguments: arguments, error: error )
			when "release"
				parse_release_command( arguments: arguments, error: error )
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
				parser.banner = "Usage: carson setup [--remote NAME] [--main-branch NAME] [--workflow STYLE] [--merge METHOD] [--canonical PATH]"
				parser.separator ""
				parser.separator "Initialise Carson configuration for the current repository."
				parser.separator "Detects git remote, main branch, and workflow style, then writes .carson.yml."
				parser.separator "Pass flags to override detected values."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--remote NAME", "Git remote name" ) { |value| options[ "git.remote" ] = value }
				parser.on( "--main-branch NAME", "Main branch name" ) { |value| options[ "git.main_branch" ] = value }
				parser.on( "--workflow STYLE", "Workflow style (branch or trunk)" ) { |value| options[ "workflow.style" ] = value }
				parser.on( "--merge METHOD", "Merge method (squash, rebase, or merge)" ) { |value| options[ "govern.merge.method" ] = value }
				parser.on( "--canonical PATH", "Canonical lint policy directory path" ) { |value| options[ "lint.canonical" ] = value }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson setup                            Auto-detect and write config"
				parser.separator "    carson setup --remote github            Use 'github' as the git remote"
				parser.separator "    carson setup --merge squash             Set squash as the merge method"
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
				parser.banner = "Usage: carson worktree <create|remove> <name> [options]"
				parser.separator ""
				parser.separator "Manage isolated worktrees for coding agents."
				parser.separator "Create auto-syncs main before branching. Remove guards against"
				parser.separator "unpushed commits and CWD-inside-worktree by default."
				parser.separator ""
				parser.separator "Subcommands:"
				parser.separator "    create <name>              Create a new worktree with a fresh branch"
				parser.separator "    remove <name> [--force]    Remove a worktree (--force skips safety checks)"
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--force", "Skip safety checks on remove" ) { options[ :force ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson worktree create feature-x    Create an isolated worktree"
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
			action = arguments.shift
			if action.to_s.strip.empty?
				review_parser = build_review_parser
				error.puts "#{BADGE} Missing subcommand for review. Use: carson review gate|sweep"
				error.puts review_parser
				return { command: :invalid }
			end
			case action
			when "gate", "sweep"
				review_parser = build_review_parser
				review_parser.parse!( arguments )
				unless arguments.empty?
					error.puts "#{BADGE} Unexpected arguments for review #{action}: #{arguments.join( ' ' )}"
					error.puts review_parser
					return { command: :invalid }
				end
				{ command: "review:#{action}" }
			when "comment", "approve", "request-changes"
				parse_review_numbered_action( action: action, arguments: arguments, error: error )
			when "reply"
				parse_review_reply_action( arguments: arguments, error: error )
			when "disposition"
				parse_review_disposition_action( arguments: arguments, error: error )
			else
				error.puts "#{BADGE} Unknown review subcommand: #{action}. Use: carson review gate|sweep|comment|reply|approve|request-changes|disposition"
				{ command: :invalid }
			end
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts( review_parser || build_review_parser )
			{ command: :invalid }
		end

		def self.build_review_parser
			OptionParser.new do |parser|
				parser.banner = "Usage: carson review <gate|sweep|comment|reply|approve|request-changes|disposition> [options]"
				parser.separator ""
				parser.separator "Manage pull-request review workflow."
				parser.separator ""
				parser.separator "Subcommands:"
				parser.separator "    gate               Check if review requirements are met for merge"
				parser.separator "    sweep              Scan for late actionable review feedback"
				parser.separator "    comment PR         Add a top-level PR comment"
				parser.separator "    reply URL          Reply to a review thread comment URL"
				parser.separator "    approve PR         Submit an approval review"
				parser.separator "    request-changes PR Submit a changes-requested review"
				parser.separator "    disposition URL    Post a disposition referencing a finding URL"
			end
		end

		def self.parse_review_numbered_action( action:, arguments:, error: )
			options = { json: false, body: nil, body_file: nil }
			review_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson review #{action} <pr-number> [--body TEXT] [--body-file PATH] [--json]"
				parser.separator ""
				parser.on( "--body TEXT", "Inline review body text" ) { |value| options[ :body ] = value }
				parser.on( "--body-file PATH", "File containing review body text" ) { |value| options[ :body_file ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			review_parser.parse!( arguments )
			pr_number = arguments.shift
			if pr_number.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson review #{action} <pr-number> [--body TEXT] [--body-file PATH] [--json]"
				error.puts review_parser
				return { command: :invalid }
			end
			{
				command: "review:#{action}",
				pr_number: Integer( pr_number ),
				body: options[ :body ],
				body_file: options[ :body_file ],
				json: options[ :json ]
			}
		rescue ArgumentError
			error.puts "#{BADGE} PR number must be an integer"
			error.puts review_parser
			{ command: :invalid }
		end

		def self.parse_review_reply_action( arguments:, error: )
			options = { json: false, body: nil, body_file: nil }
			reply_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson review reply <target-url> [--body TEXT] [--body-file PATH] [--json]"
				parser.separator ""
				parser.on( "--body TEXT", "Inline reply text" ) { |value| options[ :body ] = value }
				parser.on( "--body-file PATH", "File containing reply text" ) { |value| options[ :body_file ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			reply_parser.parse!( arguments )
			target_url = arguments.shift
			if target_url.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson review reply <target-url> [--body TEXT] [--body-file PATH] [--json]"
				error.puts reply_parser
				return { command: :invalid }
			end
			{ command: "review:reply", target_url: target_url, body: options[ :body ], body_file: options[ :body_file ], json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts reply_parser
			{ command: :invalid }
		end

		def self.parse_review_disposition_action( arguments:, error: )
			options = { json: false, body: nil, body_file: nil }
			disposition_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson review disposition <target-url> <accepted|rejected|deferred> [--body TEXT] [--body-file PATH] [--json]"
				parser.separator ""
				parser.on( "--body TEXT", "Optional explanatory text" ) { |value| options[ :body ] = value }
				parser.on( "--body-file PATH", "File containing explanatory text" ) { |value| options[ :body_file ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			disposition_parser.parse!( arguments )
			target_url = arguments.shift
			disposition = arguments.shift
			if target_url.to_s.strip.empty? || disposition.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson review disposition <target-url> <accepted|rejected|deferred> [--body TEXT] [--body-file PATH] [--json]"
				error.puts disposition_parser
				return { command: :invalid }
			end
			unless %w[accepted rejected deferred].include?( disposition )
				error.puts "#{BADGE} disposition must be accepted, rejected, or deferred"
				error.puts disposition_parser
				return { command: :invalid }
			end
			{ command: "review:disposition", target_url: target_url, disposition: disposition, body: options[ :body ], body_file: options[ :body_file ], json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts disposition_parser
			{ command: :invalid }
		end

		# --- track ---

		def self.parse_track_subcommand( arguments:, error: )
			action = arguments.shift
			if action.to_s.strip.empty?
				error.puts "#{BADGE} Missing subcommand for track. Use: carson track open|comment|close|reopen"
				return { command: :invalid }
			end

			case action
			when "open"
				parse_track_open_action( arguments: arguments, error: error )
			when "comment", "close", "reopen"
				parse_track_issue_action( action: action, arguments: arguments, error: error )
			else
				error.puts "#{BADGE} Unknown track subcommand: #{action}. Use: carson track open|comment|close|reopen"
				{ command: :invalid }
			end
		end

		def self.parse_track_open_action( arguments:, error: )
			options = { json: false, title: nil, body: nil, body_file: nil }
			track_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson track open --title TITLE [--body TEXT] [--body-file PATH] [--json]"
				parser.separator ""
				parser.on( "--title TITLE", "Issue title" ) { |value| options[ :title ] = value }
				parser.on( "--body TEXT", "Inline issue body text" ) { |value| options[ :body ] = value }
				parser.on( "--body-file PATH", "File containing issue body text" ) { |value| options[ :body_file ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			track_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for track open: #{arguments.join( ' ' )}"
				error.puts track_parser
				return { command: :invalid }
			end
			{ command: "track:open", title: options[ :title ], body: options[ :body ], body_file: options[ :body_file ], json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts track_parser
			{ command: :invalid }
		end

		def self.parse_track_issue_action( action:, arguments:, error: )
			options = { json: false, body: nil, body_file: nil }
			track_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson track #{action} <issue-number> [--body TEXT] [--body-file PATH] [--json]"
				parser.separator ""
				parser.on( "--body TEXT", "Inline issue comment text" ) { |value| options[ :body ] = value }
				parser.on( "--body-file PATH", "File containing issue comment text" ) { |value| options[ :body_file ] = value }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			track_parser.parse!( arguments )
			issue_number = arguments.shift
			if issue_number.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson track #{action} <issue-number> [--body TEXT] [--body-file PATH] [--json]"
				error.puts track_parser
				return { command: :invalid }
			end
			{
				command: "track:#{action}",
				issue_number: Integer( issue_number ),
				body: options[ :body ],
				body_file: options[ :body_file ],
				json: options[ :json ]
			}
		rescue ArgumentError
			error.puts "#{BADGE} issue number must be an integer"
			error.puts track_parser
			{ command: :invalid }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts track_parser
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
			options = { merge: false, pr_only: false, json: false, title: nil, body_file: nil }
			deliver_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson deliver [--pr-only] [--merge] [--json] [--title TITLE] [--body-file PATH]"
				parser.separator ""
				parser.separator "Run the complete post-commit delivery stream."
				parser.separator "Pushes the branch, creates or reuses the PR, waits for readiness, merges, and syncs local main."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--pr-only", "Stop after pushing and opening/updating the PR" ) { options[ :pr_only ] = true }
				parser.on( "--merge", "Compatibility alias for the default full stream" ) { options[ :merge ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.on( "--title TITLE", "PR title (defaults to branch name)" ) { |value| options[ :title ] = value }
				parser.on( "--body-file PATH", "File containing PR body text" ) { |value| options[ :body_file ] = value }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson deliver               Push, open/update the PR, merge when ready, and sync main"
				parser.separator "    carson deliver --pr-only     Push and open/update the PR without waiting or merging"
			end
			deliver_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for deliver: #{arguments.join( ' ' )}"
				error.puts deliver_parser
				return { command: :invalid }
			end
			if options[ :pr_only ] && options[ :merge ]
				error.puts "#{BADGE} --pr-only and --merge are mutually exclusive"
				error.puts deliver_parser
				return { command: :invalid }
			end
			{
				command: "deliver",
				merge: options.fetch( :merge ),
				pr_only: options.fetch( :pr_only ),
				json: options.fetch( :json ),
				title: options[ :title ],
				body_file: options[ :body_file ]
			}
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts deliver_parser
			{ command: :invalid }
		end

		# --- realign / revert / release ---

		def self.parse_realign_command( arguments:, error: )
			options = { json: false }
			realign_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson realign [--json]"
				parser.separator ""
				parser.separator "Realign the current branch with the latest main and safely update the remote branch."
				parser.separator ""
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			realign_parser.parse!( arguments )
			unless arguments.empty?
				error.puts "#{BADGE} Unexpected arguments for realign: #{arguments.join( ' ' )}"
				error.puts realign_parser
				return { command: :invalid }
			end
			{ command: "realign", json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts realign_parser
			{ command: :invalid }
		end

		def self.parse_revert_command( arguments:, error: )
			options = { json: false }
			revert_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson revert <pr-number-or-sha> [--json]"
				parser.separator ""
				parser.separator "Create a dedicated revert branch/worktree for merged work and hand off to deliver."
				parser.separator ""
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			revert_parser.parse!( arguments )
			target = arguments.shift
			if target.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson revert <pr-number-or-sha> [--json]"
				error.puts revert_parser
				return { command: :invalid }
			end
			{ command: "revert", target: target, json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts revert_parser
			{ command: :invalid }
		end

		def self.parse_release_command( arguments:, error: )
			options = { json: false, notes_file: nil, draft: false }
			release_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson release <version> [--notes-file PATH] [--draft] [--json]"
				parser.separator ""
				parser.separator "Tag and publish an already-prepared release from main."
				parser.separator ""
				parser.on( "--notes-file PATH", "File containing release notes" ) { |value| options[ :notes_file ] = value }
				parser.on( "--draft", "Create the GitHub release as a draft" ) { options[ :draft ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
			end
			release_parser.parse!( arguments )
			version = arguments.shift
			if version.to_s.strip.empty? || arguments.any?
				error.puts "#{BADGE} Usage: carson release <version> [--notes-file PATH] [--draft] [--json]"
				error.puts release_parser
				return { command: :invalid }
			end
			{ command: "release", version: version, notes_file: options[ :notes_file ], draft: options[ :draft ], json: options[ :json ] }
		rescue OptionParser::ParseError => exception
			error.puts "#{BADGE} #{exception.message}"
			error.puts release_parser
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
			options = { all: false, json: false }
			housekeep_parser = OptionParser.new do |parser|
				parser.banner = "Usage: carson housekeep [REPO] [--all] [--json]"
				parser.separator ""
				parser.separator "Run housekeeping: sync main, reap dead worktrees, and prune stale branches."
				parser.separator "Defaults to the current repository."
				parser.separator ""
				parser.separator "Options:"
				parser.on( "--all", "Housekeep all governed repositories" ) { options[ :all ] = true }
				parser.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				parser.separator ""
				parser.separator "Examples:"
				parser.separator "    carson housekeep           Housekeep the current repository"
				parser.separator "    carson housekeep nexus     Housekeep a named governed repo"
				parser.separator "    carson housekeep --all     Housekeep all governed repos"
			end
			housekeep_parser.parse!( arguments )

			if options[ :all ] && !arguments.empty?
				error.puts "#{BADGE} --all and repo target are mutually exclusive. Use: carson housekeep --all OR carson housekeep [repo]"
				return { command: :invalid }
			end

			return { command: "housekeep:all", json: options[ :json ] } if options[ :all ]

			if arguments.length > 1
				error.puts "#{BADGE} Too many arguments for housekeep. Use: carson housekeep [repo]"
				return { command: :invalid }
			end

			target = arguments.shift
			return { command: "housekeep:target", target: target, json: options[ :json ] } if target

			{ command: "housekeep", json: options[ :json ] }
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
					pr_only: parsed.fetch( :pr_only, false ),
					merge: parsed.fetch( :merge, false ),
					title: parsed.fetch( :title, nil ),
					body_file: parsed.fetch( :body_file, nil ),
					json_output: parsed.fetch( :json, false )
				)
			when "realign"
				runtime.realign!( json_output: parsed.fetch( :json, false ) )
			when "revert"
				runtime.revert!( target: parsed.fetch( :target ), json_output: parsed.fetch( :json, false ) )
			when "release"
				runtime.release!(
					version: parsed.fetch( :version ),
					notes_file: parsed.fetch( :notes_file, nil ),
					draft: parsed.fetch( :draft, false ),
					json_output: parsed.fetch( :json, false )
				)
			when "review:gate"
				runtime.review_gate!
			when "review:sweep"
				runtime.review_sweep!
			when "review:comment"
				runtime.send( :review_comment!, pr_number: parsed.fetch( :pr_number ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "review:reply"
				runtime.send( :review_reply!, target_url: parsed.fetch( :target_url ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "review:approve"
				runtime.send( :review_approve!, pr_number: parsed.fetch( :pr_number ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "review:request-changes"
				runtime.send( :review_request_changes!, pr_number: parsed.fetch( :pr_number ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "review:disposition"
				runtime.send( :review_disposition!, target_url: parsed.fetch( :target_url ), disposition: parsed.fetch( :disposition ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "track:open"
				runtime.track_open!( title: parsed.fetch( :title, nil ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "track:comment"
				runtime.track_comment!( issue_number: parsed.fetch( :issue_number ), body: parsed.fetch( :body, nil ), body_file: parsed.fetch( :body_file, nil ), json_output: parsed.fetch( :json, false ) )
			when "track:close"
				runtime.track_close!( issue_number: parsed.fetch( :issue_number ), json_output: parsed.fetch( :json, false ) )
			when "track:reopen"
				runtime.track_reopen!( issue_number: parsed.fetch( :issue_number ), json_output: parsed.fetch( :json, false ) )
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
