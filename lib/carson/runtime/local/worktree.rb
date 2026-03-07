# Safe worktree lifecycle management for coding agents.
# Two operations: create and remove. Create auto-syncs main before branching.
# Remove is safe by default — guards against CWD-inside-worktree and unpushed
# commits. Content-aware: allows removal after squash/rebase merge without --force.
# Supports --json for machine-readable structured output with recovery commands.
module Carson
	class Runtime
		module Local

			# Agent directory names whose worktrees Carson may sweep.
			AGENT_WORKTREE_DIRS = %w[ .claude .codex ].freeze

			# Creates a new worktree under .claude/worktrees/<name> with a fresh branch.
			# Uses main_worktree_root so this works even when called from inside a worktree.
			def worktree_create!( name:, json_output: false )
				worktrees_dir = File.join( main_worktree_root, ".claude", "worktrees" )
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

				# Sync main from remote before branching so the worktree starts
				# from the latest code. Prevents stale-base merge conflicts later.
				# Best-effort — if pull fails (non-ff, offline), continue anyway.
				main_root = main_worktree_root
				_, _, pull_ok, = Open3.capture3( "git", "-C", main_root, "pull", "--ff-only", config.git_remote, base )
				puts_verbose pull_ok.success? ? "synced #{base} before branching" : "sync skipped — continuing from local #{base}"

				# Ensure .claude/ is excluded from git status in the host repository.
				# Uses .git/info/exclude (local-only, never committed) to respect the outsider boundary.
				ensure_claude_dir_excluded!

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

				# Safety: refuse if the caller's shell CWD is inside the worktree.
				# Removing a directory while a shell is inside it kills the shell permanently.
				if cwd_inside_worktree?( worktree_path: resolved_path )
					safe_root = main_worktree_root
					return worktree_finish(
						result: { command: "worktree remove", status: "block", name: File.basename( resolved_path ),
							error: "current working directory is inside this worktree",
							recovery: "cd #{safe_root} && carson worktree remove #{File.basename( resolved_path )}" },
						exit_code: EXIT_BLOCK, json_output: json_output
					)
				end

				branch = worktree_branch( path: resolved_path )
				puts_verbose "worktree_remove: path=#{resolved_path} branch=#{branch} force=#{force}"

				# Safety: refuse if the branch has unpushed commits (unless --force).
				# Prevents accidental destruction of work that exists only locally.
				unless force
					unpushed = check_unpushed_commits( branch: branch, worktree_path: resolved_path )
					if unpushed
						return worktree_finish(
							result: { command: "worktree remove", status: "block", name: File.basename( resolved_path ),
								branch: branch,
								error: unpushed[ :error ],
								recovery: unpushed[ :recovery ] },
							exit_code: EXIT_BLOCK, json_output: json_output
						)
					end
				end

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

			# Removes agent-owned worktrees whose branch content is already on main.
			# Scans AGENT_WORKTREE_DIRS (e.g. .claude/worktrees/, .codex/worktrees/)
			# under the main repo root. Safe: skips detached HEADs, the caller's CWD,
			# and dirty working trees (git worktree remove refuses without --force).
			def sweep_stale_worktrees!
				main_root = main_worktree_root
				worktrees = worktree_list

				agent_prefixes = AGENT_WORKTREE_DIRS.filter_map do |dir|
					full = File.join( main_root, dir, "worktrees" )
					File.join( realpath_safe( full ), "" ) if Dir.exist?( full )
				end
				return if agent_prefixes.empty?

				worktrees.each do |wt|
					path = wt.fetch( :path )
					branch = wt.fetch( :branch, nil )
					next unless branch
					next unless agent_prefixes.any? { |prefix| path.start_with?( prefix ) }
					next if cwd_inside_worktree?( worktree_path: path )
					next unless branch_absorbed_into_main?( branch: branch )

					# Remove the worktree (no --force: refuses if dirty working tree).
					_, _, rm_success, = git_run( "worktree", "remove", path )
					next unless rm_success

					puts_verbose "swept stale worktree: #{File.basename( path )} (branch: #{branch})"

					# Delete the local branch now that no worktree holds it.
					if !config.protected_branches.include?( branch )
						git_run( "branch", "-D", branch )
						puts_verbose "deleted branch: #{branch}"
					end
				end
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

			# Returns true when the process CWD is inside the given worktree path.
			# This detects the most common session-crash scenario: removing a worktree
			# while the caller's shell is inside it.
			# Uses realpath on both sides to handle symlink differences (e.g. /tmp vs /private/tmp).
			def cwd_inside_worktree?( worktree_path: )
				cwd = realpath_safe( Dir.pwd )
				wt = realpath_safe( worktree_path )
				normalised_wt = File.join( wt, "" )
				cwd == wt || cwd.start_with?( normalised_wt )
			rescue StandardError
				false
			end

			# Checks whether a branch has unpushed commits that would be lost on removal.
			# Content-aware: after squash/rebase merge, SHAs differ but tree content may match main. Compares content, not SHAs.
			# Returns nil if safe, or { error:, recovery: } hash if unpushed work exists.
			def check_unpushed_commits( branch:, worktree_path: )
				return nil unless branch

				remote = config.git_remote
				remote_ref = "#{remote}/#{branch}"
				ahead, _, ahead_status, = Open3.capture3( "git", "rev-list", "--count", "#{remote_ref}..#{branch}", chdir: worktree_path )
				if !ahead_status.success?
					# Remote ref does not exist. Only block if the branch has unique commits vs main.
					unique, _, unique_status, = Open3.capture3( "git", "rev-list", "--count", "#{config.main_branch}..#{branch}", chdir: worktree_path )
					if unique_status.success? && unique.strip.to_i > 0
						# Content-aware check: after squash/rebase merge, commit SHAs differ
						# but the tree content may be identical to main. Compare content,
						# not SHAs — if the diff is empty, the work is already on main.
						diff_out, _, diff_ok, = Open3.capture3( "git", "diff", "--quiet", config.main_branch, branch, chdir: worktree_path )
						unless diff_ok.success?
							return { error: "branch has not been pushed to #{remote}",
								recovery: "git -C #{worktree_path} push -u #{remote} #{branch}, or use --force to override" }
						end
						# Diff is empty — content is on main (squash/rebase merged). Safe.
						puts_verbose "branch #{branch} content matches main — squash/rebase merged, safe to remove"
					end
				elsif ahead.strip.to_i > 0
					return { error: "worktree has unpushed commits",
						recovery: "git -C #{worktree_path} push #{remote} #{branch}, or use --force to override" }
				end

				nil
			end

			# Returns the branch checked out in the worktree that contains the process CWD,
			# or nil if CWD is not inside any worktree. Used by prune to proactively
			# protect the CWD worktree's branch from deletion.
			# Matches the longest (most specific) path because worktree directories
			# live under the main repo tree (.claude/worktrees/).
			def cwd_worktree_branch
				cwd = realpath_safe( Dir.pwd )
				best_branch = nil
				best_length = -1
				worktree_list.each do |wt|
					wt_path = wt.fetch( :path )
					normalised = File.join( wt_path, "" )
					if ( cwd == wt_path || cwd.start_with?( normalised ) ) && wt_path.length > best_length
						best_branch = wt.fetch( :branch, nil )
						best_length = wt_path.length
					end
				end
				best_branch
			rescue StandardError
				nil
			end

			# Returns the main (non-worktree) repository root.
			# Uses git-common-dir to find the shared .git directory, then takes its parent.
			# Falls back to repo_root if detection fails.
			def main_worktree_root
				common_dir, _, success, = git_run( "rev-parse", "--path-format=absolute", "--git-common-dir" )
				return File.dirname( common_dir.strip ) if success && !common_dir.strip.empty?

				repo_root
			end

			# Adds .claude/ to .git/info/exclude if not already present.
			# This prevents worktree directories from appearing as untracked files
			# in the host repository. Uses the local exclude file (never committed)
			# so the host repo's .gitignore is never touched.
			# Uses main_worktree_root — worktrees have .git as a file, not a directory.
			def ensure_claude_dir_excluded!
				git_dir = File.join( main_worktree_root, ".git" )
				return unless File.directory?( git_dir )

				info_dir = File.join( git_dir, "info" )
				exclude_path = File.join( info_dir, "exclude" )

				FileUtils.mkdir_p( info_dir )
				existing = File.exist?( exclude_path ) ? File.read( exclude_path ) : ""
				return if existing.lines.any? { |line| line.strip == ".claude/" }

				File.open( exclude_path, "a" ) { |f| f.puts ".claude/" }
			rescue StandardError
				# Best-effort — do not block worktree creation if exclude fails.
			end

			# Resolves a worktree path: if it's a bare name, look under .claude/worktrees/.
			# Returns the canonical (realpath) form so comparisons against git worktree list succeed,
			# even when the OS resolves symlinks differently (e.g. /tmp → /private/tmp on macOS).
			# Uses main_worktree_root (not repo_root) so resolution works from inside worktrees.
			def resolve_worktree_path( worktree_path: )
				if worktree_path.include?( "/" )
					return realpath_safe( worktree_path )
				end

				root = main_worktree_root
				candidate = File.join( root, ".claude", "worktrees", worktree_path )
				return realpath_safe( candidate ) if Dir.exist?( candidate )

				realpath_safe( worktree_path )
			end

			# Returns true if the path is a registered git worktree.
			# Compares using realpath to handle symlink differences.
			def worktree_registered?( path: )
				canonical = realpath_safe( path )
				worktree_list.any? { |wt| wt.fetch( :path ) == canonical }
			end

			# Returns the branch name checked out in a worktree, or nil.
			# Compares using realpath to handle symlink differences.
			def worktree_branch( path: )
				canonical = realpath_safe( path )
				entry = worktree_list.find { |wt| wt.fetch( :path ) == canonical }
				entry&.fetch( :branch, nil )
			end

			# Parses `git worktree list --porcelain` into structured entries.
			# Normalises paths with realpath so comparisons work across symlink differences.
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
						current[ :path ] = realpath_safe( line.sub( "worktree ", "" ) )
					elsif line.start_with?( "branch " )
						current[ :branch ] = line.sub( "branch refs/heads/", "" )
					elsif line == "detached"
						current[ :branch ] = nil
					end
				end
				entries << current unless current.empty?
				entries
			end

			# Resolves a path to its canonical form, tolerating non-existent paths.
			# Falls back to File.expand_path when the path does not exist yet.
			def realpath_safe( path )
				File.realpath( path )
			rescue Errno::ENOENT
				File.expand_path( path )
			end
		end

		include Local
	end
end
