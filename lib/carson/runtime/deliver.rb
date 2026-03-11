# PR delivery lifecycle — push, create PR, and optionally merge.
# Collapses the 8-step manual PR flow into one or two commands.
# `carson deliver` pushes and creates the PR.
# `carson deliver --merge` also merges if CI passes or no checks are configured.
# `carson deliver --json` outputs structured result for agent consumption.
module Carson
	class Runtime
		module Deliver
			# Entry point for `carson deliver`.
			# Pushes current branch, creates a PR if needed, reports the PR URL.
			# With merge: true, also merges if CI passes and cleans up.
			def deliver!( merge: false, title: nil, body_file: nil, json_output: false )
				branch = current_branch
				main = config.main_branch
				remote = config.git_remote
				result = { command: "deliver", branch: branch }

				# Guard: cannot deliver from main.
				if branch == main
					result[ :error ] = "cannot deliver from #{main}"
					result[ :recovery ] = "git checkout -b <branch-name>"
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				# Step 1: push the branch.
				remote_obj = Remote.new( name: remote, runtime: self )
				begin
					remote_obj.push!( branch: branch )
					puts_verbose "pushed #{branch} to #{remote}"
				rescue Remote::Error => e
					if e.message.include?( "non-fast-forward" )
						begin
							puts_verbose "push rejected (non-fast-forward), retrying with --force-with-lease"
							remote_obj.force_push_with_lease!( branch: branch )
							puts_verbose "pushed #{branch} to #{remote} (force-with-lease)"
						rescue Remote::Error => e2
							result[ :error ] = e2.message
							result[ :recovery ] = e2.recovery
							return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
						end
					else
						result[ :error ] = e.message
						result[ :recovery ] = e.recovery
						return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
					end
				end

				# Step 2: find or create the PR.
				pr = PullRequest.find_open( branch: branch, runtime: self )
				unless pr
					begin
						pr = PullRequest.create!( branch: branch, title: title, body_file: body_file, runtime: self )
					rescue PullRequest::Error => e
						result[ :error ] = e.message
						result[ :recovery ] = e.recovery
						return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
					end
				end

				result[ :pr_number ] = pr.number
				result[ :pr_url ] = pr.url
				# Without --merge, we are done.
				unless merge
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				# Step 3: check CI status.
				ci_status = pr.ci_status
				result[ :ci ] = ci_status.to_s

				case ci_status
				when :pass, :none
					# Continue to review gate. :none means no checks configured — nothing to wait for.
				when :pending
					result[ :recovery ] = "gh pr checks #{pr.number} --watch && carson deliver --merge"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				when :fail
					result[ :recovery ] = "gh pr checks #{pr.number} — fix failures, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				# Step 4: check review gate — block if changes are requested.
				review = pr.review_decision
				result[ :review ] = review.to_s
				if review == :changes_requested
					result[ :error ] = "review changes requested on PR ##{pr.number}"
					result[ :recovery ] = "address review comments, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				# Step 5: merge.
				begin
					method = config.govern_merge_method
					result[ :merge_method ] = method
					pr.merge!( method: method )
				rescue PullRequest::Error => e
					result[ :error ] = e.message
					result[ :recovery ] = e.recovery
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				result[ :merged ] = true

				# Step 6: sync main in the main worktree.
				sync_after_merge!( remote: remote, main: main, result: result )

				# Step 7: compute next-step guidance for the agent.
				compute_post_merge_next_step!( result: result )

				deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			# Outputs the final result — JSON or human-readable — and returns exit code.
			def deliver_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_deliver_human( result: result )
				end

				exit_code
			end

			# Human-readable output for deliver results.
			def print_deliver_human( result: )
				exit_code = result.fetch( :exit_code )

				if result[ :error ]
					puts_line result[ :error ]
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				if result[ :pr_number ]
					puts_line "PR: ##{result[ :pr_number ]} #{result[ :pr_url ]}"
				end

				if result[ :ci ]
					ci = result[ :ci ]
					case ci
					when "pass"
						puts_line "CI: pass"
					when "none"
						puts_line "CI: none — no checks configured, proceeding."
					when "pending"
						puts_line "CI: pending — merge when checks complete."
						puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					when "fail"
						puts_line "CI: not passing yet — fix before merging."
						puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					end
				end

				if result[ :merged ]
					puts_line "Merged PR ##{result[ :pr_number ]} via #{result[ :merge_method ]}."
					puts_line "  Next: #{result[ :next_step ]}" if result[ :next_step ]
				end
			end

			# Syncs main after a successful merge.
			# Pulls into the main worktree directly — does not attempt checkout,
			# because checkout would fail when running inside a feature worktree
			# (main is already checked output in the main tree).
			def sync_after_merge!( remote:, main:, result: )
				main_root = main_worktree_root
				_, pull_stderr, pull_success, = Open3.capture3(
					"git", "-C", main_root, "pull", "--ff-only", remote, main
				)
				if pull_success
					result[ :synced ] = true
					puts_verbose "synced #{main} in #{main_root} from #{remote}"
				else
					result[ :synced ] = false
					result[ :sync_error ] = pull_stderr.to_s.strip
					puts_verbose "sync failed: #{pull_stderr.to_s.strip}"
				end
			end

			# Builds next-step guidance after a successful merge.
			# Detects whether the agent is inside a worktree and suggests cleanup.
			def compute_post_merge_next_step!( result: )
				main_root = main_worktree_root
				current_wt = worktree_list
					.reject { it.path == realpath_safe( main_root ) }
					.find { it.holds_cwd? }

				if current_wt
					wt_name = File.basename( current_wt.path )
					result[ :next_step ] = "cd #{main_root} && carson worktree remove #{wt_name}"
				else
					result[ :next_step ] = "carson prune"
				end
			rescue StandardError
				# Best-effort — do not fail deliver because of next-step detection.
			end
		end

		include Deliver
	end
end
