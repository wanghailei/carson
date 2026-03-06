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

			if %w[refresh:all prune:all].include?( command )
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
			result = parse_command( command: command, argv: argv, parser: parser, err: err )
			result.merge( verbose: verbose )
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			err.puts parser
			{ command: :invalid }
		end

		def self.build_parser
			OptionParser.new do |opts|
				opts.banner = "Usage: carson [status [--json]|setup|audit [--json]|sync [--json]|deliver [--merge] [--json] [--title T] [--body-file F]|prune [--all] [--json]|worktree create|done|remove <name>|onboard|refresh [--all]|offboard|template check|apply|review gate|sweep|govern [--dry-run] [--json] [--loop SECONDS]|version]"
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

		def self.parse_command( command:, argv:, parser:, err: )
			case command
			when "version"
				parser.parse!( argv )
				{ command: "version" }
			when "setup"
				parse_setup_command( argv: argv, parser: parser, err: err )
			when "onboard", "offboard"
				parse_repo_path_command( command: command, argv: argv, parser: parser, err: err )
			when "refresh"
				parse_refresh_command( argv: argv, parser: parser, err: err )
			when "template"
				parse_template_subcommand( argv: argv, parser: parser, err: err )
			when "prune"
				parse_prune_command( argv: argv, parser: parser, err: err )
			when "worktree"
				parse_worktree_subcommand( argv: argv, parser: parser, err: err )
			when "review"
				parse_named_subcommand( command: command, usage: "gate|sweep", argv: argv, parser: parser, err: err )
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
				parser.parse!( argv )
				{ command: command }
			end
		end

		def self.parse_setup_command( argv:, parser:, err: )
			options = {}
			setup_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson setup [--remote NAME] [--main-branch NAME] [--workflow STYLE] [--merge METHOD] [--canonical PATH]"
				opts.on( "--remote NAME", "Git remote name" ) { |v| options[ "git.remote" ] = v }
				opts.on( "--main-branch NAME", "Main branch name" ) { |v| options[ "git.main_branch" ] = v }
				opts.on( "--workflow STYLE", "Workflow style (branch or trunk)" ) { |v| options[ "workflow.style" ] = v }
				opts.on( "--merge METHOD", "Merge method (squash, rebase, or merge)" ) { |v| options[ "govern.merge.method" ] = v }
				opts.on( "--canonical PATH", "Canonical template directory path" ) { |v| options[ "template.canonical" ] = v }
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

		def self.parse_repo_path_command( command:, argv:, parser:, err: )
			parser.parse!( argv )
			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for #{command}. Use: carson #{command} [repo_path]"
				err.puts parser
				return { command: :invalid }
			end

			repo_path = argv.first
			{
				command: command,
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		end

		def self.parse_refresh_command( argv:, parser:, err: )
			all_flag = argv.delete( "--all" ) ? true : false
			parser.parse!( argv )

			if all_flag && !argv.empty?
				err.puts "#{BADGE} --all and repo_path are mutually exclusive. Use: carson refresh --all OR carson refresh [repo_path]"
				err.puts parser
				return { command: :invalid }
			end

			return { command: "refresh:all" } if all_flag

			if argv.length > 1
				err.puts "#{BADGE} Too many arguments for refresh. Use: carson refresh [repo_path]"
				err.puts parser
				return { command: :invalid }
			end

			repo_path = argv.first
			{
				command: "refresh",
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		end

		def self.parse_prune_command( argv:, parser:, err: )
			all_flag = argv.delete( "--all" ) ? true : false
			json_flag = argv.delete( "--json" ) ? true : false
			parser.parse!( argv )
			return { command: "prune:all", json: json_flag } if all_flag
			{ command: "prune", json: json_flag }
		end

		def self.parse_worktree_subcommand( argv:, parser:, err: )
			action = argv.shift
			if action.to_s.strip.empty?
				err.puts "#{BADGE} Missing subcommand for worktree. Use: carson worktree create|done|remove <name>"
				err.puts parser
				return { command: :invalid }
			end

			case action
			when "create"
				name = argv.shift
				if name.to_s.strip.empty?
					err.puts "#{BADGE} Missing name for worktree create. Use: carson worktree create <name>"
					return { command: :invalid }
				end
				{ command: "worktree:create", worktree_name: name }
			when "done"
				name = argv.shift
				{ command: "worktree:done", worktree_name: name }
			when "remove"
				force = argv.delete( "--force" ) ? true : false
				worktree_path = argv.shift
				if worktree_path.to_s.strip.empty?
					err.puts "#{BADGE} Missing path for worktree remove. Use: carson worktree remove <name-or-path>"
					return { command: :invalid }
				end
				{ command: "worktree:remove", worktree_path: worktree_path, force: force }
			else
				err.puts "#{BADGE} Unknown worktree subcommand: #{action}. Use: carson worktree create|done|remove <name>"
				{ command: :invalid }
			end
		end

		def self.parse_named_subcommand( command:, usage:, argv:, parser:, err: )
			action = argv.shift
			parser.parse!( argv )
			if action.to_s.strip.empty?
				err.puts "#{BADGE} Missing subcommand for #{command}. Use: carson #{command} #{usage}"
				err.puts parser
				return { command: :invalid }
			end
			{ command: "#{command}:#{action}" }
		end

		def self.parse_template_subcommand( argv:, parser:, err: )
			action = argv.shift
			if action.to_s.strip.empty?
				err.puts "#{BADGE} Missing subcommand for template. Use: carson template check|apply"
				err.puts parser
				return { command: :invalid }
			end

			return { command: "template:#{action}" } unless action == "apply"

			options = { push_prep: false }
			apply_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson template apply [--push-prep]"
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

		def self.parse_audit_command( argv:, err: )
			json_flag = argv.delete( "--json" ) ? true : false
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for audit: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "audit", json: json_flag }
		end

		def self.parse_sync_command( argv:, err: )
			json_flag = argv.delete( "--json" ) ? true : false
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for sync: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "sync", json: json_flag }
		end

		def self.parse_status_command( argv:, err: )
			json_flag = argv.delete( "--json" ) ? true : false
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for status: #{argv.join( ' ' )}"
				return { command: :invalid }
			end
			{ command: "status", json: json_flag }
		end

		def self.parse_deliver_command( argv:, err: )
			options = { merge: false, json: false, title: nil, body_file: nil }
			deliver_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson deliver [--merge] [--json] [--title TITLE] [--body-file PATH]"
				opts.on( "--merge", "Also merge the PR if CI passes" ) { options[ :merge ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.on( "--title TITLE", "PR title (defaults to branch name)" ) { |v| options[ :title ] = v }
				opts.on( "--body-file PATH", "File containing PR body text" ) { |v| options[ :body_file ] = v }
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

		def self.parse_govern_subcommand( argv:, err: )
			options = {
				dry_run: false,
				json: false,
				loop_seconds: nil
			}
			govern_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson govern [--dry-run] [--json] [--loop SECONDS]"
				opts.on( "--dry-run", "Run all checks but do not merge or dispatch" ) { options[ :dry_run ] = true }
				opts.on( "--json", "Machine-readable JSON output" ) { options[ :json ] = true }
				opts.on( "--loop SECONDS", Integer, "Run continuously, sleeping SECONDS between cycles" ) do |s|
					err.puts( "#{BADGE} Error: --loop must be a positive integer" ) || ( return { command: :invalid } ) if s < 1
					options[ :loop_seconds ] = s
				end
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
				runtime.worktree_create!( name: parsed.fetch( :worktree_name ) )
			when "worktree:done"
				runtime.worktree_done!( name: parsed.fetch( :worktree_name, nil ) )
			when "worktree:remove"
				runtime.worktree_remove!( worktree_path: parsed.fetch( :worktree_path ), force: parsed.fetch( :force, false ) )
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
			when "govern"
				runtime.govern!(
					dry_run: parsed.fetch( :dry_run, false ),
					json_output: parsed.fetch( :json, false ),
					loop_seconds: parsed.fetch( :loop_seconds, nil )
				)
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
