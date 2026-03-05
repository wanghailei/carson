module Carson
	class Runtime
		module Local
			def sync!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless working_tree_clean?
					puts_line "BLOCK: working tree is dirty; commit/stash first, then run carson sync."
					return EXIT_BLOCK
				end
				start_branch = current_branch
				switched = false
				git_system!( "fetch", config.git_remote, "--prune" )
				if start_branch != config.main_branch
					git_system!( "switch", config.main_branch )
					switched = true
				end
				git_system!( "pull", "--ff-only", config.git_remote, config.main_branch )
				ahead_count, behind_count, error_text = main_sync_counts
				if error_text
					puts_line "BLOCK: unable to verify main sync state (#{error_text})."
					return EXIT_BLOCK
				end
				if ahead_count.zero? && behind_count.zero?
					puts_line "OK: local #{config.main_branch} is now in sync with #{config.git_remote}/#{config.main_branch}."
					return EXIT_OK
				end
				puts_line "BLOCK: local #{config.main_branch} still diverges (ahead=#{ahead_count}, behind=#{behind_count})."
				EXIT_BLOCK
			ensure
				git_system!( "switch", start_branch ) if switched && branch_exists?( branch_name: start_branch )
			end

		private

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
