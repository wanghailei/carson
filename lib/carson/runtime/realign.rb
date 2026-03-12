# Branch realignment stream — sync main, rebase, and safely update the remote branch.
module Carson
	class Runtime
		module Realign
			def realign!( json_output: false )
				branch = current_branch
				result = { command: "realign", branch: branch }

				if branch == config.main_branch
					result[ :error ] = "cannot realign #{config.main_branch}"
					result[ :recovery ] = "git switch -c <branch-name>"
					return realign_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				unless send( :working_tree_clean? )
					result[ :error ] = "working tree is dirty"
					result[ :recovery ] = "git add -A && git commit, then carson realign"
					return realign_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				sync_exit = with_captured_output { sync!( json_output: true ) }
				if sync_exit != EXIT_OK
					result[ :error ] = "unable to sync #{config.main_branch} before realign"
					result[ :recovery ] = "carson sync"
					return realign_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end
				result[ :synced_main ] = true

				_, rebase_stderr, rebase_success, = git_run( "rebase", config.main_branch )
				unless rebase_success
					result[ :error ] = blank_to( value: rebase_stderr, default: "rebase onto #{config.main_branch} failed" )
					result[ :recovery ] = "resolve conflicts, then git rebase --continue or git rebase --abort"
					return realign_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end
				result[ :rebased_onto ] = config.main_branch

				push_exit = realign_push_branch!( branch: branch, result: result )
				return realign_finish( result: result, exit_code: push_exit, json_output: json_output ) unless push_exit == EXIT_OK

				result[ :status ] = "ok"
				realign_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			def realign_push_branch!( branch:, result: )
				remote_ref = "refs/remotes/#{config.git_remote}/#{branch}"
				_, _, remote_exists, = git_run( "show-ref", "--verify", "--quiet", remote_ref )
				args = if remote_exists
					[ "push", "--no-verify", "--force-with-lease", "-u", config.git_remote, branch ]
				else
					[ "push", "--no-verify", "-u", config.git_remote, branch ]
				end
				_, stderr_text, success, = git_run( *args )
				return EXIT_OK if success

				result[ :error ] = blank_to( value: stderr_text, default: "unable to update #{branch} on #{config.git_remote}" )
				result[ :recovery ] = remote_exists ? "git fetch #{config.git_remote} #{branch} && carson realign" : "git push -u #{config.git_remote} #{branch}"
				EXIT_ERROR
			end

			def realign_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code
				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_realign_human( result: result )
				end
				exit_code
			end

			def print_realign_human( result: )
				if result[ :error ]
					puts_line result.fetch( :error )
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end
				puts_line "Realigned #{result.fetch( :branch )} onto #{result.fetch( :rebased_onto )}"
			end
		end

		include Realign
	end
end
