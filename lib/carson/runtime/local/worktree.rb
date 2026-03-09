# Thin worktree delegate layer on Runtime.
# Lifecycle operations live on Carson::Worktree; this module delegates
# and keeps only methods that genuinely belong on Runtime (path resolution,
# CWD branch detection).
module Carson
	class Runtime
		module Local

			# --- Delegates to Carson::Worktree ---

			# Creates a new worktree under .claude/worktrees/<name>.
			def worktree_create!( name:, json_output: false )
				Worktree.create!( name: name, runtime: self, json_output: json_output )
			end

			# Removes a worktree: directory, git registration, and branch.
			def worktree_remove!( worktree_path:, force: false, json_output: false )
				Worktree.remove!( path: worktree_path, runtime: self, force: force, json_output: json_output )
			end

			# Removes agent-owned worktrees whose branch content is already on main.
			def sweep_stale_worktrees!
				Worktree.sweep_stale!( runtime: self )
			end

			# Returns all registered worktrees as Carson::Worktree instances.
			def worktree_list
				Worktree.list( runtime: self )
			end

			# --- Methods that stay on Runtime ---

			# Returns the branch checked out in the worktree that contains the process CWD,
			# or nil if CWD is not inside any worktree. Used by prune to proactively
			# protect the CWD worktree's branch from deletion.
			# Matches the longest (most specific) path because worktree directories
			# live under the main repo tree (.claude/worktrees/).
			def cwd_worktree_branch
				cwd = realpath_safe( Dir.pwd )
				best_branch = nil
				best_length = -1
				worktree_list.each do |worktree|
					normalised = File.join( worktree.path, "" )
					if ( cwd == worktree.path || cwd.start_with?( normalised ) ) && worktree.path.length > best_length
						best_branch = worktree.branch
						best_length = worktree.path.length
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
