# frozen_string_literal: true

require "optparse"

module Butler
	class CLI
		def self.start( argv:, repo_root:, tool_root:, out:, err: )
			command = parse_args( argv: argv, out: out, err: err )
			return Runtime::EXIT_OK if command == :help
			if command == "version"
				out.puts Butler::VERSION
				return Runtime::EXIT_OK
			end

			runtime = Runtime.new( repo_root: repo_root, tool_root: tool_root, out: out, err: err )
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
				opts.banner = "Usage: butler [audit|sync|prune|hook|check|template check|template apply|review gate|review sweep|version]"
			end

			first = argv.first
			if [ "--help", "-h" ].include?( first )
				out.puts parser
				return :help
			end
			return "version" if [ "--version", "-v" ].include?( first )
			return "audit" if argv.empty?

			command = argv.shift
			case command
			when "version"
				parser.parse!( argv )
				"version"
			when "template"
				action = argv.shift
				parser.parse!( argv )
				"template:#{action}"
			when "review"
				action = argv.shift
				parser.parse!( argv )
				"review:#{action}"
			else
				parser.parse!( argv )
				command
			end
		rescue OptionParser::ParseError => e
			err.puts e.message
			err.puts parser
			:invalid
		end

		def self.dispatch( command:, runtime: )
			return Runtime::EXIT_ERROR if command == :invalid

			case command
			when "audit"
				Commands::Audit.run( runtime: runtime )
			when "sync"
				Commands::Sync.run( runtime: runtime )
			when "prune"
				Commands::Prune.run( runtime: runtime )
			when "hook"
				Commands::Hook.run( runtime: runtime )
			when "check"
				Commands::Check.run( runtime: runtime )
			when "template:check"
				Commands::TemplateCheck.run( runtime: runtime )
			when "template:apply"
				Commands::TemplateApply.run( runtime: runtime )
			when "review:gate"
				Commands::ReviewGate.run( runtime: runtime )
			when "review:sweep"
				Commands::ReviewSweep.run( runtime: runtime )
			else
				runtime.send( :puts_line, "Unknown command: #{command}" )
				Runtime::EXIT_ERROR
			end
		end
	end
end
