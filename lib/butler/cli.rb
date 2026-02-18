require "optparse"

module Butler
	class CLI
		def self.start( argv:, repo_root:, tool_root:, out:, err: )
			parsed = parse_args( argv: argv, out: out, err: err )
			command = parsed.fetch( :command )
			return Runtime::EXIT_OK if command == :help
			if command == "version"
				out.puts Butler::VERSION
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
			parser = OptionParser.new do |opts|
				opts.banner = "Usage: butler [audit|sync|prune|hook|check|run [repo_path]|template check|template apply|review gate|review sweep|version]"
			end

			first = argv.first
			if [ "--help", "-h" ].include?( first )
				out.puts parser
				return { command: :help }
			end
			return { command: "version" } if [ "--version", "-v" ].include?( first )
			return { command: "audit" } if argv.empty?

			command = argv.shift
			case command
			when "version"
				parser.parse!( argv )
				{ command: "version" }
			when "run"
				parser.parse!( argv )
				if argv.length > 1
					err.puts "Too many arguments for run. Use: butler run [repo_path]"
					err.puts parser
					return { command: :invalid }
				end
				repo_path = argv.first
				{
					command: "run",
					repo_root: repo_path.to_s.strip.empty? ? nil : File.expand_path( repo_path )
				}
			when "template"
				action = argv.shift
				parser.parse!( argv )
				if action.to_s.strip.empty?
					err.puts "Missing subcommand for template. Use: butler template check|apply"
					err.puts parser
					return { command: :invalid }
				end
				{ command: "template:#{action}" }
			when "review"
				action = argv.shift
				parser.parse!( argv )
				if action.to_s.strip.empty?
					err.puts "Missing subcommand for review. Use: butler review gate|sweep"
					err.puts parser
					return { command: :invalid }
				end
				{ command: "review:#{action}" }
			else
				parser.parse!( argv )
				{ command: command }
			end
		rescue OptionParser::ParseError => e
			err.puts e.message
			err.puts parser
			{ command: :invalid }
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
			when "run"
				runtime.run!
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
