# frozen_string_literal: true

require "open3"

module Butler
	module Adapters
		class Git
			def initialize( repo_root:, out:, err: )
				@repo_root = repo_root
				@out = out
				@err = err
			end

			def run( *args )
				stdout_text, stderr_text, status = Open3.capture3( "git", *args, chdir: repo_root )
				[ stdout_text, stderr_text, status.success?, status.exitstatus ]
			end

			def system!( *args )
				stdout_text, stderr_text, success, = run( *args )
				out.print stdout_text unless stdout_text.empty?
				err.print stderr_text unless stderr_text.empty?
				raise "git #{args.join( ' ' )} failed" unless success
			end

			def capture!( *args )
				stdout_text, stderr_text, success, = run( *args )
				unless success
					err.print stderr_text unless stderr_text.empty?
					raise "git #{args.join( ' ' )} failed"
				end
				stdout_text
			end

			def capture_soft( *args )
				stdout_text, stderr_text, success, = run( *args )
				[ stdout_text, stderr_text, success ]
			end

		private

			attr_reader :repo_root, :out, :err
		end
	end
end
