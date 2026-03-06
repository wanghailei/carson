module Carson
	class Runtime
		module Local
			# Removes stale local branches (gone upstream), orphan branches (no tracking) with merged PR evidence,
			# and absorbed branches (content already on main, no open PR).
			def prune!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				git_system!( "fetch", config.git_remote, "--prune" )
				active_branch = current_branch
				counters = { deleted: 0, skipped: 0 }

				stale_branches = stale_local_branches
				prune_stale_branch_entries( stale_branches: stale_branches, active_branch: active_branch, counters: counters )

				orphan_branches = orphan_local_branches( active_branch: active_branch )
				prune_orphan_branch_entries( orphan_branches: orphan_branches, counters: counters )

				absorbed_branches = absorbed_local_branches( active_branch: active_branch )
				prune_absorbed_branch_entries( absorbed_branches: absorbed_branches, counters: counters )

				return prune_no_stale_branches if counters.fetch( :deleted ).zero? && counters.fetch( :skipped ).zero?

				puts_verbose "prune_summary: deleted=#{counters.fetch( :deleted )} skipped=#{counters.fetch( :skipped )}"
				unless verbose?
					deleted_count = counters.fetch( :deleted )
					skipped_count = counters.fetch( :skipped )
					message = if deleted_count > 0 && skipped_count > 0
						"Pruned #{deleted_count}, skipped #{skipped_count} (--verbose for details)."
					elsif deleted_count > 0
						"Pruned #{deleted_count} stale branch#{plural_suffix( count: deleted_count )}."
					else
						"Skipped #{skipped_count} branch#{plural_suffix( count: skipped_count )} (--verbose for details)."
					end
					puts_line message
				end
				EXIT_OK
			end

		private

			def prune_no_stale_branches
				if verbose?
					puts_line "OK: no stale or orphan branches to prune."
				else
					puts_line "No stale branches."
				end
				EXIT_OK
			end

			def prune_stale_branch_entries( stale_branches:, active_branch:, counters: { deleted: 0, skipped: 0 } )
				stale_branches.each do |entry|
					outcome = prune_stale_branch_entry( entry: entry, active_branch: active_branch )
					counters[ outcome ] += 1
				end
				counters
			end

			def prune_stale_branch_entry( entry:, active_branch: )
				branch = entry.fetch( :branch )
				upstream = entry.fetch( :upstream )
				return prune_skip_stale_branch( type: :protected, branch: branch, upstream: upstream ) if config.protected_branches.include?( branch )
				return prune_skip_stale_branch( type: :current, branch: branch, upstream: upstream ) if branch == active_branch

				prune_delete_stale_branch( branch: branch, upstream: upstream )
			end

			def prune_skip_stale_branch( type:, branch:, upstream: )
				status = type == :protected ? "skip_protected_branch" : "skip_current_branch"
				puts_verbose "#{status}: #{branch} (upstream=#{upstream})"
				:skipped
			end

			def prune_delete_stale_branch( branch:, upstream: )
				stdout_text, stderr_text, success, = git_run( "branch", "-d", branch )
				return prune_safe_delete_success( branch: branch, upstream: upstream, stdout_text: stdout_text ) if success

				delete_error_text = normalise_branch_delete_error( error_text: stderr_text )
				prune_force_delete_stale_branch(
					branch: branch,
					upstream: upstream,
					delete_error_text: delete_error_text
				)
			end

			def prune_safe_delete_success( branch:, upstream:, stdout_text: )
				out.print stdout_text if verbose? && !stdout_text.empty?
				puts_verbose "deleted_local_branch: #{branch} (upstream=#{upstream})"
				:deleted
			end

			def prune_force_delete_stale_branch( branch:, upstream:, delete_error_text: )
				merged_pr, force_error = force_delete_evidence_for_stale_branch(
					branch: branch,
					delete_error_text: delete_error_text
				)
				return prune_force_delete_skipped( branch: branch, upstream: upstream, delete_error_text: delete_error_text, force_error: force_error ) if merged_pr.nil?

				force_stdout, force_stderr, force_success = force_delete_local_branch( branch: branch )
				return prune_force_delete_success( branch: branch, upstream: upstream, merged_pr: merged_pr, force_stdout: force_stdout ) if force_success

				prune_force_delete_failed( branch: branch, upstream: upstream, force_stderr: force_stderr )
			end

			def prune_force_delete_success( branch:, upstream:, merged_pr:, force_stdout: )
				out.print force_stdout if verbose? && !force_stdout.empty?
				puts_verbose "deleted_local_branch_force: #{branch} (upstream=#{upstream}) merged_pr=#{merged_pr.fetch( :url )}"
				:deleted
			end

			def prune_force_delete_failed( branch:, upstream:, force_stderr: )
				force_error_text = normalise_branch_delete_error( error_text: force_stderr )
				puts_verbose "fail_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error_text}"
				:skipped
			end

			def prune_force_delete_skipped( branch:, upstream:, delete_error_text:, force_error: )
				puts_verbose "skip_delete_branch: #{branch} (upstream=#{upstream}) reason=#{delete_error_text}"
				puts_verbose "skip_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error}" unless force_error.to_s.strip.empty?
				:skipped
			end

			def normalise_branch_delete_error( error_text: )
				text = error_text.to_s.strip
				text.empty? ? "unknown error" : text
			end

			# Attempts git branch -D. If blocked by a worktree, safely removes the worktree
			# first (no --force — refuses if worktree has uncommitted changes) and retries.
			def force_delete_local_branch( branch: )
				stdout, stderr, success, = git_run( "branch", "-D", branch )
				return [ stdout, stderr, success ] if success
				return [ stdout, stderr, false ] unless worktree_blocked_error?( error_text: stderr )

				wt_path = worktree_path_for_branch( branch: branch )
				return [ stdout, stderr, false ] if wt_path.nil?

				rm_stdout, rm_stderr, rm_success, = git_run( "worktree", "remove", wt_path )
				unless rm_success
					error_text = rm_stderr.to_s.strip
					puts_verbose "skip_worktree_remove: #{wt_path} (branch=#{branch}) reason=#{error_text}"
					return [ stdout, stderr, false ]
				end
				puts_verbose "worktree_removed_for_prune: #{wt_path} (branch=#{branch})"

				git_run( "branch", "-D", branch )
			end

			def worktree_blocked_error?( error_text: )
				error_text.to_s.downcase.include?( "used by worktree" )
			end

			# Returns the worktree path for a branch, or nil if not checked out in any worktree.
			def worktree_path_for_branch( branch: )
				entry = worktree_list.find { |wt| wt.fetch( :branch, nil ) == branch }
				entry&.fetch( :path, nil )
			end

			# Detects local branches whose upstream tracking is marked [gone] after fetch --prune.
			def stale_local_branches
				git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" ).lines.map do |line|
					branch, upstream, track = line.strip.split( "\t", 3 )
					upstream = upstream.to_s
					track = track.to_s
					next if branch.to_s.empty? || upstream.empty?
					next unless upstream.start_with?( "#{config.git_remote}/" ) && track.include?( "gone" )

					{ branch: branch, upstream: upstream, track: track }
				end.compact
			end

			# Detects local branches with no upstream tracking ref — candidates for orphan pruning.
			def orphan_local_branches( active_branch: )
				git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads" ).lines.filter_map do |line|
					branch, upstream = line.strip.split( "\t", 2 )
					branch = branch.to_s.strip
					upstream = upstream.to_s.strip
					next if branch.empty?
					next unless upstream.empty?
					next if config.protected_branches.include?( branch )
					next if branch == active_branch
					next if branch == TEMPLATE_SYNC_BRANCH

					branch
				end
			end

			# Detects local branches whose upstream still exists but whose content is already on main.
			# Two-step evidence: (1) find the merge-base, (2) verify every file the branch changed
			# relative to the merge-base has identical content on main.
			def absorbed_local_branches( active_branch: )
				git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" ).lines.filter_map do |line|
					branch, upstream, track = line.strip.split( "\t", 3 )
					branch = branch.to_s.strip
					upstream = upstream.to_s.strip
					track = track.to_s
					next if branch.empty?
					next if upstream.empty?
					next if track.include?( "gone" )
					next if config.protected_branches.include?( branch )
					next if branch == active_branch
					next if branch == TEMPLATE_SYNC_BRANCH

					next unless branch_absorbed_into_main?( branch: branch )

					{ branch: branch, upstream: upstream }
				end
			end

			# Returns true when the branch has no unique content relative to main.
			def branch_absorbed_into_main?( branch: )
				# Fast path: branch is a strict ancestor of main (fully merged).
				_, _, is_ancestor, = git_run( "merge-base", "--is-ancestor", branch, config.main_branch )
				return true if is_ancestor

				# Find the merge-base between main and the branch.
				merge_base_text, _, mb_success, = git_run( "merge-base", config.main_branch, branch )
				return false unless mb_success

				merge_base = merge_base_text.to_s.strip
				return false if merge_base.empty?

				# List every file the branch changed relative to the merge-base.
				changed_text, _, changed_success, = git_run( "diff", "--name-only", merge_base, branch )
				return false unless changed_success

				changed_files = changed_text.to_s.strip.lines.map( &:strip ).reject( &:empty? )
				return true if changed_files.empty?

				# Compare only those files between branch tip and main tip.
				# If identical, every branch change is already on main.
				_, _, identical, = git_run( "diff", "--quiet", branch, config.main_branch, "--", *changed_files )
				identical
			end

			# Processes absorbed branches: verifies no open PR exists before deleting local and remote.
			def prune_absorbed_branch_entries( absorbed_branches:, counters: )
				return counters if absorbed_branches.empty?
				return counters unless gh_available?

				absorbed_branches.each do |entry|
					outcome = prune_absorbed_branch_entry( branch: entry.fetch( :branch ), upstream: entry.fetch( :upstream ) )
					counters[ outcome ] += 1
				end
				counters
			end

			# Checks a single absorbed branch for open PRs and deletes local + remote if safe.
			def prune_absorbed_branch_entry( branch:, upstream: )
				if branch_has_open_pr?( branch: branch )
					puts_verbose "skip_absorbed_branch: #{branch} reason=open PR exists"
					return :skipped
				end

				force_stdout, force_stderr, force_success = force_delete_local_branch( branch: branch )
				unless force_success
					error_text = normalise_branch_delete_error( error_text: force_stderr )
					puts_verbose "fail_delete_absorbed_branch: #{branch} reason=#{error_text}"
					return :skipped
				end

				out.print force_stdout if verbose? && !force_stdout.empty?

				remote_branch = upstream.sub( "#{config.git_remote}/", "" )
				git_run( "push", config.git_remote, "--delete", remote_branch )

				puts_verbose "deleted_absorbed_branch: #{branch} (upstream=#{upstream})"
				:deleted
			end

			# Returns true if the branch has at least one open PR.
			def branch_has_open_pr?( branch: )
				owner, repo = repository_coordinates
				stdout_text, _, success, = gh_run(
					"api", "repos/#{owner}/#{repo}/pulls",
					"--method", "GET",
					"-f", "state=open",
					"-f", "head=#{owner}:#{branch}",
					"-f", "per_page=1"
				)
				return true unless success

				results = Array( JSON.parse( stdout_text ) )
				!results.empty?
			rescue StandardError
				true
			end

			# Processes orphan branches: verifies merged PR evidence via GitHub API before deleting.
			def prune_orphan_branch_entries( orphan_branches:, counters: )
				return counters if orphan_branches.empty?
				return counters unless gh_available?

				orphan_branches.each do |branch|
					outcome = prune_orphan_branch_entry( branch: branch )
					counters[ outcome ] += 1
				end
				counters
			end

			# Checks a single orphan branch for merged PR evidence and force-deletes if confirmed.
			def prune_orphan_branch_entry( branch: )
				tip_sha_text, tip_sha_error, tip_sha_success, = git_run( "rev-parse", "--verify", branch.to_s )
				unless tip_sha_success
					error_text = tip_sha_error.to_s.strip
					error_text = "unable to read local branch tip sha" if error_text.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=#{error_text}"
					return :skipped
				end
				branch_tip_sha = tip_sha_text.to_s.strip
				if branch_tip_sha.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=unable to read local branch tip sha"
					return :skipped
				end

				merged_pr, error = merged_pr_for_branch( branch: branch, branch_tip_sha: branch_tip_sha )
				if merged_pr.nil?
					reason = error.to_s.strip
					reason = "no merged PR evidence for branch tip into #{config.main_branch}" if reason.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=#{reason}"
					return :skipped
				end

				force_stdout, force_stderr, force_success = force_delete_local_branch( branch: branch )
				if force_success
					out.print force_stdout if verbose? && !force_stdout.empty?
					puts_verbose "deleted_orphan_branch: #{branch} merged_pr=#{merged_pr.fetch( :url )}"
					return :deleted
				end

				force_error_text = normalise_branch_delete_error( error_text: force_stderr )
				puts_verbose "fail_delete_orphan_branch: #{branch} reason=#{force_error_text}"
				:skipped
			end

			# Safe delete can fail after squash merges because branch tip is no longer an ancestor.
			def non_merged_delete_error?( error_text: )
				error_text.to_s.downcase.include?( "not fully merged" )
			end

			# Guarded force-delete policy for stale branches.
			# Checks merged PR evidence first (exact SHA match), then falls back to
			# absorbed-into-main detection (covers rebase merges where commit hashes change).
			def force_delete_evidence_for_stale_branch( branch:, delete_error_text: )
				return [ nil, "safe delete failure is not merge-related" ] unless non_merged_delete_error?( error_text: delete_error_text )
				return [ nil, "gh CLI not available; cannot verify merged PR evidence" ] unless gh_available?

				tip_sha_text, tip_sha_error, tip_sha_success, = git_run( "rev-parse", "--verify", branch.to_s )
				unless tip_sha_success
					error_text = tip_sha_error.to_s.strip
					error_text = "unable to read local branch tip sha" if error_text.empty?
					return [ nil, error_text ]
				end
				branch_tip_sha = tip_sha_text.to_s.strip
				return [ nil, "unable to read local branch tip sha" ] if branch_tip_sha.empty?

				merged_pr, error = merged_pr_for_branch( branch: branch, branch_tip_sha: branch_tip_sha )
				return [ merged_pr, error ] unless merged_pr.nil?

				# Fallback: branch content is already on main (rebase/cherry-pick merges rewrite SHAs).
				if branch_absorbed_into_main?( branch: branch )
					absorbed_evidence = {
						number: nil,
						url: "absorbed into #{config.main_branch}",
						merged_at: Time.now.utc.iso8601,
						head_sha: branch_tip_sha
					}
					return [ absorbed_evidence, nil ]
				end

				[ nil, error ]
			end

			# Finds merged PR evidence for the exact local branch tip.
			def merged_pr_for_branch( branch:, branch_tip_sha: )
				owner, repo = repository_coordinates
				results = []
				page = 1
				max_pages = 50
				loop do
					stdout_text, stderr_text, success, = gh_run(
						"api", "repos/#{owner}/#{repo}/pulls",
						"--method", "GET",
						"-f", "state=closed",
						"-f", "base=#{config.main_branch}",
						"-f", "head=#{owner}:#{branch}",
						"-f", "sort=updated",
						"-f", "direction=desc",
						"-f", "per_page=100",
						"-f", "page=#{page}"
					)
					unless success
						error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to query merged PR evidence for branch #{branch}" )
						return [ nil, error_text ]
					end
					page_nodes = Array( JSON.parse( stdout_text ) )
					break if page_nodes.empty?

					page_nodes.each do |entry|
						next unless entry.dig( "head", "ref" ).to_s == branch.to_s
						next unless entry.dig( "base", "ref" ).to_s == config.main_branch
						next unless entry.dig( "head", "sha" ).to_s == branch_tip_sha

						merged_at = parse_time_or_nil( text: entry[ "merged_at" ] )
						next if merged_at.nil?

						results << {
							number: entry[ "number" ],
							url: entry[ "html_url" ].to_s,
							merged_at: merged_at.utc.iso8601,
							head_sha: entry.dig( "head", "sha" ).to_s
						}
						end
						if page >= max_pages
							probe_stdout_text, probe_stderr_text, probe_success, = gh_run(
								"api", "repos/#{owner}/#{repo}/pulls",
								"--method", "GET",
								"-f", "state=closed",
								"-f", "base=#{config.main_branch}",
								"-f", "head=#{owner}:#{branch}",
								"-f", "sort=updated",
								"-f", "direction=desc",
								"-f", "per_page=100",
								"-f", "page=#{page + 1}"
							)
							unless probe_success
								error_text = gh_error_text( stdout_text: probe_stdout_text, stderr_text: probe_stderr_text, fallback: "unable to verify merged PR pagination limit for branch #{branch}" )
								return [ nil, error_text ]
							end
							probe_nodes = Array( JSON.parse( probe_stdout_text ) )
							return [ nil, "merged PR lookup exceeded pagination safety limit (#{max_pages} pages) for branch #{branch}" ] unless probe_nodes.empty?
							break
						end
						page += 1
					end
				latest = results.max_by { |item| item.fetch( :merged_at ) }
				return [ nil, "no merged PR evidence for branch tip #{branch_tip_sha} into #{config.main_branch}" ] if latest.nil?

				[ latest, nil ]
			rescue JSON::ParserError => e
				[ nil, "invalid gh JSON response (#{e.message})" ]
			rescue StandardError => e
				[ nil, e.message ]
			end
		end
	end
end
