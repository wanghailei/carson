# Agent session briefing — one command to know the full state of the estate.
# Gathers branch, working tree, worktrees, open PRs, stale branches,
# governance health, and version. Supports human-readable and JSON output.
module Carson
	class Runtime
		module Status
			# Entry point for `carson status`. Collects estate state and reports.
			def status!( json_output: false )
				data = gather_status

				if json_output
					out.puts JSON.pretty_generate( data )
				else
					print_status( data: data )
				end

				EXIT_OK
			end

		private

			# Collects all status facets into a structured hash.
			def gather_status
				data = {
					version: Carson::VERSION,
					branch: gather_branch_info,
					worktrees: gather_worktree_info,
					governance: gather_governance_info
				}

				# PR and stale branch data require gh — gather with graceful fallback.
				if gh_available?
					data[ :pull_requests ] = gather_pr_info
					data[ :stale_branches ] = gather_stale_branch_info
				end

				data
			end

			# Branch name, clean/dirty state, sync status with remote.
			def gather_branch_info
				branch = current_branch
				dirty = working_tree_dirty?
				sync = remote_sync_status( branch: branch )

				{ name: branch, dirty: dirty, sync: sync }
			end

			# Returns true when the working tree has uncommitted changes.
			def working_tree_dirty?
				stdout, _, success, = git_run( "status", "--porcelain" )
				return true unless success
				!stdout.strip.empty?
			end

			# Compares local branch against its remote tracking ref.
			# Returns :in_sync, :ahead, :behind, :diverged, or :no_remote.
			def remote_sync_status( branch: )
				remote = config.git_remote
				remote_ref = "#{remote}/#{branch}"

				# Check if the remote ref exists.
				_, _, exists, = git_run( "rev-parse", "--verify", remote_ref )
				return :no_remote unless exists

				ahead_behind, _, success, = git_run( "rev-list", "--left-right", "--count", "#{branch}...#{remote_ref}" )
				return :unknown unless success

				parts = ahead_behind.strip.split( /\s+/ )
				ahead = parts[ 0 ].to_i
				behind = parts[ 1 ].to_i

				if ahead.zero? && behind.zero?
					:in_sync
				elsif ahead.positive? && behind.zero?
					:ahead
				elsif ahead.zero? && behind.positive?
					:behind
				else
					:diverged
				end
			end

			# Lists all worktrees with branch, lifecycle state, and session ownership.
			def gather_worktree_info
				entries = worktree_list
				sessions = session_list
				ownership = build_worktree_ownership( sessions: sessions )

				# Filter out the main worktree (the repository root itself).
				entries.reject { |wt| wt.fetch( :path ) == repo_root }.map do |wt|
					name = File.basename( wt.fetch( :path ) )
					info = {
						path: wt.fetch( :path ),
						name: name,
						branch: wt.fetch( :branch, nil )
					}
					owner = ownership[ name ]
					if owner
						info[ :owner ] = owner[ :session_id ]
						info[ :owner_pid ] = owner[ :pid ]
						info[ :owner_task ] = owner[ :task ]
						info[ :stale ] = owner[ :stale ]
					end
					info
				end
			end

			# Builds a name-to-session mapping for worktree ownership.
			def build_worktree_ownership( sessions: )
				result = {}
				sessions.each do |session|
					wt = session[ :worktree ]
					next unless wt
					name = wt[ :name ] || wt[ "name" ]
					next unless name
					result[ name ] = {
						session_id: session[ :session_id ] || session[ "session_id" ],
						pid: session[ :pid ] || session[ "pid" ],
						task: session[ :task ] || session[ "task" ],
						stale: session[ :stale ]
					}
				end
				result
			end

			# Queries open PRs via gh.
			def gather_pr_info
				stdout, _, success, = gh_run(
					"pr", "list", "--state", "open",
					"--json", "number,title,headRefName,statusCheckRollup,reviewDecision"
				)
				return [] unless success

				prs = JSON.parse( stdout ) rescue []
				prs.map do |pr|
					ci = summarise_checks( rollup: pr[ "statusCheckRollup" ] )
					review = pr[ "reviewDecision" ].to_s
					review_label = review_decision_label( decision: review )

					{
						number: pr[ "number" ],
						title: pr[ "title" ],
						branch: pr[ "headRefName" ],
						ci: ci,
						review: review_label
					}
				end
			end

			# Summarises check rollup into a single status word.
			def summarise_checks( rollup: )
				entries = Array( rollup )
				return :none if entries.empty?

				states = entries.map { |c| c[ "conclusion" ].to_s.upcase }
				return :fail if states.any? { |s| s == "FAILURE" || s == "CANCELLED" || s == "TIMED_OUT" }
				return :pending if states.any? { |s| s == "" || s == "PENDING" || s == "QUEUED" || s == "IN_PROGRESS" }

				:pass
			end

			# Translates GitHub review decision to a concise label.
			def review_decision_label( decision: )
				case decision.upcase
				when "APPROVED" then :approved
				when "CHANGES_REQUESTED" then :changes_requested
				when "REVIEW_REQUIRED" then :review_required
				else :none
				end
			end

			# Counts local branches that are stale (tracking a deleted upstream).
			def gather_stale_branch_info
				stdout, _, success, = git_run( "branch", "-vv" )
				return { count: 0 } unless success

				gone_branches = stdout.lines.select { |l| l.include?( ": gone]" ) }
				{ count: gone_branches.size }
			end

			# Quick governance health check: are templates in sync?
			def gather_governance_info
				result = with_captured_output { template_check! }
				{
					templates: result == EXIT_OK ? :in_sync : :drifted
				}
			rescue StandardError
				{ templates: :unknown }
			end

			# Prints the human-readable status report.
			def print_status( data: )
				puts_line "Carson #{data.fetch( :version )}"
				puts_line ""

				# Branch
				branch = data.fetch( :branch )
				dirty_marker = branch.fetch( :dirty ) ? " (dirty)" : ""
				sync_marker = format_sync( sync: branch.fetch( :sync ) )
				puts_line "Branch: #{branch.fetch( :name )}#{dirty_marker}#{sync_marker}"

				# Worktrees
				worktrees = data.fetch( :worktrees )
				if worktrees.any?
					puts_line ""
					puts_line "Worktrees:"
					worktrees.each do |wt|
						branch_label = wt.fetch( :branch ) || "(detached)"
						owner_label = format_worktree_owner( worktree: wt )
						puts_line "  #{wt.fetch( :name )}  #{branch_label}#{owner_label}"
					end
				end

				# Pull requests
				prs = data.fetch( :pull_requests, nil )
				if prs && prs.any?
					puts_line ""
					puts_line "Pull requests:"
					prs.each do |pr|
						ci_label = pr.fetch( :ci ).to_s
						review_label = pr.fetch( :review ).to_s.tr( "_", " " )
						puts_line "  ##{pr.fetch( :number )}  #{pr.fetch( :title )}"
						puts_line "        CI: #{ci_label}  Review: #{review_label}"
					end
				end

				# Stale branches
				stale = data.fetch( :stale_branches, nil )
				if stale && stale.fetch( :count ) > 0
					count = stale.fetch( :count )
					puts_line ""
					puts_line "#{count} stale branch#{plural_suffix( count: count )} ready for pruning."
				end

				# Governance
				gov = data.fetch( :governance )
				templates = gov.fetch( :templates )
				unless templates == :in_sync
					puts_line ""
					puts_line "Templates: #{templates} — run `carson sync` to fix."
				end
			end

			# Formats owner annotation for a worktree entry.
			def format_worktree_owner( worktree: )
				owner = worktree[ :owner ]
				return "" unless owner

				stale = worktree[ :stale ]
				task = worktree[ :owner_task ]
				pid = worktree[ :owner_pid ]

				if stale
					"  (stale session #{pid})"
				elsif task
					"  (#{task})"
				else
					"  (session #{pid})"
				end
			end

			# Formats sync status for display.
			def format_sync( sync: )
				case sync
				when :in_sync then ""
				when :ahead then " (ahead of remote)"
				when :behind then " (behind remote)"
				when :diverged then " (diverged from remote)"
				when :no_remote then " (no remote tracking)"
				else ""
				end
			end
		end

		include Status
	end
end
