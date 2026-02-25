require_relative "review/query_text"
require_relative "review/data_access"
require_relative "review/gate_support"
require_relative "review/sweep_support"
require_relative "review/utility"

module Carson
	class Runtime
		module Review
			include QueryText
			include DataAccess
			include GateSupport
			include SweepSupport
			include Utility

			def review_gate!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				print_header "Review Gate"
				unless gh_available?
					puts_line "ERROR: gh CLI not available in PATH."
					return EXIT_ERROR
				end

				owner, repo = repository_coordinates
				pr_number_override = carson_pr_number_override
				pr_summary =
					if pr_number_override.nil?
						current_pull_request_for_branch( branch_name: current_branch )
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
					puts_line "BLOCK: no pull request found for branch #{current_branch}."
					report = {
						generated_at: Time.now.utc.iso8601,
						branch: current_branch,
						status: "block",
						converged: false,
						wait_seconds: config.review_wait_seconds,
						poll_seconds: config.review_poll_seconds,
						max_polls: config.review_max_polls,
						block_reasons: [ "no pull request found for current branch" ],
						pr: nil,
						unresolved_threads: [],
						actionable_top_level: [],
						unacknowledged_actionable: []
					}
					write_review_gate_report( report: report )
					return EXIT_BLOCK
				end

				wait_for_review_warmup
				converged = false
				last_snapshot = nil
				last_signature = nil
				poll_attempts = 0

				config.review_max_polls.times do |index|
					poll_attempts = index + 1
					snapshot = review_gate_snapshot( owner: owner, repo: repo, pr_number: pr_summary.fetch( :number ) )
					last_snapshot = snapshot
					signature = review_gate_signature( snapshot: snapshot )
					puts_line "poll_attempt: #{poll_attempts}/#{config.review_max_polls}"
					puts_line "latest_activity: #{snapshot.fetch( :latest_activity ) || 'unknown'}"
					puts_line "unresolved_threads: #{snapshot.fetch( :unresolved_threads ).count}"
					puts_line "unacknowledged_actionable: #{snapshot.fetch( :unacknowledged_actionable ).count}"
					if !last_signature.nil? && signature == last_signature
						converged = true
						puts_line "convergence: stable"
						break
					end
					last_signature = signature
					wait_for_review_poll if index < config.review_max_polls - 1
				end

				block_reasons = []
				block_reasons << "review snapshot did not converge within #{config.review_max_polls} polls" unless converged
				if last_snapshot.fetch( :unresolved_threads ).any?
					block_reasons << "unresolved review threads remain (#{last_snapshot.fetch( :unresolved_threads ).count})"
				end
				if last_snapshot.fetch( :unacknowledged_actionable ).any?
					block_reasons << "actionable top-level comments/reviews without required disposition (#{last_snapshot.fetch( :unacknowledged_actionable ).count})"
				end

				report = {
					generated_at: Time.now.utc.iso8601,
					branch: current_branch,
					status: block_reasons.empty? ? "ok" : "block",
					converged: converged,
					wait_seconds: config.review_wait_seconds,
					poll_seconds: config.review_poll_seconds,
					max_polls: config.review_max_polls,
					poll_attempts: poll_attempts,
					block_reasons: block_reasons,
					pr: {
						number: pr_summary.fetch( :number ),
						title: pr_summary.fetch( :title ),
						url: pr_summary.fetch( :url ),
						state: pr_summary.fetch( :state )
					},
					unresolved_threads: last_snapshot.fetch( :unresolved_threads ),
					actionable_top_level: last_snapshot.fetch( :actionable_top_level ),
					unacknowledged_actionable: last_snapshot.fetch( :unacknowledged_actionable )
				}
				write_review_gate_report( report: report )
				if block_reasons.empty?
					puts_line "OK: review gate passed."
					return EXIT_OK
				end
				block_reasons.each { |reason| puts_line "BLOCK: #{reason}" }
				EXIT_BLOCK
			rescue JSON::ParserError => e
				puts_line "ERROR: invalid gh JSON response (#{e.message})."
				EXIT_ERROR
			rescue StandardError => e
				puts_line "ERROR: #{e.message}"
				EXIT_ERROR
			end

			# Scheduled sweep for late actionable review activity across recent pull requests.
			def review_sweep!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				print_header "Review Sweep"
				unless gh_available?
					puts_line "ERROR: gh CLI not available in PATH."
					return EXIT_ERROR
				end

				owner, repo = repository_coordinates
				cutoff_time = Time.now.utc - ( config.review_sweep_window_days * 86_400 )
				pull_requests = recent_pull_requests_for_sweep( owner: owner, repo: repo, cutoff_time: cutoff_time )
				puts_line "window_days: #{config.review_sweep_window_days}"
				puts_line "candidate_prs: #{pull_requests.count}"
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
				puts_line "BLOCK: actionable late review activity detected."
				EXIT_BLOCK
			rescue JSON::ParserError => e
				puts_line "ERROR: invalid gh JSON response (#{e.message})."
				EXIT_ERROR
			rescue StandardError => e
				puts_line "ERROR: #{e.message}"
				EXIT_ERROR
			end
		end

		include Review
	end
end
