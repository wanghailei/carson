# Implements the review gate (merge readiness) and sweep (late activity scan) workflows.
require_relative "review/query_text"
require_relative "review/data_access"
require_relative "review/gate_support"
require_relative "review/sweep_support"
require_relative "review/actions_support"
require_relative "review/utility"

module Carson
	class Runtime
		# PR review gate and sweep workflow.
		module Review
			include QueryText
			include DataAccess
			include GateSupport
			include SweepSupport
			include ActionsSupport
			include Utility

			def review_gate!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				puts_verbose ""
				puts_verbose "[Review Gate]"
				unless verbose?
					puts_line "Review Gate"
				end
				unless gh_available?
					puts_line "gh CLI not found in PATH — install it to use review commands."
					return EXIT_ERROR
				end

				owner, repo = repository_coordinates
				branch = current_branch
				pr_number_override = carson_pr_number_override
				pr_summary =
					if pr_number_override.nil?
						current_pull_request_for_branch( branch_name: branch )
					else
						details = pull_request_details( owner: owner, repo: repo, pr_number: pr_number_override )
						{
							number: details.fetch( :number ),
							title: details.fetch( :title ),
							url: details.fetch( :url ),
							state: details.fetch( :state )
						}
					end
				if pr_summary.nil?
					puts_line "No pull request found for branch #{branch}."
					report = review_gate_report_for_missing_pr( branch_name: branch )
					write_review_gate_report( report: report )
					return EXIT_BLOCK
				end

				report = review_gate_report_for_pr(
					owner: owner,
					repo: repo,
					pr_number: pr_summary.fetch( :number ),
					branch_name: branch,
					pr_summary: pr_summary
				)
				write_review_gate_report( report: report )
				unless verbose?
					poll_attempts = report.fetch( :poll_attempts, 0 )
					puts_line "Polling... (converged after #{poll_attempts} attempt#{plural_suffix( count: poll_attempts )})"
				end
				block_reasons = report.fetch( :block_reasons )
				if block_reasons.empty?
					puts_line "OK: review gate passed."
					return EXIT_OK
				end
				block_reasons.each { |reason| puts_line reason }
				EXIT_BLOCK
			rescue JSON::ParserError => exception
				puts_line "Unexpected response from gh (#{exception.message})."
				EXIT_ERROR
			rescue StandardError => exception
				puts_line exception.message
				EXIT_ERROR
			end

			# Scheduled sweep for late actionable review activity across recent pull requests.
			def review_sweep!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				puts_verbose ""
				puts_verbose "[Review Sweep]"
				unless gh_available?
					puts_line "gh CLI not found in PATH — install it to use review commands."
					return EXIT_ERROR
				end

				owner, repo = repository_coordinates
				cutoff_time = Time.now.utc - ( config.review_sweep_window_days * 86_400 )
				pull_requests = recent_pull_requests_for_sweep( owner: owner, repo: repo, cutoff_time: cutoff_time )
				puts_verbose "window_days: #{config.review_sweep_window_days}"
				puts_verbose "candidate_prs: #{pull_requests.count}"
				findings = []

				pull_requests.each do |entry|
					next unless config.review_sweep_states.include?( sweep_state_for( pr_state: entry.fetch( :state ) ) )
					details = pull_request_details( owner: owner, repo: repo, pr_number: entry.fetch( :number ) )
					findings.concat( sweep_findings_for_pull_request( details: details ) )
				end

				findings.sort_by! { |item| [ item.fetch( :pr_number ), item.fetch( :created_at ).to_s, item.fetch( :url ) ] }
				issue_result = upsert_review_sweep_tracking_issue( owner: owner, repo: repo, findings: findings )
				report = {
					generated_at: Time.now.utc.iso8601,
					status: findings.empty? ? "ok" : "block",
					window_days: config.review_sweep_window_days,
					states: config.review_sweep_states,
					cutoff_time: cutoff_time.utc.iso8601,
					candidate_count: pull_requests.count,
					finding_count: findings.count,
					findings: findings,
					tracking_issue: issue_result
				}
				write_review_sweep_report( report: report )
				puts_line "finding_count: #{findings.count}"
				if findings.empty?
					puts_line "OK: no actionable late review activity detected."
					return EXIT_OK
				end
				puts_line "Late review activity needs attention."
				EXIT_BLOCK
			rescue JSON::ParserError => exception
				puts_line "Unexpected response from gh (#{exception.message})."
				EXIT_ERROR
			rescue StandardError => exception
				puts_line exception.message
				EXIT_ERROR
			end
		end

		include Review
	end
end
