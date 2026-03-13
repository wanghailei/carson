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
					result[ :recovery ] = "carson worktree create <name>"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				# Step 1: sync managed template files before push.
				# `push_prep: true` stages and commits managed drift so the subsequent
				# push carries the canonical content even though deliver uses --no-verify.
				# Output is captured to prevent pollution of --json mode.
				# Diagnostics are preserved for error reporting.
				sync_exit, sync_diagnostics = begin
					saved_output, saved_error = @output, @error
					captured_out = StringIO.new
					captured_err = StringIO.new
					@output = captured_out
					@error = captured_err
					exit_code = template_apply!( push_prep: true )
					[ exit_code, captured_out.string + captured_err.string ]
				rescue StandardError => exception
					[ EXIT_ERROR, "template sync error: #{exception.message}" ]
				ensure
					@output, @error = saved_output, saved_error
				end

				if sync_exit == EXIT_ERROR
					result[ :error ] = sync_diagnostics.to_s.strip.empty? ? "template sync failed" : sync_diagnostics.strip
					return deliver_finish( result: result, exit_code: sync_exit, json_output: json_output )
				end

				# Step 2: push the branch.
				push_exit = push_branch!( branch: branch, remote: remote, result: result )
				return deliver_finish( result: result, exit_code: push_exit, json_output: json_output ) unless push_exit == EXIT_OK

				# Step 3: find or create the PR.
				pr_number, pr_url = find_or_create_pr!(
					branch: branch, title: title, body_file: body_file, result: result
				)
				if pr_number.nil?
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				result[ :pr_number ] = pr_number
				result[ :pr_url ] = pr_url
				# Without --merge, we are done.
				unless merge
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				# Step 4: check CI status.
				ci_status = check_pr_ci( number: pr_number )
				result[ :ci ] = ci_status.to_s

				case ci_status
				when :pass, :none
					# Continue to review gate. :none means no checks configured — nothing to wait for.
				when :pending
					result[ :recovery ] = "gh pr checks #{pr_number} --watch && carson deliver --merge"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				when :fail
					result[ :recovery ] = "gh pr checks #{pr_number} — fix failures, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				# Step 5: check review gate — block on unresolved review debt.
				review = check_pr_review( number: pr_number, branch: branch, pr_url: pr_url )
				result[ :review ] = review.fetch( :review ).to_s
				if review.fetch( :review ) == :changes_requested
					result[ :error ] = "review changes requested on PR ##{pr_number}"
					result[ :recovery ] = "address review comments, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end
				if review.fetch( :status ) == :fail
					result[ :error ] = "review gate blocked on PR ##{pr_number}: #{review.fetch( :detail )}"
					result[ :recovery ] = "resolve review gate blockers, push, then `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end
				if review.fetch( :status ) == :error
					result[ :error ] = "unable to evaluate review gate for PR ##{pr_number}: #{review.fetch( :detail )}"
					result[ :recovery ] = "run `carson review gate`, then retry `carson deliver --merge`"
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				# Step 6: merge.
				merge_exit = merge_pr!( number: pr_number, result: result )
				return deliver_finish( result: result, exit_code: merge_exit, json_output: json_output ) unless merge_exit == EXIT_OK

				result[ :merged ] = true

				# Step 7: sync main in the main worktree.
				sync_after_merge!( remote: remote, main: main, result: result )

				# Step 8: compute next-step guidance for the agent.
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

			# Pushes the branch to the remote with tracking.
			# Uses --no-verify to skip the pre-push hook that Carson itself installed.
			# The hook blocks raw pushes unconditionally; Carson bypasses by skipping it.
			# Template sync (previously in the hook) now runs in deliver! before push.
			# On non-fast-forward rejection (typically after rebase), retries with
			# --force-with-lease — a protected force push that rejects if the remote
			# ref has been updated by another actor since the last fetch.
			def push_branch!( branch:, remote:, result: )
				_, push_stderr, push_success, = git_run( "push", "--no-verify", "-u", remote, branch )

				if !push_success && push_stderr.to_s.include?( "non-fast-forward" )
					return force_push_with_lease!( branch: branch, remote: remote, result: result )
				end

				unless push_success
					error_text = push_stderr.to_s.strip
					error_text = "push failed" if error_text.empty?
					result[ :error ] = error_text
					return EXIT_ERROR
				end
				puts_verbose "pushed #{branch} to #{remote}"
				EXIT_OK
			end

			# Retries push with --force-with-lease after a non-fast-forward rejection.
			# The lease check compares the local tracking ref against the remote — if
			# another actor pushed since our last fetch, the push is refused ("stale info").
			# This is atomic and safe, unlike delete-and-re-push.
			def force_push_with_lease!( branch:, remote:, result: )
				puts_verbose "push rejected (non-fast-forward), retrying with --force-with-lease"
				_, lease_stderr, lease_success, = git_run( "push", "--no-verify", "--force-with-lease", "-u", remote, branch )

				if lease_success
					puts_verbose "pushed #{branch} to #{remote} (force-with-lease)"
					return EXIT_OK
				end

				# --force-with-lease rejected — another actor pushed to this branch.
				if lease_stderr.to_s.include?( "stale info" )
					result[ :error ] = "force-with-lease rejected — another push landed on #{branch} since your last fetch"
					result[ :recovery ] = "git fetch #{remote} #{branch} && carson deliver"
				else
					error_text = lease_stderr.to_s.strip
					error_text = "push failed (force-with-lease)" if error_text.empty?
					result[ :error ] = error_text
				end
				EXIT_ERROR
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
			# gh pr view returns any PR on the branch — open, merged, or closed.
			# We check state explicitly so merged/closed PRs are treated as absent,
			# letting find_or_create_pr! fall through to create a new PR.
			def find_existing_pr( branch: )
				stdout, _, success, = gh_run(
					"pr", "view", branch,
					"--json", "number,url,state"
				)
				if success
					data = JSON.parse( stdout ) rescue nil
					if data && data[ "number" ] && data[ "state" ] == "OPEN"
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
				branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { it.upcase }
			end

			# Checks CI status on a PR. Returns :pass, :fail, :pending, or :none.
			# Uses the `bucket` field (pass/fail/pending) from `gh pr checks --json`.
			def check_pr_ci( number: )
				stdout, _, success, = gh_run(
					"pr", "checks", number.to_s,
					"--json", "name,bucket"
				)
				return :none unless success

				checks = JSON.parse( stdout ) rescue []
				return :none if checks.empty?

				buckets = checks.map { it[ "bucket" ].to_s.downcase }
				return :fail if buckets.include?( "fail" )
				return :pending if buckets.include?( "pending" )

				:pass
			end

			# Checks the full review gate on a PR. Returns a structured result hash.
			def check_pr_review( number:, branch:, pr_url: nil )
				owner, repo = repository_coordinates
				report = review_gate_report_for_pr(
					owner: owner,
					repo: repo,
					pr_number: number,
					branch_name: branch,
					pr_summary: {
						number: number,
						title: "",
						url: pr_url.to_s,
						state: "OPEN"
					}
				)
				review_gate_result( report: report )
			rescue StandardError => exception
				{ status: :error, review: :error, detail: exception.message }
			end

			# Merges the PR using the configured merge method.
			# Deliberately omits --delete-branch: gh tries to switch the local
			# checkout to main afterwards, which fails inside a worktree where
			# main is already checked output. Branch cleanup deferred to `carson prune`.
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
