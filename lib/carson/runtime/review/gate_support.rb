module Carson
	class Runtime
		module Review
			module GateSupport
			private
			def wait_for_review_warmup
				return unless config.review_wait_seconds.positive?
				puts_line "warmup_wait_seconds: #{config.review_wait_seconds}"
				sleep config.review_wait_seconds
			end

			# Poll delay between consecutive snapshot reads during convergence checks.
			def wait_for_review_poll
				return unless config.review_poll_seconds.positive?
				puts_line "poll_wait_seconds: #{config.review_poll_seconds}"
				sleep config.review_poll_seconds
			end

			# Fetches live PR review state and derives unresolved-thread plus disposition-ack summary.
			def review_gate_snapshot( owner:, repo:, pr_number: )
				details = pull_request_details( owner: owner, repo: repo, pr_number: pr_number )
				pr_author = details.dig( :author, :login ).to_s
				unresolved_threads = unresolved_thread_entries( details: details )
				actionable_top_level = actionable_top_level_items( details: details, pr_author: pr_author )
				acknowledgements = disposition_acknowledgements( details: details, pr_author: pr_author )
				unacknowledged_actionable = actionable_top_level.reject { |item| acknowledged_by_disposition?( item: item, acknowledgements: acknowledgements ) }
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
def unresolved_thread_entries( details: )
	Array( details.fetch( :review_threads ) ).each_with_index.map do |thread, index|
		next if thread.fetch( :is_resolved )
		# Outdated threads belong to superseded diffs and should not block current merge readiness.
		next if thread.fetch( :is_outdated )
		comments = thread.fetch( :comments )
		first_comment = comments.first || {}
		latest_time = comments.map { |entry| entry.fetch( :created_at ) }.max.to_s
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
		Array( ack.fetch( :target_urls ) ).any? { |url| url == item.fetch( :url ) }
	end
end

# Latest review activity marker used by convergence snapshots.
def latest_review_activity( details: )
	timestamps = []
	timestamps << details.fetch( :updated_at )
	timestamps.concat( Array( details.fetch( :comments ) ).map { |entry| entry.fetch( :created_at ) } )
	timestamps.concat( Array( details.fetch( :reviews ) ).map { |entry| entry.fetch( :created_at ) } )
	timestamps.concat( Array( details.fetch( :review_threads ) ).flat_map { |thread| thread.fetch( :comments ) }.map { |entry| entry.fetch( :created_at ) } )
	timestamps.map { |text| parse_time_or_nil( text: text ) }.compact.max&.utc&.iso8601
end

# Writes review gate artefacts using fixed report names in global report output.
def write_review_gate_report( report: )
	markdown_path, json_path = write_report(
	report: report,
	markdown_name: REVIEW_GATE_REPORT_MD,
	json_name: REVIEW_GATE_REPORT_JSON,
	renderer: method( :render_review_gate_markdown )
	)
	puts_line "review_gate_report_markdown: #{markdown_path}"
	puts_line "review_gate_report_json: #{json_path}"
rescue StandardError => e
	puts_line "review_gate_report_write: SKIP (#{e.message})"
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
