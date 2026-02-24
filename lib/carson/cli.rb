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
			dispatch( command: command, runtime: runtime )
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
				opts.banner = "Usage: carson [audit|sync|prune|hook|check|init [repo_path]|offboard [repo_path]|template check|template apply|review gate|review sweep|version]"
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

		def self.dispatch( command:, runtime: )
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
