module Carson
	class Runtime
		module Review
			module QueryText
			private

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
			end
		end
	end
end
