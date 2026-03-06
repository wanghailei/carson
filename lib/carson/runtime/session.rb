# Session state persistence for coding agents.
# Maintains a lightweight JSON file per repository in ~/.carson/sessions/ so
# agents can discover the current working context without re-running discovery commands.
# Respects the outsider boundary: state lives in Carson's own space, not the repository.
require "digest"

module Carson
	class Runtime
		module Session
			# Reads and displays current session state for this repository.
			def session!( task: nil, json_output: false )
				if task
					update_session( worktree: nil, pr: nil, task: task )
					state = read_session
					return session_finish(
						result: state.merge( command: "session", status: "ok" ),
						exit_code: EXIT_OK, json_output: json_output
					)
				end

				state = read_session
				session_finish(
					result: state.merge( command: "session", status: "ok" ),
					exit_code: EXIT_OK, json_output: json_output
				)
			end

			# Clears session state for this repository.
			def session_clear!( json_output: false )
				path = session_file_path
				File.delete( path ) if File.exist?( path )
				session_finish(
					result: { command: "session clear", status: "ok", repo: repo_root },
					exit_code: EXIT_OK, json_output: json_output
				)
			end

			# Records session state — called as a side effect from other commands.
			# Only non-nil values are updated; nil values preserve existing state.
			def update_session( worktree: nil, pr: nil, task: nil )
				state = read_session

				if worktree == :clear
					state.delete( :worktree )
				elsif worktree
					state[ :worktree ] = worktree
				end

				if pr == :clear
					state.delete( :pr )
				elsif pr
					state[ :pr ] = pr
				end

				state[ :task ] = task if task
				state[ :repo ] = repo_root
				state[ :updated_at ] = Time.now.utc.iso8601

				write_session( state )
			end

		private

			# Returns the session file path for this repository.
			def session_file_path
				sessions_dir = File.join( carson_home, "sessions" )
				FileUtils.mkdir_p( sessions_dir )
				slug = session_repo_slug
				File.join( sessions_dir, "#{slug}.json" )
			end

			# Generates a readable, unique slug for the repository: basename-shortsha.
			def session_repo_slug
				basename = File.basename( repo_root )
				short_hash = Digest::SHA256.hexdigest( repo_root )[ 0, 8 ]
				"#{basename}-#{short_hash}"
			end

			# Returns Carson's home directory (~/.carson).
			def carson_home
				home = ENV.fetch( "HOME", "" ).to_s
				return File.join( home, ".carson" ) if !home.empty? && home.start_with?( "/" )

				File.join( "/tmp", ".carson" )
			end

			# Reads session state from disk. Returns an empty hash if no state exists.
			def read_session
				path = session_file_path
				return { repo: repo_root } unless File.exist?( path )

				data = JSON.parse( File.read( path ), symbolize_names: true )
				data[ :repo ] = repo_root
				data
			rescue JSON::ParserError, StandardError
				{ repo: repo_root }
			end

			# Writes session state to disk as formatted JSON.
			def write_session( state )
				path = session_file_path
				# Convert symbol keys to strings for clean JSON output.
				string_state = deep_stringify_keys( state )
				File.write( path, JSON.pretty_generate( string_state ) + "\n" )
			end

			# Recursively converts symbol keys to strings for JSON serialisation.
			def deep_stringify_keys( hash )
				hash.each_with_object( {} ) do |( key, value ), result|
					string_key = key.to_s
					result[ string_key ] = value.is_a?( Hash ) ? deep_stringify_keys( value ) : value
				end
			end

			# Unified output for session results — JSON or human-readable.
			def session_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					out.puts JSON.pretty_generate( result )
				else
					print_session_human( result: result )
				end

				exit_code
			end

			# Human-readable output for session state.
			def print_session_human( result: )
				if result[ :command ] == "session clear"
					puts_line "Session state cleared."
					return
				end

				puts_line "Session: #{File.basename( result[ :repo ].to_s )}"

				if result[ :worktree ]
					wt = result[ :worktree ]
					puts_line "  Worktree: #{wt[ :name ] || wt[ "name" ]} (#{wt[ :branch ] || wt[ "branch" ]})"
				end

				if result[ :pr ]
					pr = result[ :pr ]
					puts_line "  PR: ##{pr[ :number ] || pr[ "number" ]} #{pr[ :url ] || pr[ "url" ]}"
				end

				if result[ :task ]
					puts_line "  Task: #{result[ :task ]}"
				end

				if result[ :updated_at ]
					puts_line "  Updated: #{result[ :updated_at ]}"
				end

				puts_line "  No active session state." unless result[ :worktree ] || result[ :pr ] || result[ :task ]
			end
		end

		include Session
	end
end
