# Close abandoned delivery work and clean up its branch/worktree when safe.
module Carson
	class Runtime
		module Abandon
			def abandon!( target:, json_output: false )
				result = { command: "abandon", target: target }

				unless gh_available?
					result[ :error ] = "gh CLI is required for carson abandon"
					result[ :recovery ] = "install and authenticate gh, then retry"
					return abandon_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				resolution = resolve_abandon_target( target: target )
				if resolution.nil?
					result[ :error ] = "no branch or pull request found for #{target}"
					result[ :recovery ] = "use a PR number, PR URL, or existing branch name"
					return abandon_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				branch = resolution.fetch( :branch )
				pull_request = resolution.fetch( :pull_request )
				worktree = resolution.fetch( :worktree )

				result[ :branch ] = branch
				result[ :pr_number ] = pull_request&.fetch( :number, nil )
				result[ :pr_url ] = pull_request&.fetch( :url, nil )
				result[ :worktree_path ] = worktree&.path

				preflight = abandon_preflight_issue( branch: branch, worktree: worktree )
				unless preflight.nil?
					result[ :error ] = preflight.fetch( :error )
					result[ :recovery ] = preflight.fetch( :recovery )
					return abandon_finish( result: result, exit_code: preflight.fetch( :exit_code ), json_output: json_output )
				end

				if pull_request&.fetch( :state ) == "OPEN"
					close_exit = close_pull_request!( number: pull_request.fetch( :number ), result: result )
					return abandon_finish( result: result, exit_code: close_exit, json_output: json_output ) unless close_exit == EXIT_OK
					result[ :pull_request_closed ] = true
				else
					result[ :pull_request_closed ] = false
				end

				if worktree
					remove_exit = with_captured_output do
						worktree_remove!( worktree_path: worktree.path, skip_unpushed: true, json_output: false )
					end
					unless remove_exit == EXIT_OK
						result[ :error ] = "worktree cleanup failed for #{worktree.path}"
						result[ :recovery ] = "run carson worktree remove #{File.basename( worktree.path )}"
						return abandon_finish( result: result, exit_code: remove_exit, json_output: json_output )
					end

					result[ :worktree_removed ] = true
					result[ :branch_deleted ] = !local_branch_exists?( branch: branch )
					result[ :remote_deleted ] = !remote_branch_exists?( branch: branch )
				else
					branch_deleted, remote_deleted = delete_branch_refs!( branch: branch )
					result[ :worktree_removed ] = false
					result[ :branch_deleted ] = branch_deleted
					result[ :remote_deleted ] = remote_deleted
				end

				mark_delivery_abandoned!( branch: branch )
				result[ :summary ] = "abandoned delivery cleaned up"
				abandon_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			def resolve_abandon_target( target: )
				pull_request = pull_request_from_target( target: target )
				branch = pull_request&.fetch( :branch ) || target.to_s.strip
				branch = branch_from_pull_request_url( target: target ) if branch.empty?
				return nil if branch.to_s.strip.empty?

				worktree = worktree_list.find { |entry| entry.branch == branch && entry.path != main_worktree_root }
				branch_exists = local_branch_exists?( branch: branch ) || remote_branch_exists?( branch: branch ) || !pull_request.nil?
				return nil unless branch_exists

				{
					branch: branch,
					pull_request: pull_request,
					worktree: worktree
				}
			end

			def pull_request_from_target( target: )
				number = pull_request_number_from_target( target: target )
				return pull_request_details_for_number( number: number ) unless number.nil?

				pull_request = worktree_pull_request( branch: target )
				return nil if pull_request.fetch( :number ).nil?

				{
					number: pull_request.fetch( :number ),
					url: pull_request.fetch( :url ),
					state: pull_request.fetch( :state ),
					branch: target
				}
			end

			def pull_request_number_from_target( target: )
				text = target.to_s.strip
				return Integer( text ) if text.match?( /\A\d+\z/ )

				match = text.match( %r{/pull/(\d+)} )
				return nil if match.nil?

				Integer( match[ 1 ] )
			rescue ArgumentError
				nil
			end

			def pull_request_details_for_number( number: )
				stdout_text, stderr_text, success, = gh_run(
					"pr", "view", number.to_s,
					"--json", "number,url,state,headRefName"
				)
				return nil unless success

				data = JSON.parse( stdout_text )
				{
					number: data.fetch( "number" ),
					url: data.fetch( "url" ).to_s,
					state: data.fetch( "state" ).to_s,
					branch: data.fetch( "headRefName" ).to_s
				}
			rescue JSON::ParserError
				nil
			end

			# Abandon is an intentional discard: committed-but-unpushed work
			# does not block abandonment. Only uncommitted (dirty) worktree
			# changes block, because those may be accidental.
			def abandon_preflight_issue( branch:, worktree: )
				if config.protected_branches.include?( branch )
					return { exit_code: EXIT_BLOCK, error: "cannot abandon protected branch #{branch}", recovery: "choose a feature branch instead" }
				end

				if worktree
					check = worktree_warehouse.assess_removal( worktree, force: false, skip_unpushed: true )
					return nil if check.fetch( :status ) == :ok

					recovery = check[ :recovery ]
					if check[ :error ] == "worktree has uncommitted changes"
						recovery = "commit or discard the changes, then retry carson abandon #{branch}"
					end

					exit_code = check[ :status ] == :block ? EXIT_BLOCK : EXIT_ERROR
					return {
						exit_code: exit_code,
						error: check[ :error ],
						recovery: recovery
					}
				end

				return { exit_code: EXIT_BLOCK, error: "current branch is #{branch}", recovery: "switch to main or a different branch, then retry" } if current_branch == branch
				nil
			end

			def close_pull_request!( number:, result: )
				_, stderr_text, success, = gh_run( "pr", "close", number.to_s )
				return EXIT_OK if success

				result[ :error ] = gh_error_text( stdout_text: "", stderr_text: stderr_text, fallback: "unable to close pull request ##{number}" )
				result[ :recovery ] = "gh pr close #{number}"
				EXIT_ERROR
			end

			def delete_branch_refs!( branch: )
				branch_deleted = false
				remote_deleted = false

				if local_branch_exists?( branch: branch ) && !config.protected_branches.include?( branch )
					_, _, success, = git_run( "branch", "-D", branch )
					branch_deleted = success
				end

				if remote_branch_exists?( branch: branch ) && !config.protected_branches.include?( branch )
					_, _, success, = git_run( "push", config.git_remote, "--delete", branch )
					remote_deleted = success
				end

				[ branch_deleted, remote_deleted ]
			end

			def local_branch_exists?( branch: )
				_, _, success, = git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{branch}" )
				success
			end

			def remote_branch_exists?( branch: )
				stdout_text, _, success, = git_run( "ls-remote", "--heads", config.git_remote, branch )
				return false unless success

				!stdout_text.to_s.strip.empty?
			end

			def mark_delivery_abandoned!( branch: )
				delivery = ledger.active_delivery( repo_path: repository_record.path, branch_name: branch )
				return if delivery.nil?

				ledger.update_delivery(
					delivery: delivery,
					status: "failed",
					cause: "abandoned",
					summary: "abandoned by carson abandon"
				)
			end

			def branch_from_pull_request_url( target: )
				number = pull_request_number_from_target( target: target )
				return "" if number.nil?

				pull_request_details_for_number( number: number )&.fetch( :branch, "" ).to_s
			end

			def abandon_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					if result[ :error ]
						puts_line result.fetch( :error )
						puts_line "  → #{result.fetch( :recovery )}" if result[ :recovery ]
					else
						pr_ref = result[ :pr_number ] ? "PR ##{result[ :pr_number ]}" : "no PR"
						puts_line "Abandoned #{result.fetch( :branch )} (#{pr_ref})."
						puts_line "  #{result.fetch( :summary )}"
					end
				end

				exit_code
			end
		end

		include Abandon
	end
end
