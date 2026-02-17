require "open3"

module Butler
	module Adapters
		class GitHub
			def initialize( repo_root: )
				@repo_root = repo_root
			end

			def run( *args )
				stdout_text, stderr_text, status = Open3.capture3( "gh", *args, chdir: repo_root )
				[ stdout_text, stderr_text, status.success?, status.exitstatus ]
			end

		private

			attr_reader :repo_root
		end
	end
end
