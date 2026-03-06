# PR delivery lifecycle — push, create PR, and optionally merge.
# Collapses the 8-step manual PR flow into one or two commands.
# `carson deliver` pushes and creates the PR.
# `carson deliver --merge` also merges if CI is green.
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
				push_exit = push_branch!( branch: branch, remote: remote, result: result )
				return deliver_finish( result: result, exit_code: push_exit, json_output: json_output ) unless push_exit == EXIT_OK

				# Step 2: find or create the PR.
				pr_number, pr_url = find_or_create_pr!(
					branch: branch, title: title, body_file: body_file, result: result
				)
				if pr_number.nil?
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				result[ :pr_number ] = pr_number
				result[ :pr_url ] = pr_url

				# Record PR in session state.
				update_session( pr: { number: pr_number, url: pr_url } )

				# Without --merge, we are done.
				unless merge
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				# Step 3: check CI status.
				ci_status = check_pr_ci( number: pr_number )
				result[ :ci ] = ci_status.to_s

				case ci_status
				when :pass
					# Continue to review gate.
				when :pending
					result[ :recovery ] = "gh pr checks #{pr_number} --watch && carson deliver --merge"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				when :fail
					result[ :recovery ] = "gh pr checks #{pr_number} — fix failures, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				else
					result[ :recovery ] = "gh pr checks #{pr_number}"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				# Step 4: check review gate — block if changes are requested.
				review = check_pr_review( number: pr_number )
				result[ :review ] = review.to_s
				if review == :changes_requested
					result[ :error ] = "review changes requested on PR ##{pr_number}"
					result[ :recovery ] = "address review comments, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				# Step 5: merge.
				merge_exit = merge_pr!( number: pr_number, result: result )
				return deliver_finish( result: result, exit_code: merge_exit, json_output: json_output ) unless merge_exit == EXIT_OK

				result[ :merged ] = true

				# Step 6: clear worktree from session state.
				update_session( worktree: :clear )

				# Step 7: sync main in the main worktree.
				sync_after_merge!( remote: remote, main: main, result: result )

				deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			# Outputs the final result — JSON or human-readable — and returns exit code.
			def deliver_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					out.puts JSON.pretty_generate( result )
				else
					print_deliver_human( result: result )
				end

				exit_code
			end

			# Human-readable output for deliver results.
			def print_deliver_human( result: )
				exit_code = result.fetch( :exit_code )

				if result[ :error ]
					puts_line "ERROR: #{result[ :error ]}"
					puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
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
					when "pending"
						puts_line "CI: pending — merge when checks complete."
						puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
					when "fail"
						puts_line "CI: failing — fix before merging."
						puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
					else
						puts_line "CI: #{ci} — check manually."
						puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
					end
				end

				if result[ :merged ]
					puts_line "Merged PR ##{result[ :pr_number ]} via #{result[ :merge_method ]}."
				end
			end

			# Pushes the branch to the remote with tracking.
			def push_branch!( branch:, remote:, result: )
				_, push_stderr, push_success, = git_run( "push", "-u", remote, branch )
				unless push_success
					error_text = push_stderr.to_s.strip
					error_text = "push failed" if error_text.empty?
					result[ :error ] = error_text
					result[ :recovery ] = "git pull #{remote} #{branch} --rebase && git push -u #{remote} #{branch}"
					return EXIT_ERROR
				end
				puts_verbose "pushed #{branch} to #{remote}"
				EXIT_OK
			end

			# Finds an existing PR for the branch, or creates a new one.
			# Returns [number, url] or [nil, nil] on failure.
			def find_or_create_pr!( branch:, title: nil, body_file: nil, result: )
				# Check for existing PR.
				existing = find_existing_pr( branch: branch )
				return existing if existing.first

				# Create a new PR.
				create_pr!( branch: branch, title: title, body_file: body_file, result: result )
			end

			# Queries gh for an open PR on this branch.
			# Returns [number, url] or [nil, nil].
			def find_existing_pr( branch: )
				stdout, _, success, = gh_run(
					"pr", "view", branch,
					"--json", "number,url"
				)
				if success
					data = JSON.parse( stdout ) rescue nil
					if data && data[ "number" ]
						return [ data[ "number" ], data[ "url" ].to_s ]
					end
				end
				[ nil, nil ]
			end

			# Creates a PR via gh. Title defaults to branch name humanised.
			# Returns [number, url] or [nil, nil] on failure.
			def create_pr!( branch:, title: nil, body_file: nil, result: )
				pr_title = title || default_pr_title( branch: branch )

				args = [ "pr", "create", "--title", pr_title, "--head", branch ]
				if body_file && File.exist?( body_file )
					args.push( "--body-file", body_file )
				else
					args.push( "--body", "" )
				end

				stdout, stderr, success, = gh_run( *args )
				unless success
					error_text = stderr.to_s.strip
					error_text = "pr create failed" if error_text.empty?
					result[ :error ] = error_text
					result[ :recovery ] = "gh pr create --title '#{pr_title}' --head #{branch}"
					return [ nil, nil ]
				end

				# gh pr create prints the URL on success. Parse number from it.
				pr_url = stdout.to_s.strip
				pr_number = pr_url.split( "/" ).last.to_i
				if pr_number > 0
					[ pr_number, pr_url ]
				else
					# Fallback: query the just-created PR.
					find_existing_pr( branch: branch )
				end
			end

			# Generates a default PR title from the branch name.
			def default_pr_title( branch: )
				branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { |c| c.upcase }
			end

			# Checks CI status on a PR. Returns :pass, :fail, :pending, or :none.
			def check_pr_ci( number: )
				stdout, _, success, = gh_run(
					"pr", "checks", number.to_s,
					"--json", "name,state,conclusion"
				)
				return :none unless success

				checks = JSON.parse( stdout ) rescue []
				return :none if checks.empty?

				conclusions = checks.map { |c| c[ "conclusion" ].to_s.upcase }
				states = checks.map { |c| c[ "state" ].to_s.upcase }

				return :fail if conclusions.any? { |c| c == "FAILURE" || c == "CANCELLED" || c == "TIMED_OUT" }
				return :pending if states.any? { |s| s == "PENDING" || s == "QUEUED" || s == "IN_PROGRESS" } ||
					conclusions.any? { |c| c == "" || c == "PENDING" }

				:pass
			end

			# Checks review decision on a PR. Returns :approved, :changes_requested, :review_required, or :none.
			def check_pr_review( number: )
				stdout, _, success, = gh_run(
					"pr", "view", number.to_s,
					"--json", "reviewDecision"
				)
				return :none unless success

				data = JSON.parse( stdout ) rescue {}
				decision = data[ "reviewDecision" ].to_s.strip.upcase
				case decision
				when "APPROVED" then :approved
				when "CHANGES_REQUESTED" then :changes_requested
				when "REVIEW_REQUIRED" then :review_required
				else :none
				end
			end

			# Merges the PR using the configured merge method.
			# Deliberately omits --delete-branch: gh tries to switch the local
			# checkout to main afterwards, which fails inside a worktree where
			# main is already checked out. Branch cleanup deferred to `carson prune`.
			def merge_pr!( number:, result: )
				method = config.govern_merge_method
				result[ :merge_method ] = method

				_, stderr, success, = gh_run(
					"pr", "merge", number.to_s,
					"--#{method}"
				)

				if success
					EXIT_OK
				else
					error_text = stderr.to_s.strip
					error_text = "merge failed" if error_text.empty?
					result[ :error ] = error_text
					result[ :recovery ] = "gh pr merge #{number} --#{method}"
					EXIT_ERROR
				end
			end

			# Syncs main after a successful merge.
			# Pulls into the main worktree directly — does not attempt checkout,
			# because checkout would fail when running inside a feature worktree
			# (main is already checked out in the main tree).
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
		end

		include Deliver
	end
end
