# Revert stream — create a revert branch/worktree from merged work, then hand off to deliver.
module Carson
	class Runtime
		module Revert
			def revert!( target:, json_output: false )
				result = { command: "revert", target: target.to_s }
				target_text = target.to_s.strip
				return revert_error_result( result: result, error: "revert target is required", recovery: "carson revert <pr-number-or-sha>", exit_code: EXIT_ERROR, json_output: json_output ) if target_text.empty?

				unless send( :working_tree_clean? )
					return revert_error_result( result: result, error: "working tree is dirty", recovery: "git add -A && git commit, then carson revert #{target_text}", exit_code: EXIT_BLOCK, json_output: json_output )
				end

					sync_exit = with_captured_output { sync!( json_output: true ) }
					if sync_exit != EXIT_OK
						return revert_error_result( result: result, error: "unable to sync #{config.main_branch} before revert", recovery: "carson sync", exit_code: EXIT_BLOCK, json_output: json_output )
					end

					commit_sha, target_label = resolve_revert_target( target: target_text, result: result )
					if commit_sha.nil?
						result[ :status ] ||= "blocked"
						return revert_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
					end
					result[ :commit ] = commit_sha

				worktree_name = revert_worktree_name( target_label: target_label )
				worktree_path = File.join( main_worktree_root, ".claude", "worktrees", worktree_name )
				create_exit = with_captured_output { worktree_create!( name: worktree_name, json_output: true ) }
				return revert_error_result( result: result, error: "unable to create revert worktree #{worktree_name}", recovery: "carson worktree create #{worktree_name}", exit_code: EXIT_ERROR, json_output: json_output ) unless create_exit == EXIT_OK

				result[ :worktree ] = worktree_name
				result[ :worktree_path ] = worktree_path

				_, revert_stderr, revert_success, = Open3.capture3( "git", "-C", worktree_path, "revert", "--no-edit", commit_sha )
				unless revert_success
					result[ :error ] = blank_to( value: revert_stderr, default: "git revert failed" )
					result[ :recovery ] = "cd #{worktree_path} && git revert --continue or git revert --abort"
					return revert_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				deliver_output = StringIO.new
				deliver_error = StringIO.new
				scoped_runtime = Runtime.new( repo_root: worktree_path, tool_root: tool_root, output: deliver_output, error: deliver_error, verbose: verbose? )
				deliver_exit = scoped_runtime.deliver!( title: "Revert #{target_label}", json_output: true )
				deliver_result = JSON.parse( deliver_output.string )
				result[ :deliver ] = deliver_result
				result[ :status ] = deliver_result[ "status" ] || ( deliver_result[ "merged" ] ? "merged" : "pending" )
				revert_finish( result: result, exit_code: deliver_exit, json_output: json_output )
			end

		private

			def resolve_revert_target( target:, result: )
				if target.match?( /\A\d+\z/ )
					resolve_revert_pull_request( number: target.to_i, result: result )
				else
					resolve_revert_commit( sha: target, result: result )
				end
			end

			def resolve_revert_pull_request( number:, result: )
				payload, stdout_text, stderr_text, success, = github_adapter.run_json( "pr", "view", number.to_s, "--json", "number,state,mergeCommit,url" )
				unless success && payload.is_a?( Hash )
					result[ :error ] = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to read PR ##{number}" )
					result[ :recovery ] = "gh pr view #{number}"
					return [ nil, nil ]
				end
				if payload[ "state" ].to_s != "MERGED"
					result[ :error ] = "PR ##{number} is not merged"
					result[ :recovery ] = "choose a merged PR or a commit on #{config.main_branch}"
					return [ nil, nil ]
				end
				merge_commit = payload.dig( "mergeCommit", "oid" ).to_s
				if merge_commit.empty?
					result[ :error ] = "PR ##{number} has no merge commit"
					result[ :recovery ] = "use a commit SHA from #{config.main_branch} instead"
					return [ nil, nil ]
				end
				[ merge_commit, "pr-#{number}" ]
			end

			def resolve_revert_commit( sha:, result: )
				_, stderr_text, success, = git_run( "rev-parse", "--verify", "#{sha}^{commit}" )
				unless success
					result[ :error ] = blank_to( value: stderr_text, default: "commit not found: #{sha}" )
					result[ :recovery ] = "use a merged PR number or a commit SHA on #{config.main_branch}"
					return [ nil, nil ]
				end

				_, _, ancestor_success, = git_run( "merge-base", "--is-ancestor", sha, config.main_branch )
				unless ancestor_success
					result[ :error ] = "commit #{sha} is not on #{config.main_branch}"
					result[ :recovery ] = "choose a commit that is already on #{config.main_branch}"
					return [ nil, nil ]
				end
				[ sha, sha[ 0, 12 ] ]
			end

			def revert_worktree_name( target_label: )
				sanitised = target_label.to_s.gsub( /[^a-zA-Z0-9._-]+/, "-" ).gsub( /-+/, "-" ).sub( /\A-/, "" ).sub( /-\z/, "" )
				sanitised = "target" if sanitised.empty?
				"revert-#{sanitised}"
			end

			def revert_error_result( result:, error:, recovery:, exit_code:, json_output: )
				result[ :status ] = exit_code == EXIT_BLOCK ? "blocked" : "error"
				result[ :error ] = error
				result[ :recovery ] = recovery
				revert_finish( result: result, exit_code: exit_code, json_output: json_output )
			end

			def revert_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code
				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_revert_human( result: result )
				end
				exit_code
			end

			def print_revert_human( result: )
				if result[ :error ]
					puts_line result.fetch( :error )
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				puts_line "Revert prepared in #{result.fetch( :worktree )}"
				deliver = result[ :deliver ] || {}
				if deliver[ "pr_number" ]
					puts_line "  PR: ##{deliver[ 'pr_number' ]} #{deliver[ 'pr_url' ]}"
				end
				if deliver[ "merged" ]
					puts_line "  Revert merged and #{config.main_branch} synced."
				elsif deliver[ "status" ] == "pending"
					puts_line "  Delivery pending — rerun `carson deliver` from #{result.fetch( :worktree_path )} or let `carson govern` finish it."
				end
			end
		end

		include Revert
	end
end
