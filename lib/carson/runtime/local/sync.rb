# Syncs local main branch with remote main.
# Supports --json for machine-readable structured output.
module Carson
	class Runtime
		module Local
			def sync!( json_output: false )
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless working_tree_clean?
					return sync_finish(
						result: { command: "sync", status: "block", error: "working tree is dirty", recovery: "git add -A && git commit, then carson sync" },
						exit_code: EXIT_BLOCK, json_output: json_output
					)
				end
				start_branch = current_branch
				switched = false
				sync_git!( "fetch", config.git_remote, "--prune", json_output: json_output )
				if start_branch != config.main_branch
					sync_git!( "switch", config.main_branch, json_output: json_output )
					switched = true
				end
				sync_git!( "pull", "--ff-only", config.git_remote, config.main_branch, json_output: json_output )
				ahead_count, behind_count, error_text = main_sync_counts
				if error_text
					return sync_finish(
						result: { command: "sync", status: "block", error: "unable to verify main sync state (#{error_text})" },
						exit_code: EXIT_BLOCK, json_output: json_output
					)
				end
				if ahead_count.zero? && behind_count.zero?
					return sync_finish(
						result: { command: "sync", status: "ok", ahead: 0, behind: 0, main_branch: config.main_branch, remote: config.git_remote },
						exit_code: EXIT_OK, json_output: json_output
					)
				end
				sync_finish(
					result: { command: "sync", status: "block", ahead: ahead_count, behind: behind_count, main_branch: config.main_branch, remote: config.git_remote, error: "local #{config.main_branch} still diverges" },
					exit_code: EXIT_BLOCK, json_output: json_output
				)
			ensure
				git_system!( "switch", start_branch ) if switched && branch_exists?( branch_name: start_branch )
			end

		private

			# Runs a git command, suppressing stdout/stderr in JSON mode to keep output clean.
			def sync_git!( *args, json_output: false )
				if json_output
					_, stderr_text, success, = git_run( *args )
					raise "git #{args.join( ' ' )} failed: #{stderr_text.to_s.strip}" unless success
				else
					git_system!( *args )
				end
			end

			# Unified output for sync results — JSON or human-readable.
			def sync_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					out.puts JSON.pretty_generate( result )
				else
					print_sync_human( result: result )
				end

				exit_code
			end

			# Human-readable output for sync results.
			def print_sync_human( result: )
				if result[ :error ]
					puts_line "BLOCK: #{result[ :error ]}."
					puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				puts_line "OK: local #{result[ :main_branch ]} is now in sync with #{result[ :remote ]}/#{result[ :main_branch ]}."
			end

			# Returns ahead/behind counts for local main versus configured remote main.
			def main_sync_counts
				target = "#{config.main_branch}...#{config.git_remote}/#{config.main_branch}"
				stdout_text, stderr_text, success, = git_run( "rev-list", "--left-right", "--count", target )
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "git rev-list failed" if error_text.empty?
					return [ 0, 0, error_text ]
				end
				counts = stdout_text.to_s.strip.split( /\s+/ )
				return [ 0, 0, "unexpected rev-list output: #{stdout_text.to_s.strip}" ] if counts.length < 2

				[ counts[ 0 ].to_i, counts[ 1 ].to_i, nil ]
			end

			def working_tree_clean?
				git_capture!( "status", "--porcelain" ).strip.empty?
			end

			def inside_git_work_tree?
				stdout_text, = git_capture_soft( "rev-parse", "--is-inside-work-tree" )
				stdout_text.to_s.strip == "true"
			end

			# Uses `git remote get-url` as existence check to avoid parsing remote lists.
			def git_remote_exists?( remote_name: )
				_, _, success, = git_run( "remote", "get-url", remote_name.to_s )
				success
			end

			# In outsider mode, Carson must not leave Carson-owned fingerprints in host repositories.
			def block_if_outsider_fingerprints!
				return nil unless outsider_mode?

				violations = outsider_fingerprint_violations
				return nil if violations.empty?

				violations.each { |entry| puts_line "BLOCK: #{entry}" }
				EXIT_BLOCK
			end

			# Carson source repository itself is excluded from host-repository fingerprint checks.
			def outsider_mode?
				File.expand_path( repo_root ) != File.expand_path( tool_root )
			end

			# Detects Carson-owned host artefacts that violate outsider boundary.
			def outsider_fingerprint_violations
				violations = []
				violations << "forbidden file .carson.yml detected" if File.file?( File.join( repo_root, ".carson.yml" ) )
				violations << "forbidden file bin/carson detected" if File.file?( File.join( repo_root, "bin", "carson" ) )
				violations << "forbidden directory .tools/carson detected" if Dir.exist?( File.join( repo_root, ".tools", "carson" ) )
				violations
			end
		end
	end
end
