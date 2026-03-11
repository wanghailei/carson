# Removes stale local branches (gone upstream), orphan branches (no tracking) with merged PR evidence,
# and absorbed branches (content already on main, no open PR).
# Supports --json for machine-readable structured output with per-branch action details.
module Carson
	class Runtime
		module Local
			def prune!( json_output: false )
				fingerprint_status = block_if_outsider_fingerprints!
				unless fingerprint_status.nil?
					if json_output
						output.puts JSON.pretty_generate( {
							command: "prune", status: "block",
							error: "Carson-owned artefacts detected in host repository",
							recovery: "remove Carson-owned files (.carson.yml, bin/carson, .tools/carson) then retry",
							exit_code: EXIT_BLOCK
						} )
					end
					return fingerprint_status
				end

				prune_git!( "fetch", config.git_remote, "--prune", json_output: json_output )

				# Clean stale worktree entries whose directories no longer exist.
				# Unblocks branch deletion for branches held by dead worktrees.
				git_run( "worktree", "prune" )

				active_branch = current_branch
				cwd_branch = cwd_worktree_branch
				counters = { deleted: 0, skipped: 0 }
				branches = []

				stale_branches = stale_local_branches
				prune_stale_branch_entries( stale_branches: stale_branches, active_branch: active_branch, cwd_branch: cwd_branch, counters: counters, branches: branches )

				orphan_branches = orphan_local_branches( active_branch: active_branch, cwd_branch: cwd_branch )
				prune_orphan_branch_entries( orphan_branches: orphan_branches, counters: counters, branches: branches )

				absorbed_branches = absorbed_local_branches( active_branch: active_branch, cwd_branch: cwd_branch )
				prune_absorbed_branch_entries( absorbed_branches: absorbed_branches, counters: counters, branches: branches )

				prune_finish(
					result: { command: "prune", status: "ok", branches: branches, deleted: counters.fetch( :deleted ), skipped: counters.fetch( :skipped ) },
					exit_code: EXIT_OK, json_output: json_output, counters: counters
				)
			end

		private

			# Unified output for prune results — JSON or human-readable.
			def prune_finish( result:, exit_code:, json_output:, counters: )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_prune_human( counters: counters )
				end

				exit_code
			end

			# Human-readable output for prune results.
			def print_prune_human( counters: )
				deleted_count = counters.fetch( :deleted )
				skipped_count = counters.fetch( :skipped )

				if deleted_count.zero? && skipped_count.zero?
					if verbose?
						puts_line "OK: no stale or orphan branches to prune."
					else
						puts_line "No stale branches."
					end
					return
				end

				puts_verbose "prune_summary: deleted=#{deleted_count} skipped=#{skipped_count}"
				unless verbose?
					message = if deleted_count > 0 && skipped_count > 0
						"Pruned #{deleted_count}, skipped #{skipped_count} (--verbose for details)."
					elsif deleted_count > 0
						"Pruned #{deleted_count} stale #{ deleted_count == 1 ? 'branch' : 'branches' }."
					else
						"Skipped #{skipped_count} #{ skipped_count == 1 ? 'branch' : 'branches' } (--verbose for details)."
					end
					puts_line message
				end
			end

			# Runs a git command, suppressing stdout in JSON mode to keep output clean.
			def prune_git!( *args, json_output: false )
				if json_output
					_, stderr_text, success, = git_run( *args )
					raise "git #{args.join( ' ' )} failed: #{stderr_text.to_s.strip}" unless success
				else
					git_system!( *args )
				end
			end

			def prune_stale_branch_entries( stale_branches:, active_branch:, cwd_branch: nil, counters: { deleted: 0, skipped: 0 }, branches: [] )
				stale_branches.each do |entry|
					result = prune_stale_branch_entry( entry: entry, active_branch: active_branch, cwd_branch: cwd_branch )
					counters[ result.fetch( :action ) ] += 1
					branches << result
				end
				counters
			end

			def prune_stale_branch_entry( entry:, active_branch:, cwd_branch: nil )
				branch = entry.fetch( :branch )
				upstream = entry.fetch( :upstream )
				return prune_skip_stale_branch( type: :protected, branch: branch, upstream: upstream ) if config.protected_branches.include?( branch )
				return prune_skip_stale_branch( type: :current, branch: branch, upstream: upstream ) if branch == active_branch
				return prune_skip_stale_branch( type: :cwd_worktree, branch: branch, upstream: upstream ) if cwd_branch && branch == cwd_branch

				prune_delete_stale_branch( branch: branch, upstream: upstream )
			end

			def prune_skip_stale_branch( type:, branch:, upstream: )
				reason = { protected: "protected branch", current: "current branch", cwd_worktree: "checked output in CWD worktree" }.fetch( type, type.to_s )
				status = { protected: "skip_protected_branch", current: "skip_current_branch", cwd_worktree: "skip_cwd_worktree_branch" }.fetch( type, "skip_#{type}" )
				puts_verbose "#{status}: #{branch} (upstream=#{upstream})"
				{ action: :skipped, branch: branch, upstream: upstream, type: "stale", reason: reason }
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
				output.print stdout_text if verbose? && !stdout_text.empty?
				puts_verbose "deleted_local_branch: #{branch} (upstream=#{upstream})"
				{ action: :deleted, branch: branch, upstream: upstream, type: "stale", reason: "upstream gone" }
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
				output.print force_stdout if verbose? && !force_stdout.empty?
				puts_verbose "deleted_local_branch_force: #{branch} (upstream=#{upstream}) merged_pr=#{merged_pr.fetch( :url )}"
				{ action: :deleted, branch: branch, upstream: upstream, type: "stale", reason: "force deleted with PR evidence" }
			end

			def prune_force_delete_failed( branch:, upstream:, force_stderr: )
				force_error_text = normalise_branch_delete_error( error_text: force_stderr )
				puts_verbose "fail_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error_text}"
				{ action: :skipped, branch: branch, upstream: upstream, type: "stale", reason: force_error_text }
			end

			def prune_force_delete_skipped( branch:, upstream:, delete_error_text:, force_error: )
				puts_verbose "skip_delete_branch: #{branch} (upstream=#{upstream}) reason=#{delete_error_text}"
				puts_verbose "skip_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error}" unless force_error.to_s.strip.empty?
				{ action: :skipped, branch: branch, upstream: upstream, type: "stale", reason: delete_error_text }
			end

			def normalise_branch_delete_error( error_text: )
				text = error_text.to_s.strip
				text.empty? ? "unknown error" : text
			end

			# Attempts git branch -D. If blocked by a worktree, skips with a diagnostic —
			# prune never removes worktrees because another session may own them.
			def force_delete_local_branch( branch: )
				stdout, stderr, success, = git_run( "branch", "-D", branch )
				return [ stdout, stderr, success ] if success

				if worktree_blocked_error?( error_text: stderr )
					wt_path = worktree_path_for_branch( branch: branch )
					hint = wt_path ? "run: carson worktree remove #{File.basename( wt_path )}" : "remove the worktree first"
					puts_verbose "skip_worktree_blocked: #{branch} (#{hint})"
				end

				[ stdout, stderr, false ]
			end

			def worktree_blocked_error?( error_text: )
				error_text.to_s.downcase.include?( "used by worktree" )
			end

			# Returns the worktree path for a branch, or nil if not checked output in any worktree.
			def worktree_path_for_branch( branch: )
				entry = worktree_list.find { |worktree| worktree.branch == branch }
				entry&.path
			end

			# Detects local branches whose upstream tracking is marked [gone] after fetch --prune.
			def stale_local_branches
				Branch.stale( remote_name: config.git_remote, runtime: self ).map do |branch|
					upstream = git_capture!( "for-each-ref", "--format=%(upstream:short)\t%(upstream:track)", "refs/heads/#{branch.name}" ).strip
					upstream_name, track = upstream.split( "\t", 2 )
					{ branch: branch.name, upstream: upstream_name.to_s, track: track.to_s }
				end
			end

			# Detects local branches with no upstream tracking ref — candidates for orphan pruning.
			def orphan_local_branches( active_branch:, cwd_branch: nil )
				Branch.orphaned(
					active_branch: active_branch, cwd_branch: cwd_branch,
					protected_branches: config.protected_branches, runtime: self
				).reject { it.name == TEMPLATE_SYNC_BRANCH }
				 .map( &:name )
			end

			# Detects local branches whose upstream still exists but whose content is already on main.
			# Two-step evidence: (1) find the merge-base, (2) verify every file the branch changed
			# relative to the merge-base has identical content on main.
			def absorbed_local_branches( active_branch:, cwd_branch: nil )
				Branch.absorbed(
					active_branch: active_branch, cwd_branch: cwd_branch,
					protected_branches: config.protected_branches, main_branch: config.main_branch, runtime: self
				).reject { it.name == TEMPLATE_SYNC_BRANCH }
				 .map do |branch|
					upstream = git_capture!( "for-each-ref", "--format=%(upstream:short)", "refs/heads/#{branch.name}" ).strip
					{ branch: branch.name, upstream: upstream }
				end
			end

			# Returns true when the branch has no unique content relative to main.
			def branch_absorbed_into_main?( branch: )
				Branch.absorbed_into_main?( branch: branch, main_branch: config.main_branch, runtime: self )
			end

			# Processes absorbed branches: verifies no open PR exists before deleting local and remote.
			def prune_absorbed_branch_entries( absorbed_branches:, counters:, branches: [] )
				return counters if absorbed_branches.empty?
				return counters unless gh_available?

				absorbed_branches.each do |entry|
					result = prune_absorbed_branch_entry( branch: entry.fetch( :branch ), upstream: entry.fetch( :upstream ) )
					counters[ result.fetch( :action ) ] += 1
					branches << result
				end
				counters
			end

			# Checks a single absorbed branch for open PRs and deletes local + remote if safe.
			def prune_absorbed_branch_entry( branch:, upstream: )
				if branch_has_open_pr?( branch: branch )
					puts_verbose "skip_absorbed_branch: #{branch} reason=open PR exists"
					return { action: :skipped, branch: branch, upstream: upstream, type: "absorbed", reason: "open PR exists" }
				end

				force_stdout, force_stderr, force_success = force_delete_local_branch( branch: branch )
				unless force_success
					error_text = normalise_branch_delete_error( error_text: force_stderr )
					puts_verbose "fail_delete_absorbed_branch: #{branch} reason=#{error_text}"
					return { action: :skipped, branch: branch, upstream: upstream, type: "absorbed", reason: error_text }
				end

				output.print force_stdout if verbose? && !force_stdout.empty?

				remote_branch = upstream.sub( "#{config.git_remote}/", "" )
				git_run( "push", config.git_remote, "--delete", remote_branch )

				puts_verbose "deleted_absorbed_branch: #{branch} (upstream=#{upstream})"
				{ action: :deleted, branch: branch, upstream: upstream, type: "absorbed", reason: "content already on main" }
			end

			# Returns true if the branch has at least one open PR.
			def branch_has_open_pr?( branch: )
				remote_obj = Remote.new( name: config.git_remote, runtime: self )
				PullRequest.open_for_branch?( branch: branch, owner: remote_obj.owner, repo: remote_obj.repo, runtime: self )
			end

			# Processes orphan branches: verifies merged PR evidence via GitHub API before deleting.
			def prune_orphan_branch_entries( orphan_branches:, counters:, branches: [] )
				return counters if orphan_branches.empty?
				return counters unless gh_available?

				orphan_branches.each do |branch|
					result = prune_orphan_branch_entry( branch: branch )
					counters[ result.fetch( :action ) ] += 1
					branches << result
				end
				counters
			end

			# Checks a single orphan branch for merged PR evidence or absorbed content, then force-deletes if confirmed.
			def prune_orphan_branch_entry( branch: )
				tip_sha_text, tip_sha_error, tip_sha_success, = git_run( "rev-parse", "--verify", branch.to_s )
				unless tip_sha_success
					error_text = tip_sha_error.to_s.strip
					error_text = "unable to read local branch tip sha" if error_text.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=#{error_text}"
					return { action: :skipped, branch: branch, upstream: "", type: "orphan", reason: error_text }
				end
				branch_tip_sha = tip_sha_text.to_s.strip
				if branch_tip_sha.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=unable to read local branch tip sha"
					return { action: :skipped, branch: branch, upstream: "", type: "orphan", reason: "unable to read local branch tip sha" }
				end

				merged_pr, error = merged_pr_for_branch( branch: branch, branch_tip_sha: branch_tip_sha )

				# Fallback: branch content is already on main (rebase merges rewrite SHAs).
				if merged_pr.nil? && branch_absorbed_into_main?( branch: branch )
					merged_pr = {
						number: nil,
						url: "absorbed into #{config.main_branch}",
						merged_at: Time.now.utc.iso8601,
						head_sha: branch_tip_sha
					}
				end

				if merged_pr.nil?
					reason = error.to_s.strip
					reason = "no merged PR evidence for branch tip into #{config.main_branch}" if reason.empty?
					puts_verbose "skip_orphan_branch: #{branch} reason=#{reason}"
					return { action: :skipped, branch: branch, upstream: "", type: "orphan", reason: reason }
				end

				force_stdout, force_stderr, force_success = force_delete_local_branch( branch: branch )
				if force_success
					output.print force_stdout if verbose? && !force_stdout.empty?
					puts_verbose "deleted_orphan_branch: #{branch} merged_pr=#{merged_pr.fetch( :url )}"
					return { action: :deleted, branch: branch, upstream: "", type: "orphan", reason: "content absorbed into #{config.main_branch}" }
				end

				force_error_text = normalise_branch_delete_error( error_text: force_stderr )
				puts_verbose "fail_delete_orphan_branch: #{branch} reason=#{force_error_text}"
				{ action: :skipped, branch: branch, upstream: "", type: "orphan", reason: force_error_text }
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
				remote_obj = Remote.new( name: config.git_remote, runtime: self )
				pr = PullRequest.merged_for_branch(
					branch: branch, branch_tip_sha: branch_tip_sha,
					owner: remote_obj.owner, repo: remote_obj.repo,
					main_branch: config.main_branch, runtime: self
				)
				if pr
					[ { number: pr.number, url: pr.url, merged_at: nil, head_sha: branch_tip_sha }, nil ]
				else
					[ nil, "no merged PR evidence for branch tip #{branch_tip_sha} into #{config.main_branch}" ]
				end
			rescue StandardError => e
				[ nil, e.message ]
			end
		end
	end
end
