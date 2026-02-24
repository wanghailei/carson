module Carson
	class Runtime
		module Review
			module DataAccess
				private
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
def carson_pr_number_override
	text = ENV.fetch( "CARSON_PR_NUMBER", "" ).to_s.strip
	return nil if text.empty?
	Integer( text )
rescue ArgumentError
	raise "invalid CARSON_PR_NUMBER value #{text.inspect}"
end
			end
		end
	end
end
