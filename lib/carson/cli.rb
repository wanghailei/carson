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

			if command == "refresh:all"
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
				opts.banner = "Usage: carson [setup|audit|sync|prune|prepare|inspect|onboard [repo_path]|refresh [--all|repo_path]|offboard [repo_path]|template check|template apply|lint policy --source <path-or-git-url>|review gate|review sweep|govern [--dry-run] [--json] [--loop SECONDS]|housekeep|version]"
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
			when "onboard", "offboard"
				parse_repo_path_command( command: command, argv: argv, parser: parser, err: err )
			when "refresh"
				parse_refresh_command( argv: argv, parser: parser, err: err )
			when "template"
				parse_named_subcommand( command: command, usage: "check|apply", argv: argv, parser: parser, err: err )
			when "lint"
				parse_lint_subcommand( argv: argv, parser: parser, err: err )
			when "review"
				parse_named_subcommand( command: command, usage: "gate|sweep", argv: argv, parser: parser, err: err )
			when "govern"
				parse_govern_subcommand( argv: argv, err: err )
			else
				parser.parse!( argv )
				{ command: command }
			end
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

		def self.parse_lint_subcommand( argv:, parser:, err: )
			action = argv.shift
			unless action == "policy"
				err.puts "#{BADGE} Missing or invalid subcommand for lint. Use: carson lint policy --source <path-or-git-url> [--ref <git-ref>] [--force]"
				err.puts parser
				return { command: :invalid }
			end

			options = {
				source: nil,
				ref: "main",
				force: false
			}
			lint_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson lint policy --source <path-or-git-url> [--ref <git-ref>] [--force]"
				opts.on( "--source SOURCE", "Source repository path or git URL that contains CODING/" ) { |value| options[ :source ] = value.to_s.strip }
				opts.on( "--ref REF", "Git ref used when --source is a git URL (default: main)" ) { |value| options[ :ref ] = value.to_s.strip }
				opts.on( "--force", "Overwrite existing files" ) { options[ :force ] = true }
			end
			lint_parser.parse!( argv )
			if options.fetch( :source ).to_s.empty?
				err.puts "#{BADGE} Missing required --source for lint policy."
				err.puts lint_parser
				return { command: :invalid }
			end
			unless argv.empty?
				err.puts "#{BADGE} Unexpected arguments for lint policy: #{argv.join( ' ' )}"
				err.puts lint_parser
				return { command: :invalid }
			end
			{
				command: "lint:setup",
				source: options.fetch( :source ),
				ref: options.fetch( :ref ),
				force: options.fetch( :force )
			}
		rescue OptionParser::ParseError => e
			err.puts "#{BADGE} #{e.message}"
			err.puts lint_parser
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
			when "setup"
				runtime.setup!
			when "audit"
				runtime.audit!
			when "sync"
				runtime.sync!
			when "prune"
				runtime.prune!
			when "prepare"
				runtime.prepare!
			when "inspect"
				runtime.inspect!
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
				runtime.template_apply!
			when "lint:setup"
				runtime.lint_setup!(
					source: parsed.fetch( :source ),
					ref: parsed.fetch( :ref ),
					force: parsed.fetch( :force )
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
			when "housekeep"
				runtime.housekeep!
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
