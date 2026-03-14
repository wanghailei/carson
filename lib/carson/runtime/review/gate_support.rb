# Review gate logic: snapshot convergence, disposition acknowledgements, and merge-readiness checks.
module Carson
	class Runtime
		module Review
			module GateSupport
			private

				def review_gate_report_for_missing_pr( branch_name: )
					{
						generated_at: Time.now.utc.iso8601,
						branch: branch_name,
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
				end

				def review_gate_report_for_pr( owner:, repo:, pr_number:, branch_name:, pr_summary: nil )
					resolved_pr_summary = resolved_review_gate_pr_summary(
						owner: owner,
						repo: repo,
						pr_number: pr_number,
						pr_summary: pr_summary
					)
					pre_snapshot = wait_for_review_warmup( owner: owner, repo: repo, pr_number: pr_number )
					converged = false
					last_snapshot = pre_snapshot
					last_signature = pre_snapshot.nil? ? nil : review_gate_signature( snapshot: pre_snapshot )
					poll_attempts = 0

					config.review_max_polls.times do |index|
						poll_attempts = index + 1
						snapshot = review_gate_snapshot( owner: owner, repo: repo, pr_number: pr_number )
						last_snapshot = snapshot
						signature = review_gate_signature( snapshot: snapshot )
						puts_verbose "poll_attempt: #{poll_attempts}/#{config.review_max_polls}"
						puts_verbose "latest_activity: #{snapshot.fetch( :latest_activity ) || 'unknown'}"
						puts_verbose "unresolved_threads: #{snapshot.fetch( :unresolved_threads ).count}"
						puts_verbose "unacknowledged_actionable: #{snapshot.fetch( :unacknowledged_actionable ).count}"
						if !last_signature.nil? && signature == last_signature
							converged = true
							puts_verbose "convergence: stable"
							break
						end
						last_signature = signature
						wait_for_review_poll if index < config.review_max_polls - 1
					end

					build_review_gate_report(
						branch_name: branch_name,
						pr_summary: resolved_pr_summary,
						snapshot: last_snapshot,
						converged: converged,
						poll_attempts: poll_attempts
					)
				end

				def review_gate_result( report: )
					return { status: :pass, review: :approved, detail: "review gate passed" } if report.fetch( :status ) == "ok"

					{
						status: :fail,
						review: review_gate_changes_requested?( report: report ) ? :changes_requested : :blocked,
						detail: report.fetch( :block_reasons ).join( "; " )
					}
				end

				def wait_for_review_warmup( owner:, repo:, pr_number: )
					return unless config.review_wait_seconds.positive?
					quick = review_gate_snapshot( owner: owner, repo: repo, pr_number: pr_number )
					if quick[ :unresolved_threads ].empty? && quick[ :unacknowledged_actionable ].empty?
						puts_verbose "warmup_skip: all threads resolved"
						return quick
					end
					puts_verbose "warmup_wait_seconds: #{config.review_wait_seconds}"
					sleep config.review_wait_seconds
					nil
				end

				# Poll delay between consecutive snapshot reads during convergence checks.
				def wait_for_review_poll
					return unless config.review_poll_seconds.positive?
					puts_verbose "poll_wait_seconds: #{config.review_poll_seconds}"
					sleep config.review_poll_seconds
				end

				# Fetches live PR review state and derives unresolved-thread plus disposition-ack summary.
				def review_gate_snapshot( owner:, repo:, pr_number: )
					details = pull_request_details( owner: owner, repo: repo, pr_number: pr_number )
					pr_author = details.dig( :author, :login ).to_s
					unresolved_threads = unresolved_thread_entries( details: details )
					actionable_top_level = actionable_top_level_items( details: details, pr_author: pr_author )
					acknowledgements = disposition_acknowledgements( details: details, pr_author: pr_author )
					unacknowledged_actionable = actionable_top_level.reject do |item|
						acknowledged_by_disposition?( item: item, acknowledgements: acknowledgements )
					end
					{
						latest_activity: latest_review_activity( details: details ),
						unresolved_threads: unresolved_threads,
						actionable_top_level: actionable_top_level,
						unacknowledged_actionable: unacknowledged_actionable,
						acknowledgements: acknowledgements
					}
				end

				# Deterministic signature used to compare two review snapshots for convergence.
				def review_gate_signature( snapshot: )
					{
						latest_activity: snapshot.fetch( :latest_activity ).to_s,
						unresolved_urls: snapshot.fetch( :unresolved_threads ).map { |entry| entry.fetch( :url ) }.sort,
						unacknowledged_urls: snapshot.fetch( :unacknowledged_actionable ).map { |entry| entry.fetch( :url ) }.sort
					}
				end

				# Pull request selected by current branch; nil is returned when no PR exists.
				def current_pull_request_for_branch( branch_name: )
					stdout_text, stderr_text, success, = gh_run( "pr", "view", "--", branch_name, "--json", "number,title,url,state" )
					unless success
						error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to read PR for branch #{branch_name}" )
						return nil if error_text.downcase.include?( "no pull requests found" )
						raise error_text
					end
					data = JSON.parse( stdout_text )
					{
						number: data.fetch( "number" ),
						title: data.fetch( "title" ).to_s,
						url: data.fetch( "url" ).to_s,
						state: data.fetch( "state" ).to_s
					}
				end

				# GraphQL returns "gemini-code-assist"; REST returns "gemini-code-assist[bot]".
				# Normalise both sides by stripping the [bot] suffix for a consistent match.
				def bot_username?( author: )
					normalised = author.to_s.downcase.delete_suffix( "[bot]" )
					config.review_bot_usernames.any? { |username| username.downcase.delete_suffix( "[bot]" ) == normalised }
				end

				def unresolved_thread_entries( details: )
					Array( details.fetch( :review_threads ) ).each_with_index.map do |thread, index|
						next if thread.fetch( :is_resolved )
						# Outdated threads belong to superseded diffs and should not block current merge readiness.
						next if thread.fetch( :is_outdated )
						comments = thread.fetch( :comments )
						first_comment = comments.first || {}
						next if bot_username?( author: first_comment.fetch( :author, "" ) )
						latest_time = comments.map { |comment| comment.fetch( :created_at ) }.max.to_s
						{
							url: blank_to( value: first_comment.fetch( :url, "" ), default: "#{details.fetch( :url )}#thread-#{index + 1}" ),
							author: first_comment.fetch( :author, "" ),
							created_at: latest_time,
							outdated: thread.fetch( :is_outdated ),
							reason: "unresolved_thread"
						}
					end.compact
				end

				# Actionable top-level findings include CHANGES_REQUESTED reviews or risk-keyword findings.
				def actionable_top_level_items( details:, pr_author: )
					items = []
					Array( details.fetch( :comments ) ).each do |comment|
						next if comment.fetch( :author ) == pr_author
						next if bot_username?( author: comment.fetch( :author ) )
						next if disposition_prefixed?( text: comment.fetch( :body ) )
						hits = matched_risk_keywords( text: comment.fetch( :body ) )
						next if hits.empty?
						items << {
							kind: "issue_comment",
							url: comment.fetch( :url ),
							author: comment.fetch( :author ),
							created_at: comment.fetch( :created_at ),
							reason: "risk_keywords: #{hits.join( ', ' )}"
						}
					end
					Array( details.fetch( :reviews ) ).each do |review|
						next if review.fetch( :author ) == pr_author
						next if bot_username?( author: review.fetch( :author ) )
						next if disposition_prefixed?( text: review.fetch( :body ) )
						hits = matched_risk_keywords( text: review.fetch( :body ) )
						changes_requested = review.fetch( :state ) == "CHANGES_REQUESTED"
						next if hits.empty? && !changes_requested
						reason = changes_requested ? "changes_requested_review" : "risk_keywords: #{hits.join( ', ' )}"
						items << {
							kind: "review",
							url: review.fetch( :url ),
							author: review.fetch( :author ),
							created_at: review.fetch( :created_at ),
							reason: reason
						}
					end
					deduplicate_findings_by_url( items: items )
				end

				# Parses acknowledgement messages and extracts referenced review URLs plus disposition.
				def disposition_acknowledgements( details:, pr_author: )
					sources = []
					sources.concat( Array( details.fetch( :comments ) ) )
					sources.concat( Array( details.fetch( :reviews ) ) )
					sources.concat( Array( details.fetch( :review_threads ) ).flat_map { |thread| thread.fetch( :comments ) } )
					sources.map do |entry|
						next unless entry.fetch( :author, "" ) == pr_author
						body = entry.fetch( :body, "" ).to_s
						next unless disposition_prefixed?( text: body )
						disposition = disposition_token( text: body )
						next if disposition.nil?
						target_urls = extract_github_urls( text: body )
						next if target_urls.empty?
						{
							url: entry.fetch( :url, "" ),
							created_at: entry.fetch( :created_at, "" ),
							disposition: disposition,
							target_urls: target_urls
						}
					end.compact
				end

				# True when any disposition acknowledgement references the specific finding URL.
				def acknowledged_by_disposition?( item:, acknowledgements: )
					acknowledgements.any? do |ack|
						Array( ack.fetch( :target_urls ) ).any? { |target_url| target_url == item.fetch( :url ) }
					end
				end

				# Latest review activity marker used by convergence snapshots.
				def latest_review_activity( details: )
					timestamps = []
					timestamps << details.fetch( :updated_at )
					timestamps.concat( Array( details.fetch( :comments ) ).map { |comment| comment.fetch( :created_at ) } )
					timestamps.concat( Array( details.fetch( :reviews ) ).map { |review| review.fetch( :created_at ) } )
					timestamps.concat( Array( details.fetch( :review_threads ) ).flat_map { |thread| thread.fetch( :comments ) }.map { |comment| comment.fetch( :created_at ) } )
					timestamps.map { |timestamp| parse_time_or_nil( text: timestamp ) }.compact.max&.utc&.iso8601
				end

				def resolved_review_gate_pr_summary( owner:, repo:, pr_number:, pr_summary: )
					required_keys = %i[number title url state]
					if !pr_summary.nil? && required_keys.all? { |key| pr_summary.key?( key ) && !pr_summary.fetch( key ).to_s.empty? }
						return pr_summary
					end

					pull_request_summary( owner: owner, repo: repo, pr_number: pr_number )
				end

				def pull_request_summary( owner:, repo:, pr_number: )
					details = pull_request_details( owner: owner, repo: repo, pr_number: pr_number )
					{
						number: details.fetch( :number ),
						title: details.fetch( :title ),
						url: details.fetch( :url ),
						state: details.fetch( :state )
					}
				end

				def build_review_gate_report( branch_name:, pr_summary:, snapshot:, converged:, poll_attempts: )
					{
						generated_at: Time.now.utc.iso8601,
						branch: branch_name,
						status: review_gate_block_reasons( snapshot: snapshot, converged: converged ).empty? ? "ok" : "block",
						converged: converged,
						wait_seconds: config.review_wait_seconds,
						poll_seconds: config.review_poll_seconds,
						max_polls: config.review_max_polls,
						poll_attempts: poll_attempts,
						block_reasons: review_gate_block_reasons( snapshot: snapshot, converged: converged ),
						pr: {
							number: pr_summary.fetch( :number ),
							title: pr_summary.fetch( :title ),
							url: pr_summary.fetch( :url ),
							state: pr_summary.fetch( :state )
						},
						unresolved_threads: snapshot.fetch( :unresolved_threads ),
						actionable_top_level: snapshot.fetch( :actionable_top_level ),
						unacknowledged_actionable: snapshot.fetch( :unacknowledged_actionable )
					}
				end

				def review_gate_block_reasons( snapshot:, converged: )
					reasons = []
					reasons << "review snapshot did not converge within #{config.review_max_polls} polls" unless converged
					if snapshot.fetch( :unresolved_threads ).any?
						reasons << "unresolved review threads remain (#{snapshot.fetch( :unresolved_threads ).count})"
					end
					if snapshot.fetch( :unacknowledged_actionable ).any?
						reasons << "actionable top-level comments/reviews without required disposition (#{snapshot.fetch( :unacknowledged_actionable ).count})"
					end
					reasons
				end

				def review_gate_changes_requested?( report: )
					Array( report.fetch( :unacknowledged_actionable ) ).any? do |entry|
						entry.fetch( :reason ) == "changes_requested_review"
					end
				end

				# Writes review gate artefacts using fixed report names in global report output.
				def write_review_gate_report( report: )
					markdown_path, json_path = report(
						report: report,
						markdown_name: REVIEW_GATE_REPORT_MD,
						json_name: REVIEW_GATE_REPORT_JSON,
						renderer: method( :render_review_gate_markdown )
					)
					puts_verbose "review_gate_report_markdown: #{markdown_path}"
					puts_verbose "review_gate_report_json: #{json_path}"
				rescue StandardError => exception
					puts_verbose "review_gate_report_write: SKIP (#{exception.message})"
				end

				# Human-readable review gate report for merge-readiness evidence.
				def render_review_gate_markdown( report: )
					lines = []
					lines << "# Carson Review Gate Report"
					lines << ""
					lines << "- Generated at: #{report.fetch( :generated_at )}"
					lines << "- Branch: #{report.fetch( :branch )}"
					lines << "- Status: #{report.fetch( :status )}"
					lines << "- Converged: #{report.fetch( :converged )}"
					lines << "- Poll attempts: #{report.fetch( :poll_attempts, 0 )}"
					lines << "- Wait seconds: #{report.fetch( :wait_seconds )}"
					lines << "- Poll seconds: #{report.fetch( :poll_seconds )}"
					lines << "- Max polls: #{report.fetch( :max_polls )}"
					lines << ""
					lines << "## Pull Request"
					pr = report[ :pr ]
					if pr.nil?
						lines << "- not available"
					else
						lines << "- Number: ##{pr.fetch( :number )}"
						lines << "- Title: #{pr.fetch( :title )}"
						lines << "- URL: #{pr.fetch( :url )}"
						lines << "- State: #{pr.fetch( :state )}"
					end
					lines << ""
					lines << "## Block Reasons"
					if report.fetch( :block_reasons ).empty?
						lines << "- none"
					else
						report.fetch( :block_reasons ).each { |reason| lines << "- #{reason}" }
					end
					lines << ""
					lines << "## Unresolved Threads"
					if report.fetch( :unresolved_threads ).empty?
						lines << "- none"
					else
						report.fetch( :unresolved_threads ).each do |entry|
							lines << "- #{entry.fetch( :url )} (author: #{entry.fetch( :author )}, outdated: #{entry.fetch( :outdated )})"
						end
					end
					lines << ""
					lines << "## Unacknowledged Actionable Top-Level Findings"
					if report.fetch( :unacknowledged_actionable ).empty?
						lines << "- none"
					else
						report.fetch( :unacknowledged_actionable ).each do |entry|
							lines << "- #{entry.fetch( :kind )}: #{entry.fetch( :url )} (author: #{entry.fetch( :author )}, reason: #{entry.fetch( :reason )})"
						end
					end
					lines << ""
					lines.join( "\n" )
				end
			end
		end
	end
end
