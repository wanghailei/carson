module Butler
	class Runtime
		module ReviewOps
			def review_gate!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				print_header "Review Gate"
				unless gh_available?
					puts_line "ERROR: gh CLI not available in PATH."
					return EXIT_ERROR
				end

				owner, repo = repository_coordinates
				pr_number_override = butler_pr_number_override
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
					block_reasons << "actionable top-level comments/reviews without Codex disposition (#{last_snapshot.fetch( :unacknowledged_actionable ).count})"
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
				unacknowledged_actionable = actionable_top_level.reject { |item| acknowledged_by_codex?( item: item, acknowledgements: acknowledgements ) }
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

			# Pull request details used by both review gate and scheduled review sweep.
			def pull_request_details( owner:, repo:, pr_number: )
				node = pull_request_details_node( owner: owner, repo: repo, pr_number: pr_number )
				paginate_pull_request_connections!( owner: owner, repo: repo, pr_number: pr_number, node: node )
				normalise_pull_request_details( node: node )
			end

			# Base PR payload with first page of each connection; remaining pages are fetched separately.
			def pull_request_details_node( owner:, repo:, pr_number: )
				stdout_text, stderr_text, success, = gh_run(
				"api", "graphql",
				"-f", "query=#{pull_request_details_query}",
				"-F", "owner=#{owner}",
				"-F", "repo=#{repo}",
				"-F", "number=#{pr_number}"
				)
				unless success
					error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to read pull request ##{pr_number}" )
					raise error_text
				end
				payload = JSON.parse( stdout_text )
				node = payload.dig( "data", "repository", "pullRequest" )
				raise "pull request ##{pr_number} not found" unless node.is_a?( Hash )
				node
			end

			# Paginates every relevant PR connection so gate/sweep decisions are based on complete data.
			def paginate_pull_request_connections!( owner:, repo:, pr_number:, node: )
				paginate_pull_request_connection!( owner: owner, repo: repo, pr_number: pr_number, node: node, connection_name: "reviewThreads" )
				paginate_pull_request_connection!( owner: owner, repo: repo, pr_number: pr_number, node: node, connection_name: "comments" )
				paginate_pull_request_connection!( owner: owner, repo: repo, pr_number: pr_number, node: node, connection_name: "reviews" )
			end

			# Fetches remaining connection pages using pageInfo; missing pageInfo defaults to one-page behaviour.
			def paginate_pull_request_connection!( owner:, repo:, pr_number:, node:, connection_name: )
				connection = node[ connection_name ]
				return unless connection.is_a?( Hash )
				nodes = Array( connection[ "nodes" ] )
				page_info = connection[ "pageInfo" ].is_a?( Hash ) ? connection[ "pageInfo" ] : {}
				while page_info[ "hasNextPage" ] == true
					cursor = page_info[ "endCursor" ].to_s
					break if cursor.empty?
					page_connection = pull_request_connection_page(
					owner: owner,
					repo: repo,
					pr_number: pr_number,
					connection_name: connection_name,
					after_cursor: cursor
					)
					nodes.concat( Array( page_connection[ "nodes" ] ) )
					page_info = page_connection[ "pageInfo" ].is_a?( Hash ) ? page_connection[ "pageInfo" ] : {}
				end
				connection[ "nodes" ] = nodes
				connection[ "pageInfo" ] = page_info
			end

			# Requests one additional page for the chosen PR connection.
			def pull_request_connection_page( owner:, repo:, pr_number:, connection_name:, after_cursor: )
				query = pull_request_connection_page_query( connection_name: connection_name )
				stdout_text, stderr_text, success, = gh_run(
				"api", "graphql",
				"-f", "query=#{query}",
				"-F", "owner=#{owner}",
				"-F", "repo=#{repo}",
				"-F", "number=#{pr_number}",
				"-F", "after=#{after_cursor}"
				)
				unless success
					error_text = gh_error_text(
					stdout_text: stdout_text,
					stderr_text: stderr_text,
					fallback: "unable to paginate pull request ##{pr_number} #{connection_name}"
					)
					raise error_text
				end
				payload = JSON.parse( stdout_text )
				node = payload.dig( "data", "repository", "pullRequest" )
				raise "pull request ##{pr_number} not found during #{connection_name} pagination" unless node.is_a?( Hash )
				connection = node[ connection_name ]
				raise "missing #{connection_name} payload during pagination" unless connection.is_a?( Hash )
				connection
			end

			# Returns GraphQL query text for one paginated PR connection.
			def pull_request_connection_page_query( connection_name: )
				case connection_name
				when "comments"
					pull_request_comments_page_query
				when "reviews"
					pull_request_reviews_page_query
				when "reviewThreads"
					pull_request_review_threads_page_query
				else
					raise "unsupported pull request connection #{connection_name}"
				end
			end

			# GraphQL query kept in one place so gate/sweep consume the same PR payload schema.
			def pull_request_details_query
				<<~GRAPHQL
				query($owner:String!, $repo:String!, $number:Int!) {
				repository(owner:$owner, name:$repo) {
				pullRequest(number:$number) {
				number
				title
				url
				state
				updatedAt
				mergedAt
				closedAt
				author { login }
				reviewThreads(first:100) {
				pageInfo {
				hasNextPage
			endCursor
			}
			nodes {
			isResolved
			isOutdated
			comments(first:100) {
			nodes {
			author { login }
			body
			url
			createdAt
			}
			}
			}
			}
			comments(first:100) {
			pageInfo {
			hasNextPage
		endCursor
		}
		nodes {
		author { login }
		body
		url
		createdAt
		}
		}
		reviews(first:100) {
		pageInfo {
		hasNextPage
	endCursor
	}
	nodes {
	author { login }
	state
	body
	url
	submittedAt
	}
	}
	}
	}
	}
	GRAPHQL
