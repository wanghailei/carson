# Governed recovery path for baseline-red governance checks.
module Carson
	class Runtime
		module Recover
			GOVERNANCE_SURFACE_PREFIXES = %w[ .github/ config/hooks/ ].freeze

			def recover!( check_name:, json_output: false )
				result = {
					command: "recover",
					branch: current_branch,
					check: check_name,
					main_branch: config.main_branch
				}

				if current_branch == config.main_branch
					result[ :error ] = "cannot recover from #{config.main_branch}"
					result[ :recovery ] = "carson worktree create <name>"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if working_tree_dirty?
					result[ :error ] = "working tree is dirty"
					result[ :recovery ] = "commit or discard local changes, then rerun carson recover --check #{check_name.inspect}"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				unless gh_available?
					result[ :error ] = "gh CLI is required for carson recover"
					result[ :recovery ] = "install and authenticate gh, then retry"
					return recover_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				delivery = ledger.active_delivery( repo_path: repository_record.path, branch_name: current_branch )
				if delivery.nil?
					result[ :error ] = "no active delivery found for #{current_branch}"
					result[ :recovery ] = "carson deliver"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				result[ :pr_number ] = delivery.pull_request_number
				result[ :pr_url ] = delivery.pull_request_url

				pull_request = recover_pull_request_details( number: delivery.pull_request_number )
				result[ :pr_url ] = pull_request.fetch( :url )

				if pull_request.fetch( :state ) != "OPEN"
					result[ :error ] = "pull request ##{delivery.pull_request_number} is not open"
					result[ :recovery ] = "carson status"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if pull_request.fetch( :branch ) != current_branch
					result[ :error ] = "pull request ##{delivery.pull_request_number} belongs to #{pull_request.fetch( :branch )}, not #{current_branch}"
					result[ :recovery ] = "checkout #{pull_request.fetch( :branch )} or rerun carson deliver for #{current_branch}"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if pull_request.fetch( :head_sha ) != current_head
					result[ :error ] = "pull request ##{delivery.pull_request_number} head no longer matches local #{current_branch}"
					result[ :recovery ] = "push the current branch with carson deliver, then retry"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				relation = recovery_governance_surface_report( base_branch: pull_request.fetch( :base_branch ) )
				if relation.fetch( :status ) == "error"
					result[ :error ] = relation.fetch( :error )
					result[ :recovery ] = "git diff --name-only #{pull_request.fetch( :base_branch )}...HEAD"
					return recover_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end
				result[ :changed_files ] = relation.fetch( :files )

				unless relation.fetch( :related )
					result[ :error ] = "branch does not touch the governance surface for #{check_name}"
					result[ :recovery ] = "update the branch to repair .github/ or config/hooks/, then rerun carson recover --check #{check_name.inspect}"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				baseline = default_branch_ci_baseline_report
				result[ :baseline ] = {
					default_branch: baseline.fetch( :default_branch, config.main_branch ),
					head_sha: baseline[ :head_sha ],
					status: baseline.fetch( :status ),
					check_name: check_name
				}
				if baseline.fetch( :status ) == "skipped"
					result[ :error ] = "unable to verify the default-branch baseline: #{baseline.fetch( :skip_reason )}"
					result[ :recovery ] = "run carson status after fixing GitHub access"
					return recover_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				baseline_entry = recovery_baseline_entry( baseline: baseline, check_name: check_name )
				if baseline_entry.nil?
					result[ :error ] = "#{check_name} is not red on #{baseline.fetch( :default_branch, config.main_branch )}"
					result[ :recovery ] = "run carson status to confirm the baseline check state"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				review = check_pr_review(
					number: delivery.pull_request_number,
					branch: current_branch,
					pr_url: delivery.pull_request_url
				)
				result[ :review ] = review
				review_issue = recovery_review_issue( review: review, check_name: check_name )
				unless review_issue.nil?
					result[ :error ] = review_issue.fetch( :error )
					result[ :recovery ] = review_issue.fetch( :recovery )
					return recover_finish(
						result: result,
						exit_code: review_issue.fetch( :exit_code ),
						json_output: json_output
					)
				end

				checks = recover_required_pr_checks_report( number: delivery.pull_request_number )
				result[ :checks ] = checks
				if checks.fetch( :status ) == "error"
					result[ :error ] = checks.fetch( :error )
					result[ :recovery ] = "gh pr checks #{delivery.pull_request_number} --required"
					return recover_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				other_gate_issue = recovery_other_required_check_issue( checks: checks, check_name: check_name )
				unless other_gate_issue.nil?
					result[ :error ] = other_gate_issue.fetch( :error )
					result[ :recovery ] = other_gate_issue.fetch( :recovery )
					return recover_finish(
						result: result,
						exit_code: other_gate_issue.fetch( :exit_code ),
						json_output: json_output
					)
				end

				pr_state = pull_request_state( number: delivery.pull_request_number )
				merge_issue = recover_mergeability_issue( pr_state: pr_state )
				unless merge_issue.nil?
					result[ :error ] = merge_issue
					result[ :recovery ] = "resolve the merge conflict, then rerun carson recover --check #{check_name.inspect}"
					return recover_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				prepared = ledger.update_delivery(
					delivery: delivery,
					status: "integrating",
					summary: "recovering #{check_name} into #{config.main_branch}"
				)
				merge_exit = recover_merge_pr!(
					number: prepared.pull_request_number,
					owner: pull_request.fetch( :owner ),
					repo: pull_request.fetch( :repo ),
					head_sha: pull_request.fetch( :head_sha ),
					result: result
				)

				if merge_exit == EXIT_OK
					event = ledger.send(
						:record_recovery_event,
						repository: repository_record,
						branch_name: current_branch,
						pr_number: prepared.pull_request_number,
						pr_url: prepared.pull_request_url,
						check_name: check_name,
						default_branch: baseline.fetch( :default_branch, config.main_branch ),
						default_branch_sha: baseline.fetch( :head_sha ),
						pr_sha: pull_request.fetch( :head_sha ),
						actor: recovery_actor,
						merge_method: result.fetch( :merge_method ),
						status: "integrated",
						summary: "recovered #{check_name} into #{config.main_branch}"
					)

					integrated = ledger.update_delivery(
						delivery: prepared,
						status: "integrated",
						integrated_at: Time.now.utc.iso8601,
						summary: "recovered #{check_name} into #{config.main_branch}"
					)
					sync_after_merge!( remote: config.git_remote, main: config.main_branch, result: result )
					result[ :delivery ] = delivery_payload( delivery: integrated )
					result[ :recovery_event ] = event
					result[ :summary ] = integrated.summary
					result[ :next_step ] = deliver_next_step( delivery: integrated, result: result )
					return recover_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				gated = ledger.update_delivery(
					delivery: prepared,
					status: "gated",
					cause: "policy",
					summary: result.fetch( :error, "recovery merge failed" )
				)
				result[ :delivery ] = delivery_payload( delivery: gated )
				result[ :summary ] = gated.summary
				result[ :next_step ] = "carson status"
				recover_finish( result: result, exit_code: merge_exit, json_output: json_output )
			rescue StandardError => exception
				result[ :error ] = exception.message
				result[ :recovery ] = "carson status"
				recover_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
			end

		private

			def recover_pull_request_details( number: )
				owner, repo = repository_coordinates
				data = gh_json_payload!(
					"api", "repos/#{owner}/#{repo}/pulls/#{number}",
					"--method", "GET",
					fallback: "unable to read pull request ##{number}"
				)
				{
					number: data.fetch( "number" ),
					url: data.fetch( "html_url" ).to_s,
					state: data.fetch( "state" ).to_s.upcase,
					branch: data.dig( "head", "ref" ).to_s,
					head_sha: data.dig( "head", "sha" ).to_s,
					base_branch: data.dig( "base", "ref" ).to_s,
					base_sha: data.dig( "base", "sha" ).to_s,
					owner: owner,
					repo: repo
				}
			end

			def recovery_governance_surface_report( base_branch: )
				stdout_text, stderr_text, success, = git_run( "diff", "--name-only", "#{base_branch}...HEAD" )
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "unable to inspect branch changes against #{base_branch}" if error_text.empty?
					return { status: "error", error: error_text, files: [] }
				end

				files = stdout_text.lines.map( &:strip ).reject( &:empty? )
				related = files.any? do |path|
					GOVERNANCE_SURFACE_PREFIXES.any? { |prefix| path.start_with?( prefix ) }
				end

				{ status: "ok", related: related, files: files }
			end

			def recovery_baseline_entry( baseline:, check_name: )
				Array( baseline.fetch( :failing ) ).find do |entry|
					entry.fetch( :name ).to_s == check_name
				end
			end

			def recovery_review_issue( review:, check_name: )
				if review.fetch( :status, :pass ) == :error
					return {
						exit_code: EXIT_ERROR,
						error: "unable to assess the review gate: #{review.fetch( :detail )}",
						recovery: "carson review gate"
					}
				end

				if review.fetch( :review, :none ) == :changes_requested
					return {
						exit_code: EXIT_BLOCK,
						error: "review changes are still requested",
						recovery: "address the requested review changes, then rerun carson recover --check #{check_name.inspect}"
					}
				end

				if review.fetch( :review, :none ) == :review_required
					return {
						exit_code: EXIT_BLOCK,
						error: "review approval is still required",
						recovery: "run carson review gate, then rerun carson recover --check #{check_name.inspect}"
					}
				end

				return nil if review.fetch( :status, :pass ) == :pass

				{
					exit_code: EXIT_BLOCK,
					error: review.fetch( :detail ).to_s,
					recovery: "run carson review gate, then rerun carson recover --check #{check_name.inspect}"
				}
			end

			def recover_required_pr_checks_report( number: )
				stdout_text, stderr_text, success, = gh_run(
					"pr", "checks", number.to_s,
					"--required",
					"--json", "name,state,bucket,workflow,link"
				)
				unless success
					error_text = gh_error_text(
						stdout_text: stdout_text,
						stderr_text: stderr_text,
						fallback: "required checks unavailable"
					)
					return { status: "error", error: error_text, required_total: 0, failing: [], pending: [] }
				end

				entries = JSON.parse( stdout_text )
				failing = entries.select { |entry| check_entry_failing?( entry: entry ) }
				pending = entries.select { |entry| entry[ "bucket" ].to_s == "pending" }
				{
					status: "ok",
					required_total: entries.count,
					failing: normalise_check_entries( entries: failing ),
					pending: normalise_check_entries( entries: pending )
				}
			rescue JSON::ParserError => exception
				{
					status: "error",
					error: "invalid gh JSON response (#{exception.message})",
					required_total: 0,
					failing: [],
					pending: []
				}
			end

			def recovery_other_required_check_issue( checks:, check_name: )
				other_failing = Array( checks.fetch( :failing ) ).reject { |entry| entry.fetch( :name ) == check_name }
				other_pending = Array( checks.fetch( :pending ) ).reject { |entry| entry.fetch( :name ) == check_name }
				return nil if other_failing.empty? && other_pending.empty?

				names = ( other_failing + other_pending ).map { |entry| entry.fetch( :name ) }.uniq.sort
				details = []
				details << "#{other_failing.count} failing" unless other_failing.empty?
				details << "#{other_pending.count} pending" unless other_pending.empty?
				{
					exit_code: EXIT_BLOCK,
					error: "other required checks are still #{details.join( ' and ' )}: #{names.join( ', ' )}",
					recovery: "fix the other required checks, then rerun carson recover --check #{check_name.inspect}"
				}
			end

			def recover_mergeability_issue( pr_state: )
				return nil unless pr_state.is_a?( Hash )

				mergeable = pr_state.fetch( "mergeable", "" ).to_s.upcase
				merge_state = pr_state.fetch( "mergeStateStatus", "" ).to_s.upcase
				return "pull request has merge conflicts" if mergeable == "CONFLICTING"
				return "pull request has merge conflicts" if %w[DIRTY CONFLICTING].include?( merge_state )

				nil
			end

			def recover_merge_pr!( number:, owner:, repo:, head_sha:, result: )
				method = config.govern_merge_method
				result[ :merge_method ] = method

				stdout_text, stderr_text, success, = gh_run(
					"api", "repos/#{owner}/#{repo}/pulls/#{number}/merge",
					"--method", "PUT",
					"-f", "sha=#{head_sha}",
					"-f", "merge_method=#{method}"
				)

				if success
					payload = JSON.parse( stdout_text ) rescue {}
					result[ :merge ] = {
						status: "recovered",
						summary: blank_to( value: payload[ "message" ], default: "merged via governed recovery" ),
						method: method
					}
					return EXIT_OK
				end

				error_text = gh_error_text(
					stdout_text: stdout_text,
					stderr_text: stderr_text,
					fallback: "recovery merge failed"
				)
				result[ :merge ] = {
					status: "blocked",
					summary: error_text,
					recovery: "carson status",
					method: method
				}
				result[ :error ] = error_text
				result[ :recovery ] = "carson status"
				EXIT_ERROR
			end

			def recovery_actor
				actor = ENV.fetch( "USER", ENV.fetch( "LOGNAME", "" ) ).to_s.strip
				actor.empty? ? "unknown" : actor
			end

			def recover_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_recover_human( result: result )
				end

				exit_code
			end

			def print_recover_human( result: )
				if result[ :error ]
					puts_line result.fetch( :error )
					puts_line "  → #{result.fetch( :recovery )}" if result[ :recovery ]
					return
				end

				puts_line "Recovery: #{result.fetch( :branch )} → #{result.fetch( :main_branch )}"
				puts_line "PR ##{result.fetch( :pr_number )}  #{result.fetch( :pr_url )}"
				puts_line "Bypassed baseline-red check #{result.fetch( :check ).inspect}."
				puts_line "Merged into #{result.fetch( :main_branch )} with #{result.fetch( :merge_method )}."
				if result[ :synced ] == false
					puts_line "Local #{result.fetch( :main_branch )} sync failed — #{result.fetch( :sync_error )}."
				elsif result[ :synced ]
					puts_line "Synced local #{result.fetch( :main_branch )}."
				end
				puts_line "Recorded recovery for #{result.fetch( :check )}."
				puts_line "Check back with #{result.fetch( :next_step )}" if result[ :next_step ]
			end
		end

		include Recover
	end
end
