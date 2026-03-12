# Agent briefing — one command to know the full state of the estate.
# Gathers branch, worktrees, open PRs, stale branches,
# governance health, and version. Supports human-readable and JSON output.
module Carson
	class Runtime
		module Status
			# Entry point for `carson status`. Collects estate state and reports.
			def status!( json_output: false )
				data = gather_status

				if json_output
					output.puts JSON.pretty_generate( data )
				else
					print_status( data: data )
				end

				EXIT_OK
			end

			# Portfolio-wide status overview across all governed repositories.
			def status_all!( json_output: false )
				repos = config.govern_repos
				if repos.empty?
					puts_line "No governed repositories configured."
					puts_line "  Run carson onboard in each repo to register."
					return EXIT_ERROR
				end

				if json_output
					results = []
					repos.each do |repo_path|
						repo_name = File.basename( repo_path )
						unless Dir.exist?( repo_path )
							results << { name: repo_name, status: "error", error: "path not found" }
							next
						end
						begin
							scoped_runtime = build_scoped_runtime( repo_path: repo_path )
							data = scoped_runtime.send( :gather_status )
							results << { name: repo_name, status: "ok" }.merge( data )
						rescue StandardError => exception
							results << { name: repo_name, status: "error", error: exception.message }
						end
					end
					output.puts JSON.pretty_generate( { command: "status", repos: results } )
					return EXIT_OK
				end

				puts_line "Carson #{Carson::VERSION} — Portfolio (#{repos.length} repo#{plural_suffix( count: repos.length )})"
				puts_line ""

				all_pending = load_batch_pending
				repos.each do |repo_path|
					repo_name = File.basename( repo_path )
					unless Dir.exist?( repo_path )
						puts_line "#{repo_name}: not found"
						next
					end

					begin
						scoped_runtime = build_scoped_runtime( repo_path: repo_path )
						data = scoped_runtime.send( :gather_status )
						branch = data.fetch( :branch )
						dirty = format_dirty_marker( branch: branch )
						worktrees = data.fetch( :worktrees )
						gov = data.fetch( :governance )
						parts = []
						parts << branch.fetch( :name ) + dirty
						parts << "#{worktrees.count} worktree#{plural_suffix( count: worktrees.count )}" if worktrees.any?
						parts << "templates #{gov.fetch( :templates )}" unless gov.fetch( :templates ) == :in_sync
						puts_line "#{repo_name}: #{parts.join( '  ' )}"

						# Show pending operations for this repo.
						repo_pending = status_pending_for_repo( all_pending: all_pending, repo_path: repo_path )
						repo_pending.each { |description| puts_line "  pending: #{description}" }
					rescue StandardError => exception
						puts_line "#{repo_name}: could not read (#{exception.message})"
					end
				end

				EXIT_OK
			end

		private

			# Returns an array of human-readable pending descriptions for a repo.
			def status_pending_for_repo( all_pending:, repo_path: )
				descriptions = []
				all_pending.each do |command, repos|
					next unless repos.is_a?( Hash ) && repos.key?( repo_path )

					info = repos[ repo_path ]
					attempts = info.fetch( "attempts", 0 )
					skipped_at = info.fetch( "skipped_at", nil )
					time_part = skipped_at ? ", since #{skipped_at[ 11..15 ]}" : ""
					descriptions << "#{command} (#{attempts} attempt#{attempts == 1 ? '' : 's'}#{time_part})"
				end
				descriptions
			end

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
				dirty_reason = dirty_worktree_reason
				sync = remote_sync_status( branch: branch )

				{ name: branch, dirty: !dirty_reason.nil?, dirty_reason: dirty_reason, sync: sync }
			end

			# Returns true when the working tree has uncommitted changes.
			def working_tree_dirty?
				stdout, _, success, = git_run( "status", "--porcelain" )
				return true unless success
				!stdout.strip.empty?
			end

			def dirty_worktree_reason
				return nil unless working_tree_dirty?
				return "main_worktree" if main_worktree_context?

				"working_tree"
			end

			def main_worktree_context?
				realpath_safe( repo_root ) == realpath_safe( main_worktree_root )
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

				return :in_sync if ahead.zero? && behind.zero?
				return :ahead if behind.zero?
				return :behind if ahead.zero?
				:diverged
			end

			# Lists all worktrees with branch name.
			def gather_worktree_info
				entries = worktree_list

				# Filter output the main worktree (the repository root itself).
				# Use realpath for comparison — git returns canonical paths that may differ from repo_root.
				canonical_root = realpath_safe( repo_root )
				entries.reject { it.path == canonical_root }.map do |worktree|
					{
						path: worktree.path,
						name: File.basename( worktree.path ),
						branch: worktree.branch
					}
				end
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

				states = entries.map { it[ "conclusion" ].to_s.upcase }
				return :fail if states.any? { it == "FAILURE" || it == "CANCELLED" || it == "TIMED_OUT" }
				return :pending if states.any? { it == "" || it == "PENDING" || it == "QUEUED" || it == "IN_PROGRESS" }

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

				gone_branches = stdout.lines.select { |line| line.include?( ": gone]" ) }
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
				dirty_marker = format_dirty_marker( branch: branch )
				sync_marker = format_sync( sync: branch.fetch( :sync ) )
				puts_line "Branch: #{branch.fetch( :name )}#{dirty_marker}#{sync_marker}"
				if branch.fetch( :dirty_reason, nil ) == "main_worktree"
					puts_line "Governance: main working tree has uncommitted changes — create a worktree with `carson worktree create <name>`."
				end

				# Worktrees
				worktrees = data.fetch( :worktrees )
				if worktrees.any?
					puts_line ""
					puts_line "Worktrees:"
					worktrees.each do |worktree|
						branch_label = worktree.fetch( :branch ) || "(detached)"
						puts_line "  #{worktree.fetch( :name )}  #{branch_label}"
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
					puts_line "#{count} stale #{ count == 1 ? 'branch' : 'branches' } ready for pruning."
				end

				# Governance
				gov = data.fetch( :governance )
				templates = gov.fetch( :templates )
				unless templates == :in_sync
					puts_line ""
					puts_line "Templates: #{templates} — run `carson sync` to fix."
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

			def format_dirty_marker( branch: )
				return "" unless branch.fetch( :dirty )
				return " (dirty main worktree)" if branch.fetch( :dirty_reason, nil ) == "main_worktree"

				" (dirty)"
			end
			end

			include Status
	end
end