end

# Additional page query for top-level issue comments.
def pull_request_comments_page_query
	<<~GRAPHQL
	query($owner:String!, $repo:String!, $number:Int!, $after:String!) {
	repository(owner:$owner, name:$repo) {
	pullRequest(number:$number) {
	comments(first:100, after:$after) {
	pageInfo {
	hasNextPage
endCursor
}
nodes {
author { login }
body
url
createdAt
}
}
}
}
}
GRAPHQL
end

# Additional page query for top-level reviews.
def pull_request_reviews_page_query
	<<~GRAPHQL
	query($owner:String!, $repo:String!, $number:Int!, $after:String!) {
	repository(owner:$owner, name:$repo) {
	pullRequest(number:$number) {
	reviews(first:100, after:$after) {
	pageInfo {
	hasNextPage
endCursor
}
nodes {
author { login }
state
body
url
submittedAt
}
}
}
}
}
GRAPHQL
end

# Additional page query for review threads.
def pull_request_review_threads_page_query
	<<~GRAPHQL
	query($owner:String!, $repo:String!, $number:Int!, $after:String!) {
	repository(owner:$owner, name:$repo) {
	pullRequest(number:$number) {
	reviewThreads(first:100, after:$after) {
	pageInfo {
	hasNextPage
endCursor
}
nodes {
isResolved
isOutdated
comments(first:100) {
nodes {
author { login }
body
url
createdAt
}
}
}
}
}
}
}
GRAPHQL
end

# Normalises pull request payload into symbol-key hash for predictable downstream processing.
def normalise_pull_request_details( node: )
	{
	number: node.fetch( "number" ),
	title: node.fetch( "title" ).to_s,
	url: node.fetch( "url" ).to_s,
	state: node.fetch( "state" ).to_s.upcase,
	updated_at: node.fetch( "updatedAt" ).to_s,
	merged_at: node[ "mergedAt" ].to_s,
	closed_at: node[ "closedAt" ].to_s,
	author: { login: node.dig( "author", "login" ).to_s },
	comments: normalise_issue_comments( nodes: node.dig( "comments", "nodes" ) ),
	reviews: normalise_reviews( nodes: node.dig( "reviews", "nodes" ) ),
	review_threads: normalise_review_threads( nodes: node.dig( "reviewThreads", "nodes" ) )
	}
end

