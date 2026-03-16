# Branch delivery lifecycle — push, create/update PR, wait for merge readiness, and integrate when clear.
# `carson deliver` owns the synchronous happy path for single-branch delivery.
module Carson
	class Runtime
		module Deliver
			DELIVER_MERGE_ATTEMPT_CAP = 3

			# Entry point for `carson deliver`.
			# Pushes the current branch, ensures a PR exists, records delivery state,
			# waits for merge readiness, and integrates when the path is clear.
			# When --commit is supplied, Carson creates one all-dirty agent-authored commit first.
			def deliver!( title: nil, body_file: nil, commit_message: nil, json_output: false )
				branch_name = current_branch
				main_branch = config.main_branch
				remote_name = config.git_remote
				result = {
					command: "deliver",
					branch: branch_name,
					watch_window_seconds: config.govern_check_wait.to_i,
					waited_seconds: 0,
					merge_attempted: false
				}

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

				freshness = assess_branch_freshness(
					head_ref: current_head,
					remote: remote_name,
					main: main_branch
				)
				result[ :freshness ] = freshness_payload( freshness: freshness )
				unless freshness.fetch( :ready )
					result[ :summary ] = freshness.fetch( :summary )
					result[ :error ] = freshness.fetch( :summary )
					result[ :recovery ] = freshness_recovery( freshness: freshness )
					result[ :main_branch ] = main_branch
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
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
				delivery = settle_delivery!(
					delivery: delivery,
					branch_name: branch.name,
					remote: remote_name,
					main: main_branch,
					result: result
				)

				result[ :pr_number ] = pr_number
				result[ :pr_url ] = pr_url
				result[ :ci ] = "pass" if delivery.integrated?
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
				freshness = assess_branch_freshness(
					head_ref: delivery.head || branch_name,
					remote: config.git_remote,
					main: config.main_branch
				)
				unless freshness.fetch( :ready )
					return ledger.update_delivery(
						delivery: delivery,
						status: "gated",
						cause: "freshness",
						summary: freshness.fetch( :summary ),
						pr_number: delivery.pull_request_number,
						pr_url: delivery.pull_request_url,
						worktree_path: delivery.worktree_path
					)
				end

				review = check_pr_review( number: delivery.pull_request_number, branch: branch_name, pr_url: delivery.pull_request_url )
				ci = check_pr_ci( number: delivery.pull_request_number )
				pr_state = pull_request_state( number: delivery.pull_request_number )
				status, cause, summary = delivery_assessment( ci: ci, review: review, pr_state: pr_state )

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

			def settle_delivery!( delivery:, branch_name:, remote:, main:, result: )
					started_at = deliver_monotonic_now
					watch_window_seconds = config.govern_check_wait.to_i
					merge_attempts = 0
					successful_assessments = 0
					last_evaluation = nil

					result[ :watch_window_seconds ] = watch_window_seconds
					result[ :waited_seconds ] = 0
					result[ :merge_attempted ] = false

					loop do
						evaluation = evaluate_delivery_for_settle(
							branch_name: branch_name,
							head_ref: delivery.head,
							pr_number: delivery.pull_request_number,
							pr_url: delivery.pull_request_url,
							main: main
						)
						last_evaluation = evaluation
						successful_assessments += 1 if evaluation[ :assessment_success ]
						result[ :ci ] = evaluation[ :ci ].to_s
						result[ :freshness ] = freshness_payload( freshness: evaluation.fetch( :freshness ) ) if evaluation[ :freshness ]

						delivery = update_delivery_for_settle_evaluation( delivery: delivery, evaluation: evaluation )
						result[ :summary ] = delivery.summary

						case evaluation[ :phase ]
						when :integrated
							delivery = mark_delivery_integrated!(
								delivery: delivery,
								remote: remote,
								main: main,
								result: result
							)
							result[ :outcome ] = "integrated"
							result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
							return delivery
						when :blocked
							result[ :outcome ] = "blocked"
							result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
							result[ :recovery ] = freshness_recovery( freshness: evaluation.fetch( :freshness ) ) if evaluation[ :cause ] == "freshness" && evaluation[ :freshness ]
							apply_handoff!(
								result: result,
								reason: evaluation.fetch( :reason ),
								summary: delivery.summary,
								outcome: "blocked"
							)
							return delivery
						when :ready
							merge_outcome = attempt_delivery_merge!(
								delivery: delivery,
								remote: remote,
								main: main,
								result: result
							)
							if merge_outcome.fetch( :attempted )
								merge_attempts += 1
								result[ :merge_attempted ] = true
							end
							delivery = merge_outcome.fetch( :delivery )
							result[ :summary ] = delivery.summary

							case merge_outcome.fetch( :phase )
							when :integrated
								result[ :outcome ] = "integrated"
								result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
								return delivery
							when :blocked
								result[ :outcome ] = "blocked"
								result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
								apply_handoff!(
									result: result,
									reason: merge_outcome.fetch( :reason ),
									summary: delivery.summary,
									outcome: "blocked"
								)
								return delivery
							end
						when :waiting
							if evaluation.fetch( :reason ) == "mergeability_pending" &&
									successful_assessments >= 2 &&
									merge_attempts < deliver_merge_attempt_cap
								merge_outcome = attempt_delivery_merge!(
									delivery: delivery,
									remote: remote,
									main: main,
									result: result
								)
								if merge_outcome.fetch( :attempted )
									merge_attempts += 1
									result[ :merge_attempted ] = true
								end
								delivery = merge_outcome.fetch( :delivery )
								result[ :summary ] = delivery.summary

								case merge_outcome.fetch( :phase )
								when :integrated
									result[ :outcome ] = "integrated"
									result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
									return delivery
								when :blocked
									result[ :outcome ] = "blocked"
									result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
									apply_handoff!(
										result: result,
										reason: merge_outcome.fetch( :reason ),
										summary: delivery.summary,
										outcome: "blocked"
									)
									return delivery
								end
							end
						end

						remaining = remaining_settle_seconds( started_at: started_at, watch_window_seconds: watch_window_seconds )
						break if remaining <= 0

						wait_seconds = [ deliver_ci_poll_seconds, remaining ].min
						deliver_sleep( wait_seconds )
					end

					result[ :outcome ] = "deferred"
					result[ :waited_seconds ] = elapsed_settle_seconds( started_at: started_at )
					apply_handoff!(
						result: result,
						reason: deferred_handoff_reason( evaluation: last_evaluation ),
						summary: delivery.summary,
						outcome: "deferred"
					)
					delivery
				end

			def evaluate_delivery_for_settle( branch_name:, head_ref:, pr_number:, pr_url:, main: )
				freshness = assess_branch_freshness(
					branch_name: branch_name,
					head_ref: head_ref,
					remote: config.git_remote,
					main: main
				)
				unless freshness.fetch( :ready )
					return {
						phase: :blocked,
						reason: freshness.fetch( :reason ),
						cause: "freshness",
						summary: freshness.fetch( :summary ),
						assessment_success: freshness.fetch( :status ) != :unknown,
						ci: :none,
						freshness: freshness
					}
				end

				review = check_pr_review( number: pr_number, branch: branch_name, pr_url: pr_url )
				ci = settle_check_pr_ci( number: pr_number )
				pr_state = pull_request_state( number: pr_number )

				return {
					phase: :waiting,
					reason: "assessment_unavailable",
					cause: "assessment",
					summary: "waiting for GitHub assessment",
					assessment_success: false,
					ci: ci
				}.merge( freshness: freshness ) if ci == :error || review.fetch( :status, :pass ) == :error || !pr_state.is_a?( Hash )

				return {
					phase: :integrated,
					reason: "already_merged",
					cause: nil,
					summary: "integrated into #{main}",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if pr_state[ "state" ] == "MERGED"

				return {
					phase: :blocked,
					reason: "pull_request_closed",
					cause: "policy",
					summary: "pull request closed without integration",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if pr_state[ "state" ] == "CLOSED"

				return {
					phase: :blocked,
					reason: "draft_pr",
					cause: "policy",
					summary: "pull request is still a draft",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if pr_state[ "isDraft" ]

				return {
					phase: :waiting,
					reason: "ci_pending",
					cause: "ci",
					summary: "waiting for CI checks",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if ci == :pending

				return {
					phase: :blocked,
					reason: "ci_failed",
					cause: "ci",
					summary: "CI checks are failing",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if ci == :fail

				return {
					phase: :blocked,
					reason: "review_changes_requested",
					cause: "review",
					summary: "review changes requested",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if review.fetch( :review, :none ) == :changes_requested

				return {
					phase: :waiting,
					reason: "review_pending",
					cause: "review",
					summary: "waiting for review",
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if review.fetch( :review, :none ) == :review_required

				return {
					phase: :blocked,
					reason: "review_blocked",
					cause: "review",
					summary: review.fetch( :detail ).to_s,
					assessment_success: true,
					ci: ci
				}.merge( freshness: freshness ) if review.fetch( :status, :pass ) == :fail

				mergeability = settle_mergeability_assessment( pr_state: pr_state, main: main )
				mergeability.merge( assessment_success: true, ci: ci, freshness: freshness )
				end

			def settle_mergeability_assessment( pr_state:, main: )
				mergeable = pr_state.fetch( "mergeable", "" ).to_s.upcase
				merge_state = pr_state.fetch( "mergeStateStatus", "" ).to_s.upcase

				return {
					phase: :blocked,
					reason: "merge_conflict",
					cause: "merge",
					summary: "pull request has merge conflicts"
				} if mergeable == "CONFLICTING" || merge_state == "DIRTY" || merge_state == "CONFLICTING"

				return {
					phase: :blocked,
					reason: "repository_policy_block",
					cause: "merge",
					summary: "merge is blocked by repository policy"
				} if merge_state == "BLOCKED"

				return {
					phase: :blocked,
					reason: "freshness_behind",
					cause: "freshness",
					summary: "branch is behind #{config.git_remote}/#{main}"
				} if merge_state == "BEHIND"

				return {
					phase: :ready,
					reason: "ready",
					cause: nil,
					summary: "ready to integrate into #{main}"
				} if merge_state == "CLEAN" || mergeable == "MERGEABLE"

				{
					phase: :waiting,
					reason: "mergeability_pending",
					cause: "assessment",
					summary: "waiting for GitHub mergeability"
				}
			end

			def update_delivery_for_settle_evaluation( delivery:, evaluation: )
				case evaluation.fetch( :phase )
				when :integrated
					delivery
				when :blocked
					if evaluation.fetch( :reason ) == "pull_request_closed"
						ledger.update_delivery(
							delivery: delivery,
							status: "failed",
							cause: evaluation.fetch( :cause ),
							summary: evaluation.fetch( :summary )
						)
					else
						ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: evaluation.fetch( :cause ),
							summary: evaluation.fetch( :summary )
						)
					end
				when :ready
					ledger.update_delivery(
						delivery: delivery,
						status: "queued",
						cause: nil,
						summary: evaluation.fetch( :summary )
					)
				else
					ledger.update_delivery(
						delivery: delivery,
						status: "gated",
						cause: evaluation.fetch( :cause ),
						summary: evaluation.fetch( :summary )
					)
				end
			end

			def attempt_delivery_merge!( delivery:, remote:, main:, result: )
				freshness = assess_branch_freshness(
					head_ref: delivery.head || delivery.branch,
					remote: remote,
					main: main
				)
				result[ :freshness ] = freshness_payload( freshness: freshness )
				unless freshness.fetch( :ready )
					result[ :recovery ] = freshness_recovery( freshness: freshness )
					return {
						phase: :blocked,
						attempted: false,
						reason: freshness.fetch( :reason ),
						delivery: ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: "freshness",
							summary: freshness.fetch( :summary )
						)
					}
				end

				pr_state = pull_request_state( number: delivery.pull_request_number )
				if pr_state && pr_state[ "state" ] == "MERGED"
					return {
						phase: :integrated,
						attempted: false,
						delivery: mark_delivery_integrated!(
							delivery: delivery,
							remote: remote,
							main: main,
							result: result
						)
					}
				end

				if pr_state && pr_state[ "state" ] == "CLOSED"
					return {
						phase: :blocked,
						attempted: false,
						reason: "pull_request_closed",
						delivery: ledger.update_delivery(
							delivery: delivery,
							status: "failed",
							cause: "policy",
							summary: "pull request closed without integration"
						)
					}
				end

				prepared = ledger.update_delivery(
					delivery: delivery,
					status: "integrating",
					summary: "integrating into #{main}"
				)
				merge_exit = merge_pr!( number: prepared.pull_request_number, result: result )
				if merge_exit == EXIT_OK
					return {
						phase: :integrated,
						attempted: true,
						delivery: mark_delivery_integrated!(
							delivery: prepared,
							remote: remote,
							main: main,
							result: result
						)
					}
				end

				merge_error = result.delete( :error )
				merge_recovery = result.delete( :recovery )
				merge_assessment = classify_merge_failure( error_text: merge_error )

				if merge_assessment.fetch( :phase ) == :blocked
					result[ :merge ] = {
						status: "blocked",
						summary: merge_assessment.fetch( :summary ),
						recovery: merge_recovery,
						method: result[ :merge_method ]
					}
				end

				{
					phase: merge_assessment.fetch( :phase ),
					attempted: true,
					reason: merge_assessment.fetch( :reason ),
					delivery: ledger.update_delivery(
						delivery: prepared,
						status: "gated",
						cause: merge_assessment.fetch( :cause ),
						summary: merge_assessment.fetch( :summary )
					)
				}
			end

			def classify_merge_failure( error_text: )
				text = error_text.to_s.strip
				downcase = text.downcase

				return {
					phase: :blocked,
					reason: "merge_conflict",
					cause: "merge",
					summary: "pull request has merge conflicts"
				} if downcase.include?( "conflict" )

				return {
					phase: :blocked,
					reason: "draft_pr",
					cause: "policy",
					summary: "pull request is still a draft"
				} if downcase.include?( "draft" )

				return {
					phase: :blocked,
					reason: "review_changes_requested",
					cause: "review",
					summary: "review changes requested"
				} if downcase.include?( "changes requested" )

				return {
					phase: :blocked,
					reason: "repository_policy_block",
					cause: "merge",
					summary: "merge is blocked by repository policy"
				} if downcase.include?( "required status check" ) ||
						downcase.include?( "required checks" ) ||
						downcase.include?( "protected branch" ) ||
						downcase.include?( "blocked by repository policy" ) ||
						downcase.include?( "review required" )

				{
					phase: :waiting,
					reason: "mergeability_pending",
					cause: "assessment",
					summary: "waiting for GitHub mergeability"
				}
			end

			def mark_delivery_integrated!( delivery:, remote:, main:, result: )
				integrated = ledger.update_delivery(
					delivery: delivery,
					status: "integrated",
					integrated_at: Time.now.utc.iso8601,
					summary: "integrated into #{main}"
				)
				sync_after_merge!( remote: remote, main: main, result: result )
				integrated
			end

			def deferred_handoff_reason( evaluation: )
				return "assessment_unavailable" if evaluation.nil?

				evaluation.fetch( :reason )
			end

			def apply_handoff!( result:, reason:, summary:, outcome: )
				next_steps = deliver_handoff_next_steps
				result[ :handoff ] = {
					reason: reason,
					expectation: handoff_expectation( reason: reason, outcome: outcome ),
					next_steps: next_steps
				}
				result[ :next_step ] = next_steps.first
				result[ :summary ] = summary
			end

			def handoff_expectation( reason:, outcome: )
				return "the PR stays open until GitHub settles and Carson is run again" if outcome == "deferred" && reason == "mergeability_pending"
				return "the PR stays open until GitHub can be assessed successfully and Carson is run again" if outcome == "deferred" && reason == "assessment_unavailable"
				return "the PR stays open while required checks finish and Carson is run again" if outcome == "deferred" && reason == "ci_pending"
				return "the PR stays open until review is approved and Carson is run again" if outcome == "deferred" && reason == "review_pending"
				return "the PR stays open until the blocker is resolved" if outcome == "blocked"

				"the PR stays open until Carson is run again"
			end

			def deliver_handoff_next_steps
				[ "carson status", "carson deliver", "carson govern --loop 300" ]
			end

			def deliver_ci_poll_seconds
				# Reuse the review poll interval for delivery reassessment polling.
				seconds = config.review_poll_seconds.to_i
				seconds.positive? ? seconds : 5
			end

			def assess_branch_freshness( branch_name: nil, head_ref: nil, remote:, main: )
				subject_ref = head_ref || branch_name
				remote_ref = "#{remote}/#{main}"
				_fetch_stdout, fetch_stderr, fetch_success, = git_run( "fetch", remote, main )
				unless fetch_success
					return {
						ready: false,
						status: :unknown,
						reason: "freshness_unknown",
						summary: "could not verify freshness against #{remote_ref}",
						remote_ref: remote_ref,
						detail: fetch_stderr.to_s.strip
					}
				end

				_merge_base_stdout, merge_base_stderr, ancestor_success, ancestor_exit = git_run(
					"merge-base", "--is-ancestor", remote_ref, subject_ref
				)
				return {
					ready: true,
					status: :fresh,
					reason: "freshness_fresh",
					summary: "verified freshness against #{remote_ref}",
					remote_ref: remote_ref
				} if ancestor_success

				return {
					ready: false,
					status: :behind,
					reason: "freshness_behind",
					summary: "branch is behind #{remote_ref}",
					remote_ref: remote_ref
				} if ancestor_exit == 1

				{
					ready: false,
					status: :unknown,
					reason: "freshness_unknown",
					summary: "could not verify freshness against #{remote_ref}",
					remote_ref: remote_ref,
					detail: merge_base_stderr.to_s.strip
				}
			end

			def freshness_payload( freshness: )
				payload = {
					status: freshness.fetch( :status ).to_s,
					reason: freshness.fetch( :reason ),
					summary: freshness.fetch( :summary ),
					base_ref: freshness.fetch( :remote_ref )
				}
				detail = freshness.fetch( :detail, "" ).to_s.strip
				payload[ :detail ] = detail unless detail.empty?
				payload
			end

			def freshness_recovery( freshness: )
				remote_ref = freshness.fetch( :remote_ref )
				return "git rebase #{remote_ref} && carson deliver" if freshness.fetch( :status ) == :behind

				remote, main = remote_ref.split( "/", 2 )
				"git fetch #{remote} #{main} && carson deliver"
			end

			def deliver_merge_attempt_cap
				DELIVER_MERGE_ATTEMPT_CAP
			end

			def deliver_monotonic_now
				Process.clock_gettime( Process::CLOCK_MONOTONIC )
			end

			def deliver_sleep( seconds )
				sleep seconds
			end

			def elapsed_settle_seconds( started_at: )
				[ ( deliver_monotonic_now - started_at ).round, 0 ].max
			end

			def remaining_settle_seconds( started_at:, watch_window_seconds: )
				( started_at + watch_window_seconds ) - deliver_monotonic_now
			end

			def delivery_assessment( ci:, review:, pr_state: )
					return [ "gated", "policy", "unable to assess CI checks" ] if ci == :error
					return [ "gated", "ci", "waiting for CI checks" ] if ci == :pending
					return [ "gated", "ci", "CI checks are failing" ] if ci == :fail
					return [ "gated", "review", "review changes requested" ] if review.fetch( :review, :none ) == :changes_requested
					return [ "gated", "review", "waiting for review" ] if review.fetch( :review, :none ) == :review_required
					return [ "gated", "review", review.fetch( :detail ).to_s ] if review.fetch( :status, :pass ) == :fail
					return [ "gated", "policy", "unable to assess review gate: #{review.fetch( :detail )}" ] if review.fetch( :status, :pass ) == :error
					return [ "gated", "merge", "waiting for GitHub mergeability" ] unless pr_state.is_a?( Hash )

					merge_result = mergeability_assessment( pr_state: pr_state )
					return merge_result if merge_result

					[ "gated", "merge", "waiting for GitHub mergeability" ]
				end

			def mergeability_assessment( pr_state: )
					return nil unless pr_state.is_a?( Hash )

				mergeable = pr_state.fetch( "mergeable", "" ).to_s.upcase
				merge_state = pr_state.fetch( "mergeStateStatus", "" ).to_s.upcase

					return [ "gated", "policy", "pull request is still a draft" ] if pr_state[ "isDraft" ]
					return [ "gated", "merge", "pull request has merge conflicts" ] if mergeable == "CONFLICTING" || merge_state == "DIRTY" || merge_state == "CONFLICTING"
					return [ "gated", "merge", "merge is blocked by repository policy" ] if merge_state == "BLOCKED"
					return [ "gated", "freshness", "branch is behind #{config.git_remote}/#{config.main_branch}" ] if merge_state == "BEHIND"
					return [ "queued", nil, "ready to integrate into #{config.main_branch}" ] if merge_state == "CLEAN" || mergeable == "MERGEABLE"

				nil
			end

			def delivery_payload( delivery: )
				{
					key: delivery.key,
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
				return result.dig( :handoff, :next_steps, 0 ) if result[ :handoff ]
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
					branch = result[ :branch ]
					main = result[ :main_branch ] || "main"
					puts_line "Delivery: #{branch} → #{main}"
				end
				if result[ :commit ]
					puts_line "Committed: #{result.dig( :commit, :summary )}"
				end
				puts_line "PR ##{result[ :pr_number ]}  #{result[ :pr_url ]}" if result[ :pr_number ]
				if result[ :delivery ]
					outcome = result[ :outcome ]
					status = result.dig( :delivery, :status )
					summary = result[ :summary ]
					if outcome == "integrated" || status == "integrated"
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
						elsif outcome == "deferred"
							puts_line "Merge deferred — #{summary}."
							puts_line deferred_human_explanation( result: result )
							print_handoff_next_steps( result: result )
						elsif outcome == "blocked"
							puts_line "Merge blocked — #{summary}."
							puts_line blocked_human_explanation( result: result )
							puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
							puts_line "  → #{result.dig( :merge, :recovery )}" if result.dig( :merge, :recovery )
							print_handoff_next_steps( result: result )
					elsif status == "failed"
						puts_line "Delivery failed — #{summary}."
					else
						puts_line "All clear — #{summary}."
					end
				end
				puts_line "Check back with #{result[ :next_step ]}" if result[ :next_step ] && !result[ :handoff ]
			end

			def deferred_human_explanation( result: )
				attempted = result[ :merge_attempted ] ? "Carson attempted merge in this run." : "Carson did not attempt merge in this run."
				"The PR is still open. Carson stopped watching after #{result[ :waited_seconds ]}s. #{attempted}"
			end

			def blocked_human_explanation( result: )
				attempted = result[ :merge_attempted ] ? "Carson attempted merge in this run." : "Carson did not attempt merge in this run."
				"The PR is still open. #{attempted}"
			end

			def print_handoff_next_steps( result: )
				Array( result.dig( :handoff, :next_steps ) ).each do |command|
					puts_line "  → #{command}"
				end
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

			def settle_check_pr_ci( number: )
				stdout, _, success, = gh_run(
					"pr", "checks", number.to_s,
					"--json", "name,bucket"
				)
				return :error unless success

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
					"--json", "number,state,isDraft,url,mergeStateStatus,mergeable"
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
			# Ensures the main worktree is attached to the main branch before pulling,
			# because git pull --ff-only on a detached HEAD fast-forwards the detached
			# HEAD but does not update the local main branch ref.
			def sync_after_merge!( remote:, main:, result: )
				main_root = main_worktree_root
				attachment = ensure_main_attached!( main_root: main_root )
				unless attachment.fetch( :ok )
					result[ :synced ] = false
					result[ :sync_error ] = attachment.fetch( :error )
					puts_verbose "sync blocked: #{attachment.fetch( :error )}"
					return
				end

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
