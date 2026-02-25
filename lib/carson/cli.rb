require "optparse"

module Carson
	class CLI
		def self.start( argv:, repo_root:, tool_root:, out:, err: )
			parsed = parse_args( argv: argv, out: out, err: err )
			command = parsed.fetch( :command )
			return Runtime::EXIT_OK if command == :help

			if command == "version"
				out.puts Carson::VERSION
				return Runtime::EXIT_OK
			end

			target_repo_root = parsed.fetch( :repo_root, nil )
			target_repo_root = repo_root if target_repo_root.to_s.strip.empty?
			unless Dir.exist?( target_repo_root )
				err.puts "ERROR: repository path does not exist: #{target_repo_root}"
				return Runtime::EXIT_ERROR
			end

			runtime = Runtime.new( repo_root: target_repo_root, tool_root: tool_root, out: out, err: err )
			dispatch( parsed: parsed, runtime: runtime )
		rescue ConfigError => e
			err.puts "CONFIG ERROR: #{e.message}"
			Runtime::EXIT_ERROR
		rescue StandardError => e
			err.puts "ERROR: #{e.message}"
			Runtime::EXIT_ERROR
		end

		def self.parse_args( argv:, out:, err: )
			parser = build_parser
			preset = parse_preset_command( argv: argv, out: out, parser: parser )
			return preset unless preset.nil?

			command = argv.shift
			parse_command( command: command, argv: argv, parser: parser, err: err )
		rescue OptionParser::ParseError => e
			err.puts e.message
			err.puts parser
			{ command: :invalid }
		end

		def self.build_parser
			OptionParser.new do |opts|
				opts.banner = "Usage: carson [audit|sync|prune|hook|check|init [repo_path]|offboard [repo_path]|template check|template apply|lint setup --source <path-or-git-url>|review gate|review sweep|version]"
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
			when "init", "offboard"
				parse_repo_path_command( command: command, argv: argv, parser: parser, err: err )
			when "template"
				parse_named_subcommand( command: command, usage: "check|apply", argv: argv, parser: parser, err: err )
			when "lint"
				parse_lint_subcommand( argv: argv, parser: parser, err: err )
			when "review"
				parse_named_subcommand( command: command, usage: "gate|sweep", argv: argv, parser: parser, err: err )
			else
				parser.parse!( argv )
				{ command: command }
			end
		end

		def self.parse_repo_path_command( command:, argv:, parser:, err: )
			parser.parse!( argv )
			if argv.length > 1
				err.puts "Too many arguments for #{command}. Use: carson #{command} [repo_path]"
				err.puts parser
				return { command: :invalid }
			end

			repo_path = argv.first
			{
				command: command,
				repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
			}
		end

		def self.parse_named_subcommand( command:, usage:, argv:, parser:, err: )
			action = argv.shift
			parser.parse!( argv )
			if action.to_s.strip.empty?
				err.puts "Missing subcommand for #{command}. Use: carson #{command} #{usage}"
				err.puts parser
				return { command: :invalid }
			end
			{ command: "#{command}:#{action}" }
		end

		def self.parse_lint_subcommand( argv:, parser:, err: )
			action = argv.shift
			unless action == "setup"
				err.puts "Missing or invalid subcommand for lint. Use: carson lint setup --source <path-or-git-url> [--ref <git-ref>] [--force]"
				err.puts parser
				return { command: :invalid }
			end

			options = {
				source: nil,
				ref: "main",
				force: false
			}
			lint_parser = OptionParser.new do |opts|
				opts.banner = "Usage: carson lint setup --source <path-or-git-url> [--ref <git-ref>] [--force]"
				opts.on( "--source SOURCE", "Source repository path or git URL that contains CODING/" ) { |value| options[ :source ] = value.to_s.strip }
				opts.on( "--ref REF", "Git ref used when --source is a git URL (default: main)" ) { |value| options[ :ref ] = value.to_s.strip }
				opts.on( "--force", "Overwrite existing files in ~/AI/CODING" ) { options[ :force ] = true }
			end
			lint_parser.parse!( argv )
			if options.fetch( :source ).to_s.empty?
				err.puts "Missing required --source for lint setup."
				err.puts lint_parser
				return { command: :invalid }
			end
			unless argv.empty?
				err.puts "Unexpected arguments for lint setup: #{argv.join( ' ' )}"
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
			err.puts e.message
			err.puts lint_parser
			{ command: :invalid }
		end

		def self.dispatch( parsed:, runtime: )
			command = parsed.fetch( :command )
			return Runtime::EXIT_ERROR if command == :invalid

			case command
			when "audit"
				runtime.audit!
			when "sync"
				runtime.sync!
			when "prune"
				runtime.prune!
			when "hook"
				runtime.hook!
			when "check"
				runtime.check!
			when "init"
				runtime.init!
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
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
