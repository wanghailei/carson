# Executes gh CLI commands via Open3 for GitHub API access.
require "json"
require "open3"

module Carson
	module Adapters
		# Thin wrapper around the gh CLI for GitHub API access.
		class GitHub
			def initialize( repo_root: )
				@repo_root = repo_root
			end

			def run( *args )
				stdout_text, stderr_text, status = Open3.capture3( "gh", *args, chdir: repo_root )
				[ stdout_text, stderr_text, status.success?, status.exitstatus ]
			end

			def run_json( *args )
				stdout_text, stderr_text, success, exitstatus = run( *args )
				payload = parse_json( text: stdout_text )
				[ payload, stdout_text, stderr_text, success, exitstatus ]
			end

		private

			def parse_json( text: )
				value = text.to_s.strip
				return nil if value.empty?
				JSON.parse( value )
			rescue JSON::ParserError
				nil
			end

			attr_reader :repo_root
		end
	end
end
