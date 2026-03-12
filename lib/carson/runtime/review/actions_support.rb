# Review actions beyond gate/sweep — comment, reply, approve, request changes, and disposition.
module Carson
	class Runtime
		module Review
			module ActionsSupport
			private

				def review_comment!( pr_number:, body: nil, body_file: nil, json_output: false )
					result = { command: "review", action: "comment", pr_number: pr_number }
					body_text, body_error = review_command_body( body: body, body_file: body_file, require_body: true )
					return review_action_error( result: result, error: body_error, recovery: "carson review comment #{pr_number} --body 'Comment'", json_output: json_output ) if body_error

					error_text = post_pull_request_comment( pr_number: pr_number, body_text: body_text )
					return review_action_error( result: result, error: error_text, recovery: "gh pr comment #{pr_number}", json_output: json_output ) if error_text

					result[ :status ] = "ok"
					result[ :pr_url ] = pull_request_url( pr_number: pr_number )
					review_action_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				def review_reply!( target_url:, body: nil, body_file: nil, json_output: false )
					result = { command: "review", action: "reply", target_url: target_url }
					comment_id, pr_number = review_reply_target( target_url: target_url )
					if comment_id.nil? || pr_number.nil?
						return review_action_error( result: result, error: "reply target must be a pull-request review thread comment URL", recovery: "use a GitHub URL containing #discussion_r<comment-id>", json_output: json_output )
					end

					body_text, body_error = review_command_body( body: body, body_file: body_file, require_body: true )
					return review_action_error( result: result, error: body_error, recovery: "carson review reply #{target_url} --body 'Reply'", json_output: json_output ) if body_error

					owner, repo = repository_coordinates
					payload, stdout_text, stderr_text, success, = github_adapter.run_json(
						"api", "--method", "POST",
						"repos/#{owner}/#{repo}/pulls/#{pr_number}/comments/#{comment_id}/replies",
						"-f", "body=#{body_text}"
					)
					unless success
						error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to reply to review thread" )
						return review_action_error( result: result, error: error_text, recovery: "reply on GitHub, then retry", json_output: json_output )
					end

					result[ :status ] = "ok"
					result[ :pr_number ] = pr_number
					result[ :reply_url ] = payload.is_a?( Hash ) ? payload[ "html_url" ].to_s : ""
					review_action_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				def review_approve!( pr_number:, body: nil, body_file: nil, json_output: false )
					review_submission!( pr_number: pr_number, body: body, body_file: body_file, mode: :approve, json_output: json_output )
				end

				def review_request_changes!( pr_number:, body: nil, body_file: nil, json_output: false )
					review_submission!( pr_number: pr_number, body: body, body_file: body_file, mode: :request_changes, json_output: json_output )
				end

				def review_disposition!( target_url:, disposition:, body: nil, body_file: nil, json_output: false )
					result = { command: "review", action: "disposition", target_url: target_url, disposition: disposition }
					pr_number = review_target_pr_number( target_url: target_url )
					return review_action_error( result: result, error: "disposition target must be a pull-request URL", recovery: "use a GitHub pull-request finding URL", json_output: json_output ) if pr_number.nil?

					extra_text, body_error = review_command_body( body: body, body_file: body_file, require_body: false )
					return review_action_error( result: result, error: body_error, recovery: "carson review disposition #{target_url} #{disposition}", json_output: json_output ) if body_error

					body_text = "#{config.review_disposition} #{disposition} #{target_url}"
					body_text = "#{body_text}\n\n#{extra_text.strip}" unless extra_text.to_s.strip.empty?
					error_text = post_pull_request_comment( pr_number: pr_number, body_text: body_text )
					return review_action_error( result: result, error: error_text, recovery: "gh pr comment #{pr_number}", json_output: json_output ) if error_text

					result[ :status ] = "ok"
					result[ :pr_number ] = pr_number
					result[ :pr_url ] = pull_request_url( pr_number: pr_number )
					review_action_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				def review_submission!( pr_number:, body:, body_file:, mode:, json_output: false )
					result = { command: "review", action: mode.to_s.tr( "_", "-" ), pr_number: pr_number }
					require_body = mode == :request_changes
					body_text, body_error = review_command_body( body: body, body_file: body_file, require_body: require_body )
					if body_error
						recovery = mode == :approve ? "carson review approve #{pr_number}" : "carson review request-changes #{pr_number} --body 'Reason'"
						return review_action_error( result: result, error: body_error, recovery: recovery, json_output: json_output )
					end

					args = [ "pr", "review", pr_number.to_s ]
					case mode
					when :approve
						args << "--approve"
					when :request_changes
						args << "--request-changes"
					end
					args.push( "--body", body_text.to_s )

					stdout_text, stderr_text, success, = gh_run( *args )
					unless success
						error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to submit review on PR ##{pr_number}" )
						return review_action_error( result: result, error: error_text, recovery: "gh pr review #{pr_number}", json_output: json_output )
					end

					result[ :status ] = "ok"
					result[ :pr_url ] = pull_request_url( pr_number: pr_number )
					review_action_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				def review_reply_target( target_url: )
					comment_id = target_url.to_s[/discussion_r(\d+)/, 1]
					pr_number = review_target_pr_number( target_url: target_url )
					return [ nil, nil ] if comment_id.to_s.empty? || pr_number.nil?
					[ comment_id, pr_number ]
				end

				def review_target_pr_number( target_url: )
					target_url.to_s[/\/pull\/(\d+)/, 1]&.to_i
				end

				def pull_request_url( pr_number: )
					payload, = github_adapter.run_json( "pr", "view", pr_number.to_s, "--json", "url" )
					payload.is_a?( Hash ) ? payload[ "url" ].to_s : ""
				end

				def post_pull_request_comment( pr_number:, body_text: )
					stdout_text, stderr_text, success, = gh_run( "pr", "comment", pr_number.to_s, "--body", body_text )
					return nil if success

					gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to comment on PR ##{pr_number}" )
				end

				def review_command_body( body:, body_file:, require_body: )
					if body_file && !body_file.to_s.strip.empty?
						path = body_file.to_s
						return [ nil, "body file not found: #{path}" ] unless File.file?( path )
						text = File.read( path )
						return [ nil, "body cannot be blank" ] if require_body && text.to_s.strip.empty?
						return [ text, nil ]
					end

					text = body.to_s
					return [ nil, "body cannot be blank" ] if require_body && text.strip.empty?
					[ text, nil ]
				end

				def review_action_error( result:, error:, recovery:, json_output: )
					result[ :status ] = "error"
					result[ :error ] = error
					result[ :recovery ] = recovery
					review_action_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				def review_action_finish( result:, exit_code:, json_output: )
					result[ :exit_code ] = exit_code
					if json_output
						output.puts JSON.pretty_generate( result )
					else
						print_review_action_human( result: result )
					end
					exit_code
				end

				def print_review_action_human( result: )
					if result[ :error ]
						puts_line result.fetch( :error )
						puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
						return
					end

					label = case result.fetch( :action )
					when "comment" then "PR commented"
					when "reply" then "Review thread replied"
					when "approve" then "PR approved"
					when "request-changes" then "Changes requested"
					when "disposition" then "Disposition posted"
					else "Review updated"
					end
					puts_line label
					puts_line "  URL: #{result[ :pr_url ]}" if result[ :pr_url ] && !result[ :pr_url ].empty?
					puts_line "  Reply: #{result[ :reply_url ]}" if result[ :reply_url ] && !result[ :reply_url ].empty?
				end
			end
		end
	end
end
