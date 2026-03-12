# Release stream — tag and publish an already-prepared release from main.
module Carson
	class Runtime
		module Release
			def release!( version:, notes_file: nil, draft: false, json_output: false )
				tag = normalise_release_tag( version: version )
				result = { command: "release", tag: tag }

				if current_branch != config.main_branch
					result[ :error ] = "release must run from #{config.main_branch}"
					result[ :recovery ] = "git switch #{config.main_branch} && carson sync"
					return release_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				unless send( :working_tree_clean? )
					result[ :error ] = "working tree is dirty"
					result[ :recovery ] = "git add -A && git commit, then carson release #{tag}"
					return release_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				sync_exit = with_captured_output { sync!( json_output: true ) }
				if sync_exit != EXIT_OK
					result[ :error ] = "local #{config.main_branch} is not in sync with #{config.git_remote}/#{config.main_branch}"
					result[ :recovery ] = "carson sync"
					return release_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if release_tag_exists?( tag: tag )
					result[ :error ] = "tag already exists: #{tag}"
					result[ :recovery ] = "choose a new version or delete the existing tag before retrying"
					return release_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				if notes_file && !notes_file.to_s.strip.empty? && !File.file?( notes_file )
					result[ :error ] = "notes file not found: #{notes_file}"
					result[ :recovery ] = "use --notes-file with an existing file or omit it for generated notes"
					return release_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				_, tag_stderr, tag_success, = git_run( "tag", "-a", tag, "-m", tag )
				unless tag_success
					result[ :error ] = blank_to( value: tag_stderr, default: "unable to create tag #{tag}" )
					return release_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				_, push_stderr, push_success, = git_run( "push", config.git_remote, tag )
				unless push_success
					result[ :error ] = blank_to( value: push_stderr, default: "unable to push tag #{tag}" )
					result[ :recovery ] = "git push #{config.git_remote} #{tag}"
					return release_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				args = [ "release", "create", tag, "--title", tag ]
				args << "--draft" if draft
				if notes_file && !notes_file.to_s.strip.empty?
					args.push( "--notes-file", notes_file )
				else
					args << "--generate-notes"
				end

				stdout_text, stderr_text, success, = gh_run( *args )
				unless success
					result[ :error ] = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to create GitHub release #{tag}" )
					result[ :recovery ] = "gh release create #{tag}"
					return release_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				result[ :status ] = "ok"
				result[ :release_url ] = stdout_text.to_s.lines.map( &:strip ).reject( &:empty? ).last.to_s
				release_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
			end

		private

			def normalise_release_tag( version: )
				text = version.to_s.strip
				text.start_with?( "v" ) ? text : "v#{text}"
			end

			def release_tag_exists?( tag: )
				_, _, local_exists, = git_run( "rev-parse", "--verify", "--quiet", "refs/tags/#{tag}" )
				return true if local_exists

				stdout_text, _, success, = git_run( "ls-remote", "--tags", config.git_remote, "refs/tags/#{tag}" )
				success && !stdout_text.to_s.strip.empty?
			end

			def release_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code
				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_release_human( result: result )
				end
				exit_code
			end

			def print_release_human( result: )
				if result[ :error ]
					puts_line result.fetch( :error )
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				puts_line "Release published: #{result.fetch( :tag )}"
				puts_line "  URL: #{result[ :release_url ]}" if result[ :release_url ] && !result[ :release_url ].empty?
			end
		end

		include Release
	end
end
