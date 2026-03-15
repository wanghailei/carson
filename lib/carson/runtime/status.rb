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

			# Portfolio-wide status overview across all governed repositories.
			def status_all!( json_output: false )
				repositories = config.govern_repos
				if repositories.empty?
					puts_line "No governed repositories configured."
					puts_line "  Run carson onboard in each repo to register."
					return EXIT_ERROR
				end

				results = repositories.map do |repo_path|
					repo_name = File.basename( repo_path )
					unless Dir.exist?( repo_path )
						{ name: repo_name, status: "error", error: "not found" }
					else
						begin
							scoped_runtime = build_scoped_runtime( repo_path: repo_path )
							{ name: repo_name, status: "ok" }.merge( scoped_runtime.send( :gather_status ) )
						rescue StandardError => exception
							{ name: repo_name, status: "error", error: exception.message }
						end
					end
				end

				if json_output
					output.puts JSON.pretty_generate( { command: "status", repos: results, repositories: results } )
				else
					puts_line "Carson #{Carson::VERSION} — Portfolio (#{repositories.length} repo#{plural_suffix( count: repositories.length )})"
					puts_line ""
					results.each { |result| print_portfolio_status( result: result ) }
				end

				EXIT_OK
			end

		private

			def gather_status
				repository = repository_record
				branch = branch_record
				deliveries = ledger.active_deliveries( repo_path: repository.path )

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
						sync: remote_sync_status( branch: branch.name )
					},
					worktrees: gather_worktree_summary,
					branches: deliveries.map { |delivery| status_branch_entry( delivery: delivery ) },
					stale_branches: gather_stale_branch_info
				}
			end

			def status_branch_entry( delivery: )
				{
					branch: delivery.branch,
					worktree_path: delivery.worktree_path,
					head: delivery.head,
					pr_number: delivery.pull_request_number,
					delivery_state: delivery.status,
					revision_count: delivery.revision_count,
					summary: delivery.summary,
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
				realpath_safe( repo_root ) == realpath_safe( main_worktree_root )
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

				deliveries = data.fetch( :branches )
				if deliveries.empty?
					puts_line "No active deliveries."
					return
				end

				count = deliveries.length
				puts_line "#{count} active deliver#{count == 1 ? 'y' : 'ies'}:"
				deliveries.each do |delivery|
					pr_number = delivery.fetch( :pr_number )
					pr_ref = pr_number ? " (PR ##{pr_number})" : ""
					puts_line "  #{delivery.fetch( :branch )}#{pr_ref} — #{delivery.fetch( :delivery_state )}"
					puts_line "  #{delivery.fetch( :summary )}." unless delivery.fetch( :summary ).to_s.empty?
				end
			end

			def print_portfolio_status( result: )
				if result.fetch( :status ) == "error"
					puts_line "#{result.fetch( :name )}: #{result.fetch( :error )}"
					return
				end

				deliveries = Array( result.fetch( :branches, [] ) )
				counts = deliveries.each_with_object( Hash.new( 0 ) ) { |delivery, memo| memo[ delivery.fetch( :delivery_state ) ] += 1 }
				summary = if counts.empty?
					"no active deliveries"
				else
					counts.map { |state, count| "#{count} #{state}" }.join( ", " )
				end
				puts_line "#{result.fetch( :name )} — #{summary}"
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
		end

		include Status
	end
end
