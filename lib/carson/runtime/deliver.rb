# Branch delivery lifecycle — push, create/update PR, wait for merge readiness, and integrate when clear.
# `carson deliver` owns the synchronous happy path for single-branch delivery.
module Carson
	class Runtime
		module Deliver
			# Entry point for `carson deliver`.
			# Pushes the current branch, ensures a PR exists, records delivery state,
			# waits for merge readiness, and integrates when the path is clear.
			# When --commit is supplied, Carson creates one all-dirty agent-authored commit first.
			def deliver!( title: nil, body_file: nil, commit_message: nil, json_output: false )
				branch_name = current_branch
				main_branch = config.main_branch
				remote_name = config.git_remote
				result = { command: "deliver", branch: branch_name }

				if branch_name == main_branch
					result[ :error ] = "cannot deliver from #{main_branch}"
					result[ :recovery ] = "carson worktree create <name>"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				initial_dirty = working_tree_dirty?
				if initial_dirty && commit_message.to_s.strip.empty?
					result[ :error ] = "working tree is dirty"
					result[ :recovery ] = "carson deliver --commit \"describe this delivery\""
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if !initial_dirty && !commit_message.to_s.strip.empty?
					result[ :commit ] = blocked_commit_payload(
						message: commit_message,
						summary: "blocked — working tree is already clean"
					)
					result[ :error ] = "working tree is already clean"
					result[ :recovery ] = "carson deliver"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				sync_exit, sync_diagnostics = deliver_template_sync
				if sync_exit == EXIT_ERROR
					result[ :error ] = sync_diagnostics.to_s.strip.empty? ? "template sync failed" : sync_diagnostics.strip
					return deliver_finish( result: result, exit_code: sync_exit, json_output: json_output )
				end
				template_sync_committed = sync_exit == EXIT_BLOCK

				unless commit_message.to_s.strip.empty?
					commit_exit = prepare_delivery_commit!(
						commit_message: commit_message,
						template_sync_committed: template_sync_committed,
						result: result
					)
					return deliver_finish( result: result, exit_code: commit_exit, json_output: json_output ) unless commit_exit == EXIT_OK
				end

				push_exit = push_branch!( branch: branch_name, remote: remote_name, result: result )
				return deliver_finish( result: result, exit_code: push_exit, json_output: json_output ) unless push_exit == EXIT_OK

				pr_number, pr_url = find_or_create_pr!(
					branch: branch_name,
					title: title,
					body_file: body_file,
					result: result
				)
				return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output ) if pr_number.nil?

				branch = branch_record( name: branch_name )
				delivery = ledger.upsert_delivery(
					repository: repository_record,
					branch_name: branch.name,
					head: branch.head || current_head,
					worktree_path: branch.worktree || repo_root,
					pr_number: pr_number,
					pr_url: pr_url,
					status: "preparing",
					summary: "delivery accepted",
					cause: nil
				)
				delivery = assess_delivery!( delivery: delivery, branch_name: branch.name )
				delivery = wait_for_delivery_readiness!( delivery: delivery, branch_name: branch.name )
				delivery = integrate_delivery_now!(
					delivery: delivery,
					branch_name: branch.name,
					remote: remote_name,
					main: main_branch,
					result: result
				) if delivery.ready?

				result[ :pr_number ] = pr_number
				result[ :pr_url ] = pr_url
				result[ :ci ] = delivery.integrated? ? "pass" : check_pr_ci( number: pr_number ).to_s
				result[ :delivery ] = delivery_payload( delivery: delivery )
				result[ :main_branch ] = main_branch
				result[ :summary ] = delivery.summary
				result[ :next_step ] = deliver_next_step( delivery: delivery, result: result )

				deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			def prepare_delivery_commit!( commit_message:, template_sync_committed:, result: )
				if working_tree_dirty?
					return create_delivery_commit!( commit_message: commit_message, result: result )
				end

				if template_sync_committed
					result[ :commit ] = skipped_commit_payload(
						message: commit_message,
						summary: "skipped — template sync committed all pending changes"
					)
					return EXIT_OK
				end

				# The caller blocks the ordinary clean-tree case before template sync.
				# Keep this branch as a post-sync safety net so future sequencing changes
				# do not silently turn a clean tree into a successful no-op commit request.
				result[ :commit ] = blocked_commit_payload(
					message: commit_message,
					summary: "blocked — working tree is already clean"
				)
				result[ :error ] = "working tree is already clean"
				result[ :recovery ] = "carson deliver"
				EXIT_BLOCK
			end

			def create_delivery_commit!( commit_message:, result: )
				_, add_stderr, add_success, = git_run( "add", "-A" )
				unless add_success
					error_text = add_stderr.to_s.strip
					error_text = "git add failed" if error_text.empty?
					result[ :commit ] = blocked_commit_payload(
						message: commit_message,
						summary: "blocked — #{error_text}"
					)
					result[ :error ] = error_text
					result[ :recovery ] = "git status"
					return EXIT_ERROR
				end

				commit_stdout, commit_stderr, commit_success, = git_run( "commit", "-m", commit_message )
				unless commit_success
					error_text = [ commit_stderr.to_s.strip, commit_stdout.to_s.strip ].reject( &:empty? ).join( " | " )
					error_text = "git commit failed" if error_text.empty?
					result[ :commit ] = blocked_commit_payload(
						message: commit_message,
						summary: "blocked — #{error_text}"
					)
					result[ :error ] = error_text
					result[ :recovery ] = "git status"
					return EXIT_ERROR
				end

				result[ :commit ] = created_commit_payload(
					message: commit_message,
					head: current_head,
					summary: "created agent-authored commit"
				)
				EXIT_OK
			end

			def created_commit_payload( message:, head:, summary: )
				{
					status: "created",
					message: message,
					head: head,
					summary: summary
				}
			end

			def skipped_commit_payload( message:, summary: )
				{
					status: "skipped",
					message: message,
					head: nil,
					summary: summary
				}
			end

			def blocked_commit_payload( message:, summary: )
				{
					status: "blocked",
					message: message,
					head: nil,
					summary: summary
				}
			end

			def deliver_template_sync
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

			# Assesses delivery readiness and records Carson's current branch state.
			def assess_delivery!( delivery:, branch_name: )
				review = check_pr_review( number: delivery.pull_request_number, branch: branch_name, pr_url: delivery.pull_request_url )
				ci = check_pr_ci( number: delivery.pull_request_number )
				status, cause, summary = delivery_assessment( ci: ci, review: review )

				ledger.update_delivery(
					delivery: delivery,
					status: status,
					cause: cause,
					summary: summary,
					pr_number: delivery.pull_request_number,
					pr_url: delivery.pull_request_url,
					worktree_path: delivery.worktree_path
				)
			end

			def wait_for_delivery_readiness!( delivery:, branch_name: )
				return delivery unless delivery.status == "gated" && delivery.cause == "ci"
				return delivery unless config.govern_check_wait.positive?

				deadline = Process.clock_gettime( Process::CLOCK_MONOTONIC ) + config.govern_check_wait
				interval = deliver_ci_poll_seconds
				puts_verbose "waiting up to #{config.govern_check_wait}s for CI to settle"

				loop do
					remaining = deadline - Process.clock_gettime( Process::CLOCK_MONOTONIC )
					break if remaining <= 0

					sleep [ interval, remaining ].min
					delivery = assess_delivery!( delivery: delivery, branch_name: branch_name )
					break unless delivery.status == "gated" && delivery.cause == "ci"
				end

				delivery
			end

			def deliver_ci_poll_seconds
				seconds = config.review_poll_seconds.to_i
				seconds.positive? ? seconds : 5
			end

			def integrate_delivery_now!( delivery:, branch_name:, remote:, main:, result: )
				pr_state = pull_request_state( number: delivery.pull_request_number )
				if pr_state && pr_state[ "state" ] == "MERGED"
					integrated = ledger.update_delivery(
						delivery: delivery,
						status: "integrated",
						integrated_at: Time.now.utc.iso8601,
						summary: "integrated into #{main}"
					)
					sync_after_merge!( remote: remote, main: main, result: result )
					return integrated
				end

				if pr_state && pr_state[ "state" ] == "CLOSED"
					return ledger.update_delivery(
						delivery: delivery,
						status: "failed",
						cause: "policy",
						summary: "pull request closed without integration"
					)
				end

				prepared = ledger.update_delivery(
					delivery: delivery,
					status: "integrating",
					summary: "integrating into #{main}"
				)
				merge_exit = merge_pr!( number: prepared.pull_request_number, result: result )
				if merge_exit == EXIT_OK
					integrated = ledger.update_delivery(
						delivery: prepared,
						status: "integrated",
						integrated_at: Time.now.utc.iso8601,
						summary: "integrated into #{main}"
					)
					sync_after_merge!( remote: remote, main: main, result: result )
					return integrated
				end

				merge_error = result.delete( :error )
				merge_recovery = result.delete( :recovery )
				result[ :merge ] = {
					status: "blocked",
					summary: merge_error || "merge failed",
					recovery: merge_recovery,
					method: result[ :merge_method ]
				}
				ledger.update_delivery(
					delivery: prepared,
					status: "gated",
					cause: "policy",
					summary: result.dig( :merge, :summary )
				)
			end

			def delivery_assessment( ci:, review: )
				return [ "gated", "ci", "waiting for CI checks" ] if ci == :pending
				return [ "gated", "ci", "CI checks are failing" ] if ci == :fail
				return [ "gated", "review", "review changes requested" ] if review.fetch( :review, :none ) == :changes_requested
				return [ "gated", "review", "waiting for review" ] if review.fetch( :review, :none ) == :review_required
				return [ "gated", "review", review.fetch( :detail ).to_s ] if review.fetch( :status, :pass ) == :fail
				return [ "gated", "policy", "unable to assess review gate: #{review.fetch( :detail )}" ] if review.fetch( :status, :pass ) == :error

				[ "queued", nil, "ready to integrate into #{config.main_branch}" ]
			end

			def delivery_payload( delivery: )
				{
					id: delivery.id,
					status: delivery.status,
					head: delivery.head,
					worktree_path: delivery.worktree_path,
					revision_count: delivery.revision_count,
					cause: delivery.cause
				}
			end

			def deliver_next_step( delivery:, result: )
				return "carson sync" if delivery.integrated? && result[ :synced ] == false
				return "carson housekeep" if delivery.integrated?
				return "carson status" if delivery.blocked?

				nil
			end

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
				if result[ :error ]
					puts_line result[ :error ]
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				if result[ :delivery ]
					delivery_id = result.dig( :delivery, :id )
					branch = result[ :branch ]
					main = result[ :main_branch ] || "main"
					puts_line "Delivery ##{delivery_id}  #{branch} → #{main}"
				end
				if result[ :commit ]
					puts_line "Committed: #{result.dig( :commit, :summary )}"
				end
				puts_line "PR ##{result[ :pr_number ]}  #{result[ :pr_url ]}" if result[ :pr_number ]
				if result[ :delivery ]
					status = result.dig( :delivery, :status )
					summary = result[ :summary ]
					if status == "integrated"
						if result[ :merge_method ]
							puts_line "Merged into #{main} with #{result[ :merge_method ]}."
						else
							puts_line "Merged into #{main}."
						end
						if result[ :synced ] == false
							puts_line "Local #{main} sync failed — #{result[ :sync_error ]}."
						elsif result[ :synced ]
							puts_line "Synced local #{main}."
						end
					elsif status == "gated"
						puts_line "Held at gate — #{summary}."
						puts_line "  → #{result.dig( :merge, :recovery )}" if result.dig( :merge, :recovery )
					elsif status == "failed"
						puts_line "Delivery failed — #{summary}."
					else
						puts_line "All clear — #{summary}."
					end
				end
				puts_line "Check back with #{result[ :next_step ]}" if result[ :next_step ]
			end

			# Pushes the branch to the remote with tracking.
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
			def force_push_with_lease!( branch:, remote:, result: )
				puts_verbose "push rejected (non-fast-forward), retrying with --force-with-lease"
				_, lease_stderr, lease_success, = git_run( "push", "--no-verify", "--force-with-lease", "-u", remote, branch )

				if lease_success
					puts_verbose "pushed #{branch} to #{remote} (force-with-lease)"
					return EXIT_OK
				end

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
			def find_or_create_pr!( branch:, title: nil, body_file: nil, result: )
				existing = find_existing_pr( branch: branch )
				return existing if existing.first

				create_pr!( branch: branch, title: title, body_file: body_file, result: result )
			end

			# Queries gh for an open PR on this branch.
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

				pr_url = stdout.to_s.strip
				pr_number = pr_url.split( "/" ).last.to_i
				return [ pr_number, pr_url ] if pr_number > 0

				find_existing_pr( branch: branch )
			end

			def default_pr_title( branch: )
				branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { |character| character.upcase }
			end

			# Checks CI status on a PR. Returns :pass, :fail, :pending, or :none.
			def check_pr_ci( number: )
				stdout, _, success, = gh_run(
					"pr", "checks", number.to_s,
					"--json", "name,bucket"
				)
				return :none unless success

				checks = JSON.parse( stdout ) rescue []
				return :none if checks.empty?

				buckets = checks.map { |entry| entry[ "bucket" ].to_s.downcase }
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

			# Returns the current PR state for govern reconciliation.
			def pull_request_state( number: )
				stdout, _, success, = gh_run(
					"pr", "view", number.to_s,
					"--json", "number,state,isDraft,url"
				)
				return nil unless success

				JSON.parse( stdout )
			rescue JSON::ParserError
				nil
			end

			# Merges the PR using the governed merge method.
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
			def sync_after_merge!( remote:, main:, result: )
				main_root = main_worktree_root
				_, pull_stderr, pull_status, = Open3.capture3(
					"git", "-C", main_root, "pull", "--ff-only", remote, main
				)
				if pull_status.success?
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
