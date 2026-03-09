# Executes git commands via Open3 and returns structured output.
require "open3"

module Carson
	module Adapters
		# Thin wrapper around the git CLI. Runs commands via Open3.
		class Git
			def initialize( repo_root: )
				@repo_root = repo_root
			end

			def run( *args )
				stdout_text, stderr_text, status = Open3.capture3( "git", *args, chdir: repo_root )
				[ stdout_text, stderr_text, status.success?, status.exitstatus ]
			end

		private

			attr_reader :repo_root
		end
	end
end