# Converts GraphQL issue comment nodes into a stable internal format.
def normalise_issue_comments( nodes: )
	Array( nodes ).map do |entry|
		{
		author: entry.dig( "author", "login" ).to_s,
		body: entry[ "body" ].to_s,
		url: entry[ "url" ].to_s,
		created_at: entry[ "createdAt" ].to_s
		}
	end
end

# Converts GraphQL review nodes into a stable internal format.
def normalise_reviews( nodes: )
	Array( nodes ).map do |entry|
		{
		author: entry.dig( "author", "login" ).to_s,
		state: entry[ "state" ].to_s.upcase,
		body: entry[ "body" ].to_s,
		url: entry[ "url" ].to_s,
		created_at: entry[ "submittedAt" ].to_s
		}
	end
end

# Converts GraphQL review-thread nodes into a stable internal format.
def normalise_review_threads( nodes: )
	Array( nodes ).map do |entry|
		{
		is_resolved: entry[ "isResolved" ] == true,
		is_outdated: entry[ "isOutdated" ] == true,
		comments: Array( entry.dig( "comments", "nodes" ) ).map do |comment|
			{
			author: comment.dig( "author", "login" ).to_s,
			body: comment[ "body" ].to_s,
			url: comment[ "url" ].to_s,
			created_at: comment[ "createdAt" ].to_s
			}
		end
		}
	end
end

# Unresolved review threads are always actionable until explicitly resolved.
def unresolved_thread_entries( details: )
	Array( details.fetch( :review_threads ) ).each_with_index.filter_map do |thread, index|
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
	end
end

# Actionable top-level findings include CHANGES_REQUESTED reviews or risk-keyword findings.
def actionable_top_level_items( details:, pr_author: )
	items = []
	Array( details.fetch( :comments ) ).each do |comment|
		next if comment.fetch( :author ) == pr_author
		next if codex_prefixed?( text: comment.fetch( :body ) )
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
		next if codex_prefixed?( text: review.fetch( :body ) )
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

# Parses Codex acknowledgement messages and extracts referenced review URLs plus disposition.
def disposition_acknowledgements( details:, pr_author: )
	sources = []
	sources.concat( Array( details.fetch( :comments ) ) )
	sources.concat( Array( details.fetch( :reviews ) ) )
	sources.concat( Array( details.fetch( :review_threads ) ).flat_map { |thread| thread.fetch( :comments ) } )
	sources.filter_map do |entry|
		next unless entry.fetch( :author, "" ) == pr_author
		body = entry.fetch( :body, "" ).to_s
		next unless codex_prefixed?( text: body )
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
	end
end

# True when any Codex acknowledgement references the specific finding URL.
def acknowledged_by_codex?( item:, acknowledgements: )
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

# Writes review gate artefacts using fixed report names in reports.dir.
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
	lines << "# Butler Review Gate Report"
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

# Lists recently updated pull requests for scheduled sweep scanning.
def recent_pull_requests_for_sweep( owner:, repo:, cutoff_time: )
	results = []
	page = 1
	loop do
		stdout_text, stderr_text, success, = gh_run(
		"api", "repos/#{owner}/#{repo}/pulls",
		"--method", "GET",
		"-f", "state=all",
		"-f", "sort=updated",
		"-f", "direction=desc",
		"-f", "per_page=100",
		"-f", "page=#{page}"
		)
		unless success
			error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to list pull requests for review sweep" )
			raise error_text
		end

		page_nodes = Array( JSON.parse( stdout_text ) )
		break if page_nodes.empty?
		stop_paging = false

		page_nodes.each do |entry|
			updated_time = parse_time_or_nil( text: entry[ "updated_at" ] )
			next if updated_time.nil?
			if updated_time < cutoff_time
				stop_paging = true
				next
			end
			state = normalise_rest_pull_request_state( entry: entry )
			next unless config.review_sweep_states.include?( sweep_state_for( pr_state: state ) )
			results << {
			number: entry[ "number" ],
			title: entry[ "title" ].to_s,
			url: entry[ "html_url" ].to_s,
			state: state,
			updated_at: updated_time.utc.iso8601,
			merged_at: entry[ "merged_at" ].to_s,
			closed_at: entry[ "closed_at" ].to_s,
			author: entry.dig( "user", "login" ).to_s
			}
		end

		break if stop_paging
		page += 1
	end
	results
