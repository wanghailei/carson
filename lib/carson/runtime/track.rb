# GitHub issue lifecycle stream — open, comment, close, and reopen.
module Carson
	class Runtime
		module Track
			def track_open!( title:, body: nil, body_file: nil, json_output: false )
				result = { command: "track", action: "open" }
				title_text = title.to_s.strip
				return track_error_result( result: result, error: "issue title is required", recovery: "carson track open --title 'Title'", json_output: json_output ) if title_text.empty?

				body_text, body_error = command_body_text( body: body, body_file: body_file, require_body: false )
				return track_error_result( result: result, error: body_error, recovery: "carson track open --title '#{title_text}'", json_output: json_output ) if body_error

				args = [ "issue", "create", "--title", title_text ]
				args.push( "--body", body_text.to_s )

				stdout_text, stderr_text, success, = gh_run( *args )
				unless success
					error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to create issue" )
					return track_error_result( result: result, error: error_text, recovery: "gh issue create --title '#{title_text}'", json_output: json_output )
				end

				issue_url = stdout_text.to_s.lines.map( &:strip ).reject( &:empty? ).last.to_s
				issue_number = issue_url.split( "/" ).last.to_i
				result[ :status ] = "ok"
				result[ :title ] = title_text
				result[ :issue_number ] = issue_number if issue_number.positive?
				result[ :issue_url ] = issue_url unless issue_url.empty?
				track_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

			def track_comment!( issue_number:, body: nil, body_file: nil, json_output: false )
				result = { command: "track", action: "comment", issue_number: issue_number }
				body_text, body_error = command_body_text( body: body, body_file: body_file, require_body: true )
				return track_error_result( result: result, error: body_error, recovery: "carson track comment #{issue_number} --body 'Comment'", json_output: json_output ) if body_error

				stdout_text, stderr_text, success, = gh_run( "issue", "comment", issue_number.to_s, "--body", body_text )
				unless success
					error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to comment on issue ##{issue_number}" )
					return track_error_result( result: result, error: error_text, recovery: "gh issue comment #{issue_number}", json_output: json_output )
				end

				result[ :status ] = "ok"
				result[ :issue_url ] = issue_url( issue_number: issue_number )
				track_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

			def track_close!( issue_number:, json_output: false )
				track_issue_state_change!( issue_number: issue_number, action: "close", json_output: json_output )
			end

			def track_reopen!( issue_number:, json_output: false )
				track_issue_state_change!( issue_number: issue_number, action: "reopen", json_output: json_output )
			end

		private

			def track_issue_state_change!( issue_number:, action:, json_output: false )
				result = { command: "track", action: action, issue_number: issue_number }
				stdout_text, stderr_text, success, = gh_run( "issue", action, issue_number.to_s )
				unless success
					error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to #{action} issue ##{issue_number}" )
					return track_error_result( result: result, error: error_text, recovery: "gh issue #{action} #{issue_number}", json_output: json_output )
				end

				result[ :status ] = "ok"
				result[ :issue_url ] = issue_url( issue_number: issue_number )
				track_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

			def issue_url( issue_number: )
				payload, = github_adapter.run_json( "issue", "view", issue_number.to_s, "--json", "url" )
				payload.is_a?( Hash ) ? payload[ "url" ].to_s : ""
			end

			def command_body_text( body:, body_file:, require_body: )
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

			def track_error_result( result:, error:, recovery:, json_output: )
				result[ :status ] = "error"
				result[ :error ] = error
				result[ :recovery ] = recovery
				track_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
			end

			def track_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code
				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_track_human( result: result )
				end
				exit_code
			end

			def print_track_human( result: )
				if result[ :error ]
					puts_line result.fetch( :error )
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				message = case result.fetch( :action )
				when "open" then "Issue opened"
				when "comment" then "Issue commented"
				when "close" then "Issue closed"
				when "reopen" then "Issue reopened"
				else "Issue updated"
				end
				suffix = if result[ :issue_number ]
					": ##{result[ :issue_number ]}"
				else
					""
				end
				puts_line "#{message}#{suffix}"
				puts_line "  URL: #{result[ :issue_url ]}" if result[ :issue_url ] && !result[ :issue_url ].empty?
			end
		end

		include Track
	end
end
