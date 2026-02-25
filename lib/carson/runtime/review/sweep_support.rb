module Carson
	class Runtime
		module Review
			module SweepSupport
			private

				def sweep_findings_for_pull_request( details: )
					pr_author = details.dig( :author, :login ).to_s
					state = details.fetch( :state )
					baseline_time = if [ "CLOSED", "MERGED" ].include?( state )
						parse_time_or_nil( text: details.fetch( :merged_at ) ) || parse_time_or_nil( text: details.fetch( :closed_at ) )
					end

					findings = []
					unresolved_thread_entries( details: details ).each do |entry|
						thread_time = parse_time_or_nil( text: entry.fetch( :created_at ) )
						next unless include_sweep_event?( event_time: thread_time, baseline_time: baseline_time )
						findings << build_sweep_finding(
							details: details,
							kind: "unresolved_thread",
							url: entry.fetch( :url ),
							author: entry.fetch( :author ),
							created_at: entry.fetch( :created_at ),
							reason: "unresolved review thread"
						)
					end

					Array( details.fetch( :comments ) ).each do |comment|
						next if comment.fetch( :author ) == pr_author
						hits = matched_risk_keywords( text: comment.fetch( :body ) )
						next if hits.empty?
						event_time = parse_time_or_nil( text: comment.fetch( :created_at ) )
						next unless include_sweep_event?( event_time: event_time, baseline_time: baseline_time )
						findings << build_sweep_finding(
							details: details,
							kind: "risk_issue_comment",
							url: comment.fetch( :url ),
							author: comment.fetch( :author ),
							created_at: comment.fetch( :created_at ),
							reason: "risk keywords: #{hits.join( ', ' )}"
						)
					end

					Array( details.fetch( :reviews ) ).each do |review|
						next if review.fetch( :author ) == pr_author
						hits = matched_risk_keywords( text: review.fetch( :body ) )
						next if hits.empty?
						event_time = parse_time_or_nil( text: review.fetch( :created_at ) )
						next unless include_sweep_event?( event_time: event_time, baseline_time: baseline_time )
						findings << build_sweep_finding(
							details: details,
							kind: "risk_review",
							url: review.fetch( :url ),
							author: review.fetch( :author ),
							created_at: review.fetch( :created_at ),
							reason: "risk keywords: #{hits.join( ', ' )}"
						)
					end

					Array( details.fetch( :review_threads ) ).flat_map { |thread| thread.fetch( :comments ) }.each do |comment|
						next if comment.fetch( :author ) == pr_author
						hits = matched_risk_keywords( text: comment.fetch( :body ) )
						next if hits.empty?
						event_time = parse_time_or_nil( text: comment.fetch( :created_at ) )
						next unless include_sweep_event?( event_time: event_time, baseline_time: baseline_time )
						findings << build_sweep_finding(
							details: details,
							kind: "risk_thread_comment",
							url: comment.fetch( :url ),
							author: comment.fetch( :author ),
							created_at: comment.fetch( :created_at ),
							reason: "risk keywords: #{hits.join( ', ' )}"
						)
					end
					deduplicate_findings_by_url( items: findings )
				end

				# Inclusion guard for late-event sweep checks; closed PRs only include events after close/merge.
				def include_sweep_event?( event_time:, baseline_time: )
					return true if baseline_time.nil?
					return false if event_time.nil?
					event_time > baseline_time
				end

				# Formats one sweep finding record with PR context fields included.
				def build_sweep_finding( details:, kind:, url:, author:, created_at:, reason: )
					{
						pr_number: details.fetch( :number ),
						pr_title: details.fetch( :title ),
						pr_url: details.fetch( :url ),
						pr_state: details.fetch( :state ),
						kind: kind,
						url: url,
						author: author,
						created_at: created_at.to_s,
						reason: reason
					}
				end

				# Upserts one rolling tracking issue that captures latest sweep findings.
				def upsert_review_sweep_tracking_issue( owner:, repo:, findings: )
					slug = "#{owner}/#{repo}"
					ensure_review_sweep_label( repo_slug: slug )
					issue = find_review_sweep_issue( repo_slug: slug )
					if findings.empty?
						return close_review_sweep_issue_if_open( repo_slug: slug, issue: issue )
					end
					body = render_review_sweep_issue_body( findings: findings )
					if issue.nil?
						stdout_text, stderr_text, success, = gh_run(
							"issue", "create",
							"--repo", slug,
							"--title", config.review_tracking_issue_title,
							"--body", body,
							"--label", config.review_tracking_issue_label
						)
						raise gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to create review sweep tracking issue" ) unless success
						issue = find_review_sweep_issue( repo_slug: slug )
						return issue.nil? ? { action: "create_unknown", issue: nil } : { action: "created", issue: issue }
					end

					if issue.fetch( :state ) == "CLOSED"
						gh_system!( "issue", "reopen", issue.fetch( :number ).to_s, "--repo", slug )
					end
					gh_system!(
						"issue", "edit", issue.fetch( :number ).to_s,
						"--repo", slug,
						"--title", config.review_tracking_issue_title,
						"--body", body,
						"--add-label", config.review_tracking_issue_label
					)
					updated_issue = find_review_sweep_issue( repo_slug: slug )
					{ action: issue.fetch( :state ) == "CLOSED" ? "reopened_updated" : "updated", issue: updated_issue || issue }
				end

				# Creates/updates sweep tracking label so issue upsert can apply a stable filter tag.
				def ensure_review_sweep_label( repo_slug: )
					gh_system!(
						"label", "create", config.review_tracking_issue_label,
						"--repo", repo_slug,
						"--description", "Carson review sweep tracking",
						"--color", "B60205",
						"--force"
					)
				end

				# Finds rolling tracking issue by exact configured title.
				def find_review_sweep_issue( repo_slug: )
					stdout_text, stderr_text, success, = gh_run( "issue", "list", "--repo", repo_slug, "--state", "all", "--limit", "100", "--json", "number,title,state,url,labels" )
					raise gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to list issues for review sweep" ) unless success
					issues = Array( JSON.parse( stdout_text ) )
					node = issues.find { |entry| entry[ "title" ].to_s == config.review_tracking_issue_title }
					return nil if node.nil?
					{
						number: node[ "number" ],
						title: node[ "title" ].to_s,
						state: node[ "state" ].to_s.upcase,
						url: node[ "url" ].to_s
					}
				end

				# When sweep is clear, close prior tracking issue and add one clear audit comment.
				def close_review_sweep_issue_if_open( repo_slug:, issue: )
					return { action: "none", issue: nil } if issue.nil?
					return { action: "none", issue: issue } unless issue.fetch( :state ) == "OPEN"
					clear_message = "Clear: no actionable late review activity detected at #{Time.now.utc.iso8601}."
					gh_system!( "issue", "comment", issue.fetch( :number ).to_s, "--repo", repo_slug, "--body", clear_message )
					gh_system!( "issue", "close", issue.fetch( :number ).to_s, "--repo", repo_slug )
					closed_issue = find_review_sweep_issue( repo_slug: repo_slug )
					{ action: "closed", issue: closed_issue || issue }
				end

				# Markdown body used by rolling sweep issue so latest findings are always in one place.
				def render_review_sweep_issue_body( findings: )
					lines = []
					lines << "# Carson review sweep findings"
					lines << ""
					lines << "- Generated at: #{Time.now.utc.iso8601}"
					lines << "- Window days: #{config.review_sweep_window_days}"
					lines << "- States: #{config.review_sweep_states.join( ', ' )}"
					lines << "- Finding count: #{findings.count}"
					lines << ""
					lines << "## Findings"
					if findings.empty?
						lines << "- none"
					else
						findings.each do |item|
							lines << "- PR ##{item.fetch( :pr_number )} (#{item.fetch( :pr_state )}) #{item.fetch( :kind )}: #{item.fetch( :reason )}"
							lines << "  - URL: #{item.fetch( :url )}"
							lines << "  - Author: #{item.fetch( :author )}"
							lines << "  - Created at: #{item.fetch( :created_at )}"
						end
					end
					lines.join( "\n" )
				end

				# Writes sweep artefacts for CI logs and local troubleshooting.
				def write_review_sweep_report( report: )
					markdown_path, json_path = write_report(
						report: report,
						markdown_name: REVIEW_SWEEP_REPORT_MD,
						json_name: REVIEW_SWEEP_REPORT_JSON,
						renderer: method( :render_review_sweep_markdown )
					)
					puts_line "review_sweep_report_markdown: #{markdown_path}"
					puts_line "review_sweep_report_json: #{json_path}"
				rescue StandardError => e
					puts_line "review_sweep_report_write: SKIP (#{e.message})"
				end

				# Human-readable scheduled sweep report.
				def render_review_sweep_markdown( report: )
					lines = []
					lines << "# Carson Review Sweep Report"
					lines << ""
					lines << "- Generated at: #{report.fetch( :generated_at )}"
					lines << "- Status: #{report.fetch( :status )}"
					lines << "- Window days: #{report.fetch( :window_days )}"
					lines << "- States: #{Array( report.fetch( :states ) ).join( ', ' )}"
					lines << "- Cutoff time: #{report.fetch( :cutoff_time )}"
					lines << "- Candidate count: #{report.fetch( :candidate_count )}"
					lines << "- Finding count: #{report.fetch( :finding_count )}"
					tracking_issue = report[ :tracking_issue ]
					if tracking_issue.is_a?( Hash )
						lines << "- Tracking issue action: #{tracking_issue.fetch( :action )}"
						if tracking_issue[ :issue ].is_a?( Hash )
							lines << "- Tracking issue URL: #{tracking_issue.dig( :issue, :url )}"
						end
					end
					lines << ""
					lines << "## Findings"
					if report.fetch( :findings ).empty?
						lines << "- none"
					else
						report.fetch( :findings ).each do |item|
							lines << "- PR ##{item.fetch( :pr_number )} (#{item.fetch( :pr_state )}) #{item.fetch( :kind )}: #{item.fetch( :reason )}"
							lines << "  - URL: #{item.fetch( :url )}"
							lines << "  - Author: #{item.fetch( :author )}"
							lines << "  - Created at: #{item.fetch( :created_at )}"
						end
					end
					lines.join( "\n" )
				end

				# Sweep state mapping treats merged PRs as closed for state-based inclusion filtering.
				def sweep_state_for( pr_state: )
					pr_state.to_s.upcase == "OPEN" ? "open" : "closed"
				end
			end
		end
	end
end
