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
			def worktree_remove!( worktree_path:, force: false, skip_unpushed: false, json_output: false )
				Worktree.remove!( path: worktree_path, runtime: self, force: force, skip_unpushed: skip_unpushed, json_output: json_output )
			end

			# Removes agent-owned worktrees whose branch content is already on main.
			def sweep_stale_worktrees!
				Worktree.sweep_stale!( runtime: self )
			end

			# Returns all registered worktrees as Carson::Worktree instances.
			def worktree_list
				Worktree.list( runtime: self )
			end

			# Human and JSON status surface for all registered worktrees.
			def worktree_list!( json_output: false )
				entries = worktree_inventory
				result = {
					command: "worktree list",
					status: "ok",
					worktrees: entries,
					exit_code: EXIT_OK
				}

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_worktree_list( entries: entries )
				end

				EXIT_OK
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
			# Preserves canonical parents for missing paths so deleted worktrees still
			# compare equal to git's recorded path (for example /tmp vs /private/tmp).
			def realpath_safe( path )
				File.realpath( path )
			rescue Errno::ENOENT
				expanded = File.expand_path( path )
				missing_segments = []
				candidate = expanded

				until File.exist?( candidate ) || Dir.exist?( candidate )
					parent = File.dirname( candidate )
					break if parent == candidate

					missing_segments.unshift( File.basename( candidate ) )
					candidate = parent
				end

				base = if File.exist?( candidate ) || Dir.exist?( candidate )
					File.realpath( candidate )
				else
					candidate
				end

				missing_segments.empty? ? base : File.join( base, *missing_segments )
			end

		private

			def worktree_inventory
				worktree_list.map { |worktree| worktree_inventory_entry( worktree: worktree ) }
			end

			def worktree_inventory_entry( worktree: )
				cleanup = classify_worktree_cleanup( worktree: worktree )
				pull_request = worktree_pull_request( branch: worktree.branch )

				{
					name: File.basename( worktree.path ),
					branch: worktree.branch,
					path: worktree.path,
					main: worktree.path == main_worktree_root,
					exists: worktree.exists?,
					dirty: worktree.dirty?,
					held_by_current_shell: worktree.holds_cwd?,
					held_by_other_process: worktree.held_by_other_process?,
					absorbed_into_main: cleanup.fetch( :absorbed, false ),
					pull_request: pull_request,
					cleanup: {
						action: cleanup.fetch( :action ).to_s,
						reason: cleanup.fetch( :reason )
					}
				}
			end

			# Shared cleanup classifier used by `worktree list` and `housekeep`.
			def classify_worktree_cleanup( worktree: )
				return { action: :skip, reason: "main worktree", absorbed: false } if worktree.path == main_worktree_root
				return { action: :skip, reason: "detached HEAD", absorbed: false } if worktree.branch.to_s.strip.empty?
				return { action: :skip, reason: "held by current shell", absorbed: false } if worktree.holds_cwd?
				return { action: :skip, reason: "held by another process", absorbed: false } if worktree.held_by_other_process?
				return { action: :reap, reason: "directory missing (destroyed externally)", absorbed: false } unless worktree.exists?

				absorbed = branch_absorbed_into_main?( branch: worktree.branch )
				return { action: :skip, reason: "dirty worktree", absorbed: absorbed } if worktree.dirty?
				return { action: :skip, reason: "gh CLI not available for PR check", absorbed: absorbed } unless gh_available?

				tip_sha = worktree_branch_tip_sha( branch: worktree.branch )
				return { action: :skip, reason: "cannot read branch tip SHA", absorbed: absorbed } if tip_sha.nil?

				merged_pr, = merged_pr_for_branch( branch: worktree.branch, branch_tip_sha: tip_sha )
				return { action: :reap, reason: "merged #{pr_short_ref( merged_pr.fetch( :url ) )}", absorbed: absorbed } unless merged_pr.nil?
				return { action: :skip, reason: "open PR exists", absorbed: absorbed } if branch_has_open_pr?( branch: worktree.branch )

				abandoned_pr, = abandoned_pr_for_branch( branch: worktree.branch, branch_tip_sha: tip_sha )
				return { action: :reap, reason: "closed abandoned #{pr_short_ref( abandoned_pr.fetch( :url ) )}", absorbed: absorbed } unless abandoned_pr.nil?

				{ action: :skip, reason: "no evidence to reap", absorbed: absorbed }
			end

			def worktree_branch_tip_sha( branch: )
				git_capture!( "rev-parse", "--verify", branch ).strip
			rescue StandardError
				nil
			end

			def worktree_pull_request( branch: )
				return { state: nil, number: nil, url: nil, error: nil } if branch.to_s.strip.empty?
				return { state: nil, number: nil, url: nil, error: "gh unavailable" } unless gh_available?

				owner, repo = repository_coordinates
				stdout_text, stderr_text, success, = gh_run(
					"api", "repos/#{owner}/#{repo}/pulls",
					"--method", "GET",
					"-f", "state=all",
					"-f", "head=#{owner}:#{branch}",
					"-f", "per_page=100"
				)
				unless success
					error_text = gh_error_text(
						stdout_text: stdout_text,
						stderr_text: stderr_text,
						fallback: "unable to read pull request for #{branch}"
					)
					return { state: nil, number: nil, url: nil, error: error_text }
				end

				entries = Array( JSON.parse( stdout_text ) )
				return { state: nil, number: nil, url: nil, error: nil } if entries.empty?

				chosen = entries.find { |entry| normalise_rest_pull_request_state( entry: entry ) == "OPEN" } ||
					entries.max_by { |entry| parse_time_or_nil( text: entry[ "updated_at" ] ) || Time.at( 0 ) }

				{
					state: normalise_rest_pull_request_state( entry: chosen ),
					number: chosen[ "number" ],
					url: chosen[ "html_url" ].to_s,
					error: nil
				}
			rescue JSON::ParserError => exception
				{ state: nil, number: nil, url: nil, error: "invalid gh JSON response (#{exception.message})" }
			rescue StandardError => exception
				{ state: nil, number: nil, url: nil, error: exception.message }
			end

			def print_worktree_list( entries: )
				puts_line "Worktrees:"
				return puts_line "  none" if entries.empty?

				entries.each do |entry|
					label = entry.fetch( :main ) ? "#{entry.fetch( :name )} (main)" : entry.fetch( :name )
					state = []
					state << entry.fetch( :branch ) unless entry.fetch( :branch ).to_s.empty?
					state << ( entry.fetch( :exists ) ? ( entry.fetch( :dirty ) ? "dirty" : "clean" ) : "missing" )
					state << "held by current shell" if entry.fetch( :held_by_current_shell )
					state << "held by another process" if entry.fetch( :held_by_other_process )
					state << worktree_pull_request_text( pull_request: entry.fetch( :pull_request ) )
					state << "absorbed into main" if entry.fetch( :absorbed_into_main )

					recommendation = entry.fetch( :cleanup )
					action = recommendation.fetch( :action ) == "reap" ? "reap" : "keep"
					puts_line "- #{label}: #{state.join( ', ' )}"
					puts_line "  Recommendation: #{action} — #{recommendation.fetch( :reason )}"
				end
			end

			def worktree_pull_request_text( pull_request: )
				return "PR unknown (#{pull_request.fetch( :error )})" unless pull_request.fetch( :error ).nil?
				return "PR none" if pull_request.fetch( :number ).nil?

				"PR ##{pull_request.fetch( :number )} #{pull_request.fetch( :state )}"
			end

			def pr_short_ref( url )
				return "PR" if url.nil? || url.empty?

				match = url.match( /\/pull\/(\d+)$/ )
				match ? "PR ##{match[ 1 ]}" : "PR"
			end
		end

		include Local
	end
end
