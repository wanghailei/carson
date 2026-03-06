module Carson
	class Runtime
		module Local
			# Safe worktree lifecycle management for coding agents.
			# Enforces the teardown order: exit worktree → git worktree remove → branch cleanup.
			# Never forces removal — if the worktree has uncommitted changes, refuses unless
			# the user explicitly passes force: true via CLI --force flag.
			def worktree_remove!( worktree_path:, force: false )
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				resolved_path = resolve_worktree_path( worktree_path: worktree_path )

				unless worktree_registered?( path: resolved_path )
					puts_line "ERROR: #{resolved_path} is not a registered worktree."
					puts_line "  Registered worktrees:"
					worktree_list.each { |wt| puts_line "  - #{wt.fetch( :path )} [#{wt.fetch( :branch )}]" }
					return EXIT_ERROR
				end

				branch = worktree_branch( path: resolved_path )
				puts_verbose "worktree_remove: path=#{resolved_path} branch=#{branch} force=#{force}"

				# Step 1: remove the worktree (directory + git registration).
				# Try safe removal first. Only use --force if the user explicitly requested it.
				rm_args = [ "worktree", "remove" ]
				rm_args << "--force" if force
				rm_args << resolved_path
				rm_stdout, rm_stderr, rm_success, = git_run( *rm_args )
				unless rm_success
					error_text = rm_stderr.to_s.strip
					error_text = "unable to remove worktree" if error_text.empty?
					if !force && ( error_text.downcase.include?( "untracked" ) || error_text.downcase.include?( "modified" ) )
						puts_line "Worktree has uncommitted changes: #{File.basename( resolved_path )}"
						puts_line "  Commit or discard changes first, or use --force to override."
					else
						puts_line "ERROR: #{error_text}"
					end
					return EXIT_ERROR
				end
				puts_verbose "worktree_removed: #{resolved_path}"

				# Step 2: delete the local branch.
				if branch && !config.protected_branches.include?( branch )
					_, del_stderr, del_success, = git_run( "branch", "-D", branch )
					if del_success
						puts_verbose "branch_deleted: #{branch}"
					else
						puts_verbose "branch_delete_skipped: #{branch} reason=#{del_stderr.to_s.strip}"
					end
				end

				# Step 3: delete the remote branch (best-effort).
				if branch && !config.protected_branches.include?( branch )
					remote_branch = branch
					git_run( "push", config.git_remote, "--delete", remote_branch )
					puts_verbose "remote_branch_deleted: #{config.git_remote}/#{remote_branch}"
				end

				unless verbose?
					puts_line "Worktree removed: #{File.basename( resolved_path )}"
				end
				EXIT_OK
			end

		private

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
