# Branch delivery lifecycle — push, create/update PR, wait for merge readiness, and integrate when clear.
# `carson deliver` owns the synchronous happy path for single-branch delivery.
module Carson
	class Runtime
		module Deliver
			DELIVER_MERGE_ATTEMPT_CAP = 3

			# Entry point for `carson deliver`.
			# Delegates to the OO domain model: Warehouse → Courier → Waybill.
			# The Courier orchestrates the delivery; Carson renders the result.
			def deliver!( title: nil, body_file: nil, commit_message: nil, json_output: false )
				warehouse = Warehouse.new(
					path: work_dir,
					main_label: config.main_branch,
					bureau_address: config.git_remote,
					compliance_checker: method( :deliver_compliance_checker )
				)
				parcel = Parcel.new(
					label: current_branch,
					head: current_head
				)
				courier = Courier.new( warehouse,
				ledger: ledger,
				merge_method: config.govern_merge_method,
				poll_interval_at_registry: config.poll_interval_at_registry,
				output: output
			)

				result = courier.deliver( parcel,
					title: title,
					body_file: body_file,
					commit_message: commit_message
				)

				deliver_oo_finish( result: result, json_output: json_output )
			end

		private

			# --- OO bridge methods ---

			# Compliance checker for the Warehouse. Wraps the existing template_apply!
			# machinery and returns the hash contract submit_compliance! expects.
			def deliver_compliance_checker( _warehouse )
				sync_exit, sync_diagnostics = deliver_template_sync
				case sync_exit
				when EXIT_OK
					{ compliant: true, committed: false }
				when EXIT_BLOCK
					{ compliant: true, committed: true }
				else
					{ compliant: false, committed: false, error: sync_diagnostics.to_s.strip.empty? ? "template sync failed" : sync_diagnostics.strip }
				end
			end

			# Render the OO result — JSON or human via Carson.report.
			def deliver_oo_finish( result:, json_output: )
				format = json_output ? :json : :human
				Carson.report( result, format: format, output: output )
				result[ :exit ] || Courier::OK
			end

			# --- Legacy deliver methods (used by receive!, status!, etc.) ---

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
			# Post-PR freshness is delegated to GitHub's mergeStateStatus via delivery_assessment.
			def assess_delivery!( delivery:, branch_name: )
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
						worktree_path: delivery.worktree_path,
						**pull_request_observation_attributes( pr_state: pr_state )
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
					if evaluation[ :cause ] == "freshness"
						result[ :freshness ] = {
							status: "behind",
							reason: "freshness_behind",
							summary: evaluation[ :summary ],
							base_ref: "#{config.git_remote}/#{main}"
						}
					end

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
						result[ :recovery ] = "carson deliver" if evaluation[ :cause ] == "freshness"
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

				# Post-PR freshness is delegated to GitHub's mergeStateStatus via settle_mergeability_assessment.
				def evaluate_delivery_for_settle( branch_name:, head_ref:, pr_number:, pr_url:, main: )
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
					}.merge( pr_state: pr_state ) if ci == :error || review.fetch( :status, :pass ) == :error || !pr_state.is_a?( Hash )

					return {
						phase: :integrated,
						reason: "already_merged",
						cause: nil,
						summary: "integrated into #{main}",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if pr_state[ "state" ] == "MERGED"
					return {
						phase: :blocked,
						reason: "pull_request_closed",
						cause: "policy",
						summary: "pull request closed without integration",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if pr_state[ "state" ] == "CLOSED"

					return {
						phase: :blocked,
						reason: "draft_pr",
						cause: "policy",
						summary: "pull request is still a draft",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if pr_state[ "isDraft" ]

					return {
						phase: :waiting,
						reason: "ci_pending",
						cause: "ci",
						summary: "waiting for CI checks",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if ci == :pending

					return {
						phase: :blocked,
						reason: "ci_failed",
						cause: "ci",
						summary: "CI checks are failing",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if ci == :fail

					return {
						phase: :blocked,
						reason: "review_changes_requested",
						cause: "review",
						summary: "review changes requested",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if review.fetch( :review, :none ) == :changes_requested

					return {
						phase: :waiting,
						reason: "review_pending",
						cause: "review",
						summary: "waiting for review",
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if review.fetch( :review, :none ) == :review_required

					return {
						phase: :blocked,
						reason: "review_blocked",
						cause: "review",
						summary: review.fetch( :detail ).to_s,
						assessment_success: true,
						ci: ci
					}.merge( pr_state: pr_state ) if review.fetch( :status, :pass ) == :fail

					mergeability = settle_mergeability_assessment( pr_state: pr_state, main: main )
					mergeability.merge( assessment_success: true, ci: ci, pr_state: pr_state )
				end

			def settle_mergeability_assessment( pr_state:, main: )
				assessment = github_merge_assessment( pr_state: pr_state )
				phase = if assessment[ :ready ]
					:ready
				elsif [ "mergeability_pending", "assessment_unavailable" ].include?( assessment[ :reason ] )
					:waiting
				else
					:blocked
				end
				# Preserve the settle-loop's "assessment" cause for pending/unavailable states
				cause = phase == :waiting ? "assessment" : assessment[ :cause ]
				{
					phase: phase,
					reason: assessment[ :reason ],
					cause: cause,
					summary: assessment[ :summary ]
				}
			end

			def update_delivery_for_settle_evaluation( delivery:, evaluation: )
				observation = pull_request_observation_attributes( pr_state: evaluation[ :pr_state ] )

				case evaluation.fetch( :phase )
				when :integrated
					ledger.update_delivery(
						delivery: delivery,
						**observation
					)
				when :blocked
					if evaluation.fetch( :reason ) == "pull_request_closed"
						ledger.update_delivery(
							delivery: delivery,
							status: "failed",
							cause: evaluation.fetch( :cause ),
							summary: evaluation.fetch( :summary ),
							**observation
						)
					else
						ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: evaluation.fetch( :cause ),
							summary: evaluation.fetch( :summary ),
							**observation
						)
					end
				when :ready
					ledger.update_delivery(
						delivery: delivery,
						status: "queued",
						cause: nil,
						summary: evaluation.fetch( :summary ),
						**observation
					)
				else
					ledger.update_delivery(
						delivery: delivery,
						status: "gated",
						cause: evaluation.fetch( :cause ),
						summary: evaluation.fetch( :summary ),
						**observation
					)
				end
			end

			# Pre-merge recheck using GitHub as the authority for merge eligibility.
			# Blocks on definite GitHub-reported issues (BEHIND, CONFLICTING, BLOCKED, draft).
			# Allows through pending/unknown states — the merge attempt itself will succeed or fail.
			def attempt_delivery_merge!( delivery:, remote:, main:, result: )
					pr_state = pull_request_state( number: delivery.pull_request_number )
					merge_check = github_merge_assessment( pr_state: pr_state )
					definite_blocker = !merge_check[ :ready ] &&
						![ "mergeability_pending", "assessment_unavailable" ].include?( merge_check[ :reason ] )
					if definite_blocker
						if merge_check[ :cause ] == "freshness"
							result[ :freshness ] = {
								status: "behind",
								reason: "freshness_behind",
								summary: merge_check[ :summary ],
								base_ref: "#{remote}/#{main}"
							}
						end
						result[ :recovery ] = merge_check[ :recovery ] if merge_check[ :recovery ]
						return {
							phase: :blocked,
							attempted: false,
							reason: merge_check[ :reason ],
							delivery: ledger.update_delivery(
								delivery: delivery,
								status: "gated",
								cause: merge_check[ :cause ],
								summary: merge_check[ :summary ]
							)
						}
					end

					observation = pull_request_observation_attributes( pr_state: pr_state )
					if pr_state && pr_state[ "state" ] == "MERGED"
						return {
							phase: :integrated,
							attempted: false,
							delivery: mark_delivery_integrated!(
								delivery: delivery,
								remote: remote,
								main: main,
								result: result,
								pr_state: pr_state
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
								summary: "pull request closed without integration",
								**observation
							)
						}
					end

					prepared = ledger.update_delivery(
						delivery: delivery,
						status: "integrating",
						summary: "integrating into #{main}",
						**observation
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
							result: result,
							pr_state: pr_state
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

			def mark_delivery_integrated!( delivery:, remote:, main:, result:, pr_state: nil )
				integrated_at = Time.now.utc.iso8601
				integrated = ledger.update_delivery(
					delivery: delivery,
					status: "integrated",
					integrated_at: integrated_at,
					summary: "integrated into #{main}",
					pull_request_state: "MERGED",
					pull_request_draft: false,
					pull_request_merged_at: pr_state&.fetch( "mergedAt", nil ) || integrated_at
				)
				sync_after_merge!( remote: remote, main: main, result: result )
				proof = if result[ :synced ] == false
					merge_proof_unavailable(
						main_ref: main,
						summary: "proof unavailable — local #{main} sync failed."
					)
				else
					merge_proof_for_branch( branch: integrated.branch, main_ref: main )
				end
				result[ :merge_proof ] = merge_proof_payload( proof: proof )
				ledger.update_delivery(
					delivery: integrated,
					merge_proof: proof
				)
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
				[ "carson status", "carson deliver" ]
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
				return "carson deliver" if freshness.fetch( :status ) == :behind

				"carson deliver (once #{remote_ref} is reachable)"
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

			# Interprets GitHub's PR state into a merge readiness verdict.
			# Pure method — no API calls. Accepts the already-fetched pr_state hash.
			# Returns a standardised hash: { ready:, reason:, cause:, summary:, recovery: }
			def github_merge_assessment( pr_state: )
				unless pr_state.is_a?( Hash )
					return {
						ready: false,
						reason: "assessment_unavailable",
						cause: "merge",
						summary: "waiting for GitHub mergeability",
						recovery: nil
					}
				end

				mergeable = pr_state.fetch( "mergeable", "" ).to_s.upcase
				merge_state = pr_state.fetch( "mergeStateStatus", "" ).to_s.upcase
				remote_main = "#{config.git_remote}/#{config.main_branch}"

				return {
					ready: false,
					reason: "draft_pr",
					cause: "policy",
					summary: "pull request is still a draft",
					recovery: nil
				} if pr_state[ "isDraft" ]

				return {
					ready: false,
					reason: "merge_conflict",
					cause: "merge",
					summary: "pull request has merge conflicts",
					recovery: nil
				} if mergeable == "CONFLICTING" || merge_state == "DIRTY" || merge_state == "CONFLICTING"

				return {
					ready: false,
					reason: "repository_policy_block",
					cause: "merge",
					summary: "merge is blocked by repository policy",
					recovery: nil
				} if merge_state == "BLOCKED"

				return {
					ready: false,
					reason: "freshness_behind",
					cause: "freshness",
					summary: "branch is behind #{remote_main}",
					recovery: "carson deliver"
				} if merge_state == "BEHIND"

				return {
					ready: true,
					reason: "ready",
					cause: nil,
					summary: "ready to integrate into #{config.main_branch}",
					recovery: nil
				} if merge_state == "CLEAN" || mergeable == "MERGEABLE"

				{
					ready: false,
					reason: "mergeability_pending",
					cause: "merge",
					summary: "waiting for GitHub mergeability",
					recovery: nil
				}
			end

			def mergeability_assessment( pr_state: )
				assessment = github_merge_assessment( pr_state: pr_state )
				return nil if assessment[ :reason ] == "mergeability_pending" && pr_state.is_a?( Hash )
				status = assessment[ :ready ] ? "queued" : "gated"
				[ status, assessment[ :cause ], assessment[ :summary ] ]
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
				return "carson status" if delivery.integrated? && merge_proof_needs_follow_up?( proof: result[ :merge_proof ] )
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
					remote = result[ :git_remote ] || "github"
					main = result[ :main_branch ] || "main"
					remote_main = "#{remote}/#{main}"
					puts_line "Delivery: #{branch} → #{remote_main}"
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
							puts_line "Merged into #{remote_main} with #{result[ :merge_method ]}."
						else
							puts_line "Merged into #{remote_main}."
						end
						if result[ :synced ] == false
							puts_line "Local #{main} sync failed — #{result[ :sync_error ]}."
						elsif result[ :synced ]
							puts_line "Synced local #{main}."
						end
						puts_line "Merge proof: #{result.dig( :merge_proof, :summary )}" if result[ :merge_proof ]
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

			def merge_proof_needs_follow_up?( proof: )
				return false unless proof.is_a?( Hash )

				!proof.fetch( :proven, false )
			end

			def merge_proof_payload( proof: )
				return nil unless proof.is_a?( Hash )

				{
					applicable: proof.fetch( :applicable ),
					proven: proof.fetch( :proven ),
					basis: proof.fetch( :basis ),
					summary: proof.fetch( :summary ),
					main_branch: proof.fetch( :main_branch ),
					changed_files_count: proof.fetch( :changed_files_count )
				}
			end

			def pull_request_payload( delivery: )
				number = delivery.pull_request_number
				return nil if number.nil?

				state = pull_request_state_for_delivery( delivery: delivery )
				draft = delivery.pull_request_draft
				merged_at = delivery.pull_request_merged_at
				merged_at ||= delivery.integrated_at if state == "MERGED"

				{
					number: number,
					url: delivery.pull_request_url,
					state: state,
					draft: draft,
					merged_at: merged_at,
						summary: delivery_pull_request_summary(
							number: number,
							state: state,
							draft: draft
						)
					}
				end

			def pull_request_state_for_delivery( delivery: )
				return delivery.pull_request_state unless delivery.pull_request_state.to_s.strip.empty?
				return "MERGED" if delivery.integrated?

				nil
			end

				def delivery_pull_request_summary( number:, state:, draft: )
					return "PR ##{number} is merged." if state == "MERGED"
					return "PR ##{number} is closed." if state == "CLOSED"
					return "PR ##{number} is open as draft." if state == "OPEN" && draft
					return "PR ##{number} is open." if state == "OPEN"

				"PR ##{number} is tracked by Carson."
			end

			def pull_request_observation_attributes( pr_state: )
				return {} unless pr_state.is_a?( Hash )

				{
					pull_request_state: pr_state[ "state" ],
					pull_request_draft: pr_state[ "isDraft" ],
					pull_request_merged_at: pr_state[ "mergedAt" ]
				}
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
					result[ :recovery ] = "inspect newer commits on #{branch}, reconcile, then carson deliver"
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
					result[ :recovery ] = "carson deliver"
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
					"--json", "number,state,isDraft,url,mergeStateStatus,mergeable,mergedAt"
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
					result[ :recovery ] = "carson deliver"
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
