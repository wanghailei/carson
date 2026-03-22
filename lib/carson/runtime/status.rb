# Agent-readable repository status centred on branch deliveries.
module Carson
	class Runtime
		module Status
			# Entry point for `carson status`.
			def status!( json_output: false )
				data = gather_status

				if json_output
					output.puts JSON.pretty_generate( data )
				else
					print_status( data: data )
				end

				EXIT_OK
			end

		private

			def gather_status
				repository = repository_record
				branch = branch_record
				tracked_delivery = status_branch_delivery( branch_name: branch.name )
				deliveries = ledger.active_deliveries( repo_path: repository.path )
				next_delivery_key = deliveries.find( &:ready? )&.key

				{
					version: Carson::VERSION,
					repository: {
						name: repository.name,
						path: repository.path
					},
					branch: {
						name: branch.name,
						head: branch.head,
						worktree: branch.worktree,
						dirty: working_tree_dirty?,
						dirty_reason: dirty_worktree_reason,
						sync: remote_sync_status( branch: branch.name ),
						pull_request: status_branch_pull_request( delivery: tracked_delivery ),
						merge_proof: status_branch_merge_proof( branch_name: branch.name, delivery: tracked_delivery )
					},
					worktrees: gather_worktree_summary,
					branches: deliveries.map { |delivery| status_branch_entry( delivery: delivery, next_to_integrate: delivery.key == next_delivery_key ) },
					stale_branches: gather_stale_branch_info
				}
			end

			def status_branch_entry( delivery:, next_to_integrate: )
				{
					branch: delivery.branch,
					worktree_path: delivery.worktree_path,
					head: delivery.head,
					pr_number: delivery.pull_request_number,
					delivery_state: delivery.status,
					revision_count: delivery.revision_count,
					summary: delivery.summary,
					next_to_integrate: next_to_integrate,
					updated_at: delivery.updated_at
				}
			end

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
				realpath_safe( work_dir ) == realpath_safe( main_worktree_root )
			end

			def remote_sync_status( branch: )
				remote = config.git_remote
				remote_ref = "#{remote}/#{branch}"
				_, _, exists, = git_run( "rev-parse", "--verify", remote_ref )
				return :no_remote unless exists

				ahead_behind, _, success, = git_run( "rev-list", "--left-right", "--count", "#{branch}...#{remote_ref}" )
				return :unknown unless success

				ahead, behind = ahead_behind.strip.split.map( &:to_i )
				return :in_sync if ahead.zero? && behind.zero?
				return :ahead if behind.zero?
				return :behind if ahead.zero?
				:diverged
			end

			def gather_stale_branch_info
				stdout, _, success, = git_run( "branch", "-vv" )
				return { count: 0 } unless success

				gone_branches = stdout.lines.select { |line| line.include?( ": gone]" ) }
				{ count: gone_branches.size }
			end

			def gather_worktree_summary
				all = worktree_list
				main_root = main_worktree_root
				non_main = all.reject { |worktree| worktree.path == main_root }
				{ count: all.count, non_main_count: non_main.count }
			end

			def print_status( data: )
				repo_name = data.dig( :repository, :name )
				puts_line "Carson #{data.fetch( :version )} — #{repo_name}"

				branch = data.fetch( :branch )
				branch_line = "On #{branch.fetch( :name )}"
				branch_line += " (uncommitted changes)" if branch.fetch( :dirty )
				branch_line += ", #{format_sync( sync: branch.fetch( :sync ) )}."
				puts_line branch_line
				worktree_summary = data.fetch( :worktrees )
				puts_line "Worktrees: #{worktree_summary.fetch( :non_main_count )} tracked outside main — run carson worktree list." if worktree_summary.fetch( :non_main_count ).positive?
				if (pull_request = branch[ :pull_request ])
					puts_line pull_request.fetch( :summary )
				end
				if branch.fetch( :name ) != config.main_branch && (merge_proof = branch[ :merge_proof ])
					puts_line "Merge proof: #{merge_proof.fetch( :summary )}"
				end

				deliveries = data.fetch( :branches )
				if deliveries.empty?
					puts_line "No active deliveries."
					return
				end

				count = deliveries.length
				puts_line "#{count} active deliver#{count == 1 ? 'y' : 'ies'}:"
				if (next_delivery = deliveries.find { |delivery| delivery.fetch( :next_to_integrate, false ) })
					pr_number = next_delivery.fetch( :pr_number )
					pr_ref = pr_number ? " (PR ##{pr_number})" : ""
					puts_line "Next delivery: #{next_delivery.fetch( :branch )}#{pr_ref}."
				end
				deliveries.each do |delivery|
					pr_number = delivery.fetch( :pr_number )
					pr_ref = pr_number ? " (PR ##{pr_number})" : ""
					puts_line "  #{delivery.fetch( :branch )}#{pr_ref} — #{delivery.fetch( :delivery_state )}"
					puts_line "  #{delivery.fetch( :summary )}." unless delivery.fetch( :summary ).to_s.empty?
				end
			end

			def format_sync( sync: )
				case sync
				when :in_sync then "in sync with remote"
				when :ahead then "ahead of remote"
				when :behind then "behind remote"
				when :diverged then "diverged from remote"
				when :no_remote then "no remote tracking"
				else "sync unknown"
				end
			end

			def status_branch_delivery( branch_name: )
				return nil if branch_name == config.main_branch

				ledger.latest_delivery(
					repo_path: repository_record.path,
					branch_name: branch_name
				)
			end

			def status_branch_pull_request( delivery: )
				return nil unless delivery

				pull_request_payload( delivery: delivery )
			end

			def status_branch_merge_proof( branch_name:, delivery: )
				return merge_proof_payload( proof: merge_proof_for_branch( branch: branch_name ) ) if branch_name == config.main_branch
				return nil unless delivery

				return merge_proof_payload( proof: delivery.merge_proof ) if delivery.merge_proof

				merge_proof_payload( proof: merge_proof_for_branch( branch: branch_name ) )
			end
		end

		include Status
	end
end