end

# REST /pulls payload normaliser so merged PRs stay distinguishable from closed-unmerged PRs.
def normalise_rest_pull_request_state( entry: )
	base_state = entry[ "state" ].to_s.upcase
	return "MERGED" if base_state == "CLOSED" && !entry[ "merged_at" ].to_s.strip.empty?
	base_state
end

# Produces sweep findings for one PR using late-event baseline for closed/merged PRs.
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
	"--description", "Butler review sweep tracking",
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
	lines << "# Butler review sweep findings"
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
	lines << "# Butler Review Sweep Report"
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

# Shared report writer for JSON plus Markdown pairs in reports.dir.
def write_report( report:, markdown_name:, json_name:, renderer: )
	report_dir = report_dir_path
	FileUtils.mkdir_p( report_dir )
	markdown_path = File.join( report_dir, markdown_name )
	json_path = File.join( report_dir, json_name )
	File.write( json_path, JSON.pretty_generate( report ) )
	File.write( markdown_path, renderer.call( report: report ) )
	[ markdown_path, json_path ]
end

# Sweep state mapping treats merged PRs as closed for state-based inclusion filtering.
def sweep_state_for( pr_state: )
	pr_state.to_s.upcase == "OPEN" ? "open" : "closed"
end

# Extracts owner/repository from configured git remote URL.
def repository_coordinates
	remote_url = git_capture!( "config", "--get", "remote.#{config.git_remote}.url" ).strip
	match = remote_url.match( %r{\A(?:git@|https?://|ssh://git@)?[^/:]+[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?\z} )
	return [ match[ :owner ], match[ :repo ] ] unless match.nil?

	stdout_text, = gh_capture_soft( "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" )
	name_with_owner = stdout_text.to_s.strip
	if name_with_owner.include?( "/" )
		owner, repo = name_with_owner.split( "/", 2 )
		return [ owner, repo ] unless owner.to_s.empty? || repo.to_s.empty?
	end

	repo_name = File.basename( remote_url ).sub( /\.git\z/, "" )
	return [ "local", repo_name ] unless repo_name.empty?
	raise "unable to parse owner/repo from remote URL #{remote_url}"
end

# Optional CI override for detached-HEAD contexts where branch-based PR lookup is not possible.
def butler_pr_number_override
	text = ENV.fetch( "BUTLER_PR_NUMBER", "" ).to_s.strip
	return nil if text.empty?
	Integer( text )
rescue ArgumentError
	raise "invalid BUTLER_PR_NUMBER value #{text.inspect}"
end

# Returns matching risk keywords using case-insensitive whole-word matching.
def matched_risk_keywords( text: )
	text_value = text.to_s
	config.review_risk_keywords.select do |keyword|
		text_value.match?( /\b#{Regexp.escape( keyword )}\b/i )
	end
end

# Codex disposition records always start with configured prefix.
def codex_prefixed?( text: )
	text.to_s.lstrip.start_with?( config.review_disposition_prefix )
end

# Extracts first matching disposition token from configured acknowledgement body.
def disposition_token( text: )
	DISPOSITION_TOKENS.find { |token| text.to_s.match?( /\b#{token}\b/i ) }
end

# GitHub URL extraction for mapping disposition acknowledgements to finding URLs.
def extract_github_urls( text: )
	text.to_s.scan( %r{https://github\.com/[^\s\)\]]+} ).map { |value| value.sub( /[.,;:]+$/, "" ) }.uniq
end

# Parse RFC3339 timestamps and return nil on blank/invalid values.
def parse_time_or_nil( text: )
	value = text.to_s.strip
	return nil if value.empty?
	Time.parse( value )
rescue ArgumentError
	nil
end

# Removes duplicate finding URLs while preserving first occurrence ordering.
def deduplicate_findings_by_url( items: )
	seen = {}
	Array( items ).each_with_object( [] ) do |entry, result|
		url = entry.fetch( :url ).to_s
		next if url.empty? || seen.key?( url )
		seen[ url ] = true
		result << entry
	end
end

end

include ReviewOps
end
end
