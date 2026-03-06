# Safe worktree lifecycle management for coding agents.
# Three operations: create, done (mark completed), remove (batch cleanup).
# The deferred deletion model: worktrees persist after use, cleaned up later.
# Supports --json for machine-readable structured output with recovery commands.
module Carson
	class Runtime
		module Local

			# Creates a new worktree under .claude/worktrees/<name> with a fresh branch.
			def worktree_create!( name:, json_output: false )
				worktrees_dir = File.join( repo_root, ".claude", "worktrees" )
				wt_path = File.join( worktrees_dir, name )

				if Dir.exist?( wt_path )
					return worktree_finish(
						result: { command: "worktree create", status: "error", name: name, path: wt_path,
							error: "worktree already exists: #{name}",
							recovery: "carson worktree remove #{name}, then retry" },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end

				# Determine the base branch (main branch from config).
				base = config.main_branch

				# Create the worktree with a new branch based on the main branch.
				FileUtils.mkdir_p( worktrees_dir )
				_, wt_stderr, wt_success, = git_run( "worktree", "add", wt_path, "-b", name, base )
				unless wt_success
					error_text = wt_stderr.to_s.strip
					error_text = "unable to create worktree" if error_text.empty?
					return worktree_finish(
						result: { command: "worktree create", status: "error", name: name,
							error: error_text },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end

				worktree_finish(
					result: { command: "worktree create", status: "ok", name: name, path: wt_path, branch: name },
					exit_code: EXIT_OK, json_output: json_output
				)
			end

			# Marks a worktree as completed without deleting it.
			# Verifies all changes are committed. Deferred deletion — cleanup happens later.
			def worktree_done!( name: nil, json_output: false )
				if name.to_s.strip.empty?
					return worktree_finish(
						result: { command: "worktree done", status: "error",
							error: "missing worktree name",
							recovery: "carson worktree done <name>" },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end

				resolved_path = resolve_worktree_path( worktree_path: name )

				unless worktree_registered?( path: resolved_path )
					return worktree_finish(
						result: { command: "worktree done", status: "error", name: name,
							error: "#{name} is not a registered worktree",
							recovery: "git worktree list" },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end

				# Check for uncommitted changes in the worktree.
				wt_status, _, status_success, = Open3.capture3( "git", "status", "--porcelain", chdir: resolved_path )
				if status_success && !wt_status.strip.empty?
					return worktree_finish(
						result: { command: "worktree done", status: "block", name: name,
							error: "worktree has uncommitted changes",
							recovery: "git -C #{resolved_path} add -A && git -C #{resolved_path} commit, then carson worktree done #{name}" },
						exit_code: EXIT_BLOCK, json_output: json_output
					)
				end

				# Check for unpushed commits.
				branch = worktree_branch( path: resolved_path )
				if branch
					remote = config.git_remote
					remote_ref = "#{remote}/#{branch}"
					ahead, _, ahead_ok, = Open3.capture3( "git", "rev-list", "--count", "#{remote_ref}..#{branch}", chdir: resolved_path )
					if ahead_ok && ahead.strip.to_i > 0
						return worktree_finish(
							result: { command: "worktree done", status: "block", name: name, branch: branch,
								error: "worktree has unpushed commits",
								recovery: "git -C #{resolved_path} push #{remote} #{branch}" },
							exit_code: EXIT_BLOCK, json_output: json_output
						)
					end
				end

				worktree_finish(
					result: { command: "worktree done", status: "ok", name: name, branch: branch || "(detached)",
						next_step: "carson worktree remove #{name}" },
					exit_code: EXIT_OK, json_output: json_output
				)
			end

			# Removes a worktree: directory, git registration, and branch.
			# Never forces removal — if the worktree has uncommitted changes, refuses unless
			# the user explicitly passes force: true via CLI --force flag.
			def worktree_remove!( worktree_path:, force: false, json_output: false )
				fingerprint_status = block_if_outsider_fingerprints!
				unless fingerprint_status.nil?
					if json_output
						out.puts JSON.pretty_generate( {
							command: "worktree remove", status: "block",
							error: "Carson-owned artefacts detected in host repository",
							recovery: "remove Carson-owned files (.carson.yml, bin/carson, .tools/carson) then retry",
							exit_code: EXIT_BLOCK
						} )
					end
					return fingerprint_status
				end

				resolved_path = resolve_worktree_path( worktree_path: worktree_path )

				unless worktree_registered?( path: resolved_path )
					return worktree_finish(
						result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
							error: "#{resolved_path} is not a registered worktree",
							recovery: "git worktree list" },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end

				branch = worktree_branch( path: resolved_path )
				puts_verbose "worktree_remove: path=#{resolved_path} branch=#{branch} force=#{force}"

				# Step 1: remove the worktree (directory + git registration).
				rm_args = [ "worktree", "remove" ]
				rm_args << "--force" if force
				rm_args << resolved_path
				rm_stdout, rm_stderr, rm_success, = git_run( *rm_args )
				unless rm_success
					error_text = rm_stderr.to_s.strip
					error_text = "unable to remove worktree" if error_text.empty?
					if !force && ( error_text.downcase.include?( "untracked" ) || error_text.downcase.include?( "modified" ) )
						return worktree_finish(
							result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
								error: "worktree has uncommitted changes",
								recovery: "commit or discard changes first, or use --force to override" },
							exit_code: EXIT_ERROR, json_output: json_output
						)
					end
					return worktree_finish(
						result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
							error: error_text },
						exit_code: EXIT_ERROR, json_output: json_output
					)
				end
				puts_verbose "worktree_removed: #{resolved_path}"

				# Step 2: delete the local branch.
				branch_deleted = false
				if branch && !config.protected_branches.include?( branch )
					_, del_stderr, del_success, = git_run( "branch", "-D", branch )
					if del_success
						puts_verbose "branch_deleted: #{branch}"
						branch_deleted = true
					else
						puts_verbose "branch_delete_skipped: #{branch} reason=#{del_stderr.to_s.strip}"
					end
				end

				# Step 3: delete the remote branch (best-effort).
				remote_deleted = false
				if branch && !config.protected_branches.include?( branch )
					remote_branch = branch
					_, _, rd_success, = git_run( "push", config.git_remote, "--delete", remote_branch )
					if rd_success
						puts_verbose "remote_branch_deleted: #{config.git_remote}/#{remote_branch}"
						remote_deleted = true
					end
				end

				worktree_finish(
					result: { command: "worktree remove", status: "ok", name: File.basename( resolved_path ),
						branch: branch, branch_deleted: branch_deleted, remote_deleted: remote_deleted },
					exit_code: EXIT_OK, json_output: json_output
				)
			end

		private

			# Unified output for worktree results — JSON or human-readable.
			def worktree_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					out.puts JSON.pretty_generate( result )
				else
					print_worktree_human( result: result )
				end

				exit_code
			end

			# Human-readable output for worktree results.
			def print_worktree_human( result: )
				command = result[ :command ]
				status = result[ :status ]

				case status
				when "ok"
					case command
					when "worktree create"
						puts_line "Worktree created: #{result[ :name ]}"
						puts_line "  Path: #{result[ :path ]}"
						puts_line "  Branch: #{result[ :branch ]}"
					when "worktree done"
						puts_line "Worktree done: #{result[ :name ]}"
						puts_line "  Branch: #{result[ :branch ]}"
						puts_line "  Cleanup later with `#{result[ :next_step ]}` or `carson housekeep`."
					when "worktree remove"
						unless verbose?
							puts_line "Worktree removed: #{result[ :name ]}"
						end
					end
				when "error"
					puts_line "ERROR: #{result[ :error ]}"
					puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
				when "block"
					puts_line "#{result[ :error ]&.capitalize || 'Blocked'}: #{result[ :name ]}"
					puts_line "  Recovery: #{result[ :recovery ]}" if result[ :recovery ]
				end
			end

			# Resolves a worktree path: if it's a bare name, look under .claude/worktrees/.
			def resolve_worktree_path( worktree_path: )
				return File.expand_path( worktree_path ) if worktree_path.include?( "/" )

				candidate = File.join( repo_root, ".claude", "worktrees", worktree_path )
				return candidate if Dir.exist?( candidate )

				File.expand_path( worktree_path )
			end

			# Returns true if the path is a registered git worktree.
			def worktree_registered?( path: )
				worktree_list.any? { |wt| wt.fetch( :path ) == path }
			end

			# Returns the branch name checked out in a worktree, or nil.
			def worktree_branch( path: )
				entry = worktree_list.find { |wt| wt.fetch( :path ) == path }
				entry&.fetch( :branch, nil )
			end

			# Parses `git worktree list --porcelain` into structured entries.
			def worktree_list
				output = git_capture!( "worktree", "list", "--porcelain" )
				entries = []
				current = {}
				output.lines.each do |line|
					line = line.strip
					if line.empty?
						entries << current unless current.empty?
						current = {}
					elsif line.start_with?( "worktree " )
						current[ :path ] = line.sub( "worktree ", "" )
					elsif line.start_with?( "branch " )
						current[ :branch ] = line.sub( "branch refs/heads/", "" )
					elsif line == "detached"
						current[ :branch ] = nil
					end
				end
				entries << current unless current.empty?
				entries
			end
		end

		include Local
	end
end
