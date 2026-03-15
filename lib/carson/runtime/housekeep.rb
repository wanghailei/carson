# Housekeeping — sync, reap dead worktrees, and prune for a repository.
# carson housekeep <repo>  — serve one repo by name or path.
# carson housekeep         — serve the repo you are standing in.
# carson housekeep --all   — serve all governed repos.
require "json"
require "open3"
require "stringio"

module Carson
	class Runtime
		module Housekeep
			# Serves the current repo: sync + prune.
			# Resolves to the canonical main worktree root so the command works
			# correctly when invoked from inside an agent worktree.
			def housekeep!( json_output: false, dry_run: false )
				canonical = main_worktree_root

				if dry_run
					scoped = Runtime.new( repo_root: canonical, tool_root: tool_root, output: output, error: error, verbose: verbose? )
					return scoped.housekeep_one_dry_run
				end

				housekeep_one( repo_path: canonical, json_output: json_output )
			end

			# Resolves a target name to a governed repo, then serves it.
			def housekeep_target!( target:, json_output: false, dry_run: false )
				repo_path = resolve_governed_repo( target: target )
				unless repo_path
					result = { command: "housekeep", status: "error", error: "Not a governed repository: #{target}", recovery: "Run carson repos to see governed repositories." }
					return housekeep_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				if dry_run
					scoped = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: output, error: error, verbose: verbose? )
					return scoped.housekeep_one_dry_run
				end

				housekeep_one( repo_path: repo_path, json_output: json_output )
			end

			# Knocks each governed repo's gate in turn.
			def housekeep_all!( json_output: false, dry_run: false )
				repos = config.govern_repos
				if repos.empty?
					result = { command: "housekeep", status: "error", error: "No governed repositories configured.", recovery: "Run carson onboard in each repo to register." }
					return housekeep_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				if dry_run
					repos.each_with_index do |repo_path, idx|
						puts_line "" if idx > 0
						unless Dir.exist?( repo_path )
							puts_line "#{File.basename( repo_path )}: SKIP (path not found)"
							next
						end
						scoped = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: output, error: error, verbose: verbose? )
						scoped.housekeep_one_dry_run
					end
					total = repos.size
					puts_line ""
					puts_line "#{total} repo#{plural_suffix( count: total )} surveyed. Run without --dry-run to apply."
					return EXIT_OK
				end

				results = []
				repos.each do |repo_path|
					entry = housekeep_one_entry( repo_path: repo_path, silent: json_output )
					if entry[ :status ] == "ok"
						clear_batch_success( command: "housekeep", repo_path: repo_path )
					else
						record_batch_skip( command: "housekeep", repo_path: repo_path, reason: entry[ :error ] || "housekeep failed" )
					end
					results << entry
				end

				succeeded = results.count { |entry| entry[ :status ] == "ok" }
				failed = results.count { |entry| entry[ :status ] != "ok" }
				result = { command: "housekeep", status: failed.zero? ? "ok" : "partial", repos: results, succeeded: succeeded, failed: failed }
				housekeep_finish( result: result, exit_code: failed.zero? ? EXIT_OK : EXIT_ERROR, json_output: json_output, results: results, succeeded: succeeded, failed: failed )
			end

			# Prints a dry-run plan for this repo without making any changes.
			# Calls reap_dead_worktrees_plan and prune_plan on self (already scoped to the repo).
			def housekeep_one_dry_run
				repo_name = File.basename( repo_root )
				worktree_plan = reap_dead_worktrees_plan
				branch_plan = prune_plan( dry_run: true )
				print_housekeep_dry_run( repo_name: repo_name, worktree_plan: worktree_plan, branch_plan: branch_plan )
				EXIT_OK
			end

			# Returns a plan array describing what reap_dead_worktrees! would do for each
			# non-main worktree, without executing any mutations.
			# Each item: { name:, branch:, action: :reap|:skip, reason: }
			def reap_dead_worktrees_plan
				worktree_list.filter_map do |worktree|
					next if worktree.path == main_worktree_root

					classification = classify_worktree_cleanup( worktree: worktree )
					{
						name: File.basename( worktree.path ),
						branch: worktree.branch,
						action: classification.fetch( :action ),
						reason: classification.fetch( :reason )
					}
				end
			end

			def reap_dead_worktrees!
				worktree_list.each do |worktree|
					next if worktree.path == main_worktree_root

					classification = classify_worktree_cleanup( worktree: worktree )
					if classification.fetch( :action ) == :skip
						puts_line "Kept worktree: #{worktree_housekeep_label( worktree: worktree )} — #{classification.fetch( :reason )}" unless verbose?
						next
					end

					reap_one_worktree!( worktree: worktree, reason: classification.fetch( :reason ) )
				end
			end

		private

			# Runs sync + prune on one repo and returns the exit code directly.
			def housekeep_one( repo_path:, json_output: false )
				entry = housekeep_one_entry( repo_path: repo_path, silent: json_output )
				ok = entry[ :status ] == "ok"
				result = { command: "housekeep", status: ok ? "ok" : "error", repos: [ entry ], succeeded: ok ? 1 : 0, failed: ok ? 0 : 1 }
				housekeep_finish( result: result, exit_code: ok ? EXIT_OK : EXIT_ERROR, json_output: json_output, results: [ entry ], succeeded: result[ :succeeded ], failed: result[ :failed ] )
			end

			# Runs sync + prune on a single repository. Returns a result hash.
			def housekeep_one_entry( repo_path:, silent: false )
				repo_name = File.basename( repo_path )
				unless Dir.exist?( repo_path )
					puts_line "#{repo_name}: SKIP (path not found)" unless silent
					return { name: repo_name, path: repo_path, status: "error", error: "path not found" }
				end

				buffer = verbose? ? output : StringIO.new
				error_buffer = verbose? ? error : StringIO.new
				scoped_runtime = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: buffer, error: error_buffer, verbose: verbose? )

				sync_status = scoped_runtime.sync!
				if sync_status == EXIT_OK
					scoped_runtime.reap_dead_worktrees!
					prune_status = scoped_runtime.prune!
				end

				ok = sync_status == EXIT_OK && prune_status == EXIT_OK
				unless verbose? || silent
					puts_line "#{repo_name}:"
					output.print buffer.string
					puts_line "  OK" if buffer.string.to_s.strip.empty?
				end

				{ name: repo_name, path: repo_path, status: ok ? "ok" : "error" }
			rescue StandardError => exception
				puts_line "#{repo_name}: did not complete (#{exception.message})" unless silent
				{ name: repo_name, path: repo_path, status: "error", error: exception.message }
			end

			# Resolves a user-supplied target to a governed repository path.
			# Accepts: exact path, expandable path, or basename match (case-insensitive).
			def resolve_governed_repo( target: )
				repos = config.govern_repos
				expanded = File.expand_path( target )
				return expanded if repos.include?( expanded )

				downcased = File.basename( target ).downcase
				repos.find { |repo_path| File.basename( repo_path ).downcase == downcased }
			end

			# Unified output — JSON or human-readable.
			def housekeep_finish( result:, exit_code:, json_output:, results: nil, succeeded: nil, failed: nil )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					if results && ( succeeded || failed )
						total = ( succeeded || 0 ) + ( failed || 0 )
						puts_line ""
						puts_line "Housekeep complete: #{succeeded} cleaned, #{failed} failed (#{total} repo#{plural_suffix( count: total )})."
					elsif result[ :error ]
						puts_line result[ :error ]
						puts_line "  #{result[ :recovery ]}" if result[ :recovery ]
					end
				end

				exit_code
			end

			# Formats and prints the dry-run plan for one repo.
			def print_housekeep_dry_run( repo_name:, worktree_plan:, branch_plan: )
				stale    = branch_plan.fetch( :stale, [] )
				orphan   = branch_plan.fetch( :orphan, [] )
				absorbed = branch_plan.fetch( :absorbed, [] )

				all_items = worktree_plan + stale + orphan + absorbed
				would_apply = all_items.count { |i| i[ :action ] == :reap || i[ :action ] == :delete }
				would_skip  = all_items.count { |i| i[ :action ] == :skip }

				# Column widths for aligned output.
				name_width = [ ( worktree_plan + stale + orphan + absorbed ).map { |i| i[ :name ].to_s.length + i[ :branch ].to_s.length }.max || 0, 28 ].min + 2
				reason_width = 34

				puts_line "Dry run — #{repo_name}"
				note = gh_available? ? nil : " (gh CLI not available — PR evidence skipped)"
				puts_line "  Note: branch staleness reflects last sync#{note}."
				puts_line ""

				puts_line "  Worktrees:"
				if worktree_plan.empty?
					puts_line "    none"
				else
					worktree_plan.each do |item|
						label = "#{item[ :name ]} (#{item[ :branch ]})"
						action_str = item[ :action ] == :reap ? "→ would reap" : "→ skip"
						puts_line "    #{label.ljust( name_width )}  #{item[ :reason ].ljust( reason_width )}  #{action_str}"
					end
				end

				puts_line ""
				puts_line "  Stale branches (upstream gone):"
				if stale.empty?
					puts_line "    none"
				else
					stale.each { |item| print_branch_plan_item( item: item, name_width: name_width, reason_width: reason_width ) }
				end

				puts_line ""
				puts_line "  Orphan branches (no upstream tracking):"
				if orphan.empty?
					puts_line "    none"
				else
					orphan.each { |item| print_branch_plan_item( item: item, name_width: name_width, reason_width: reason_width ) }
				end

				puts_line ""
				puts_line "  Absorbed branches (content already on main):"
				if absorbed.empty?
					puts_line "    none"
				else
					absorbed.each { |item| print_branch_plan_item( item: item, name_width: name_width, reason_width: reason_width ) }
				end

				puts_line ""
				puts_line "  #{would_apply} would be applied, #{would_skip} skipped."
				puts_line "  Run without --dry-run to apply." if would_apply > 0
			end

			# Prints one branch plan item with aligned columns.
			def print_branch_plan_item( item:, name_width:, reason_width: )
				action_str = item[ :action ] == :delete ? "→ would delete" : "→ skip"
				puts_line "    #{item[ :branch ].ljust( name_width )}  #{item[ :reason ].ljust( reason_width )}  #{action_str}"
			end

			def reap_one_worktree!( worktree:, reason: )
				label = worktree_housekeep_label( worktree: worktree )

				unless worktree.exists?
					git_run( "worktree", "prune" )
					delete_branch_after_reap!( branch: worktree.branch )
					puts_line "Reaped worktree: #{label} — #{reason}" unless verbose?
					return
				end

				_, _, rm_success, = git_run( "worktree", "remove", worktree.path )
				unless rm_success
					puts_line "Kept worktree: #{label} — removal failed" unless verbose?
					return
				end

				delete_branch_after_reap!( branch: worktree.branch )
				puts_line "Reaped worktree: #{label} — #{reason}" unless verbose?
			end

			def delete_branch_after_reap!( branch: )
				return if branch.to_s.strip.empty?
				return if config.protected_branches.include?( branch )

				git_run( "branch", "-D", branch )
				puts_verbose "deleted branch: #{branch}"
			end

			def worktree_housekeep_label( worktree: )
				name = File.basename( worktree.path )
				return name if worktree.branch.to_s.strip.empty?

				"#{name} (#{worktree.branch})"
			end

			# Extracts a short PR reference (e.g. "PR #123") from a GitHub URL.
			def pr_short_ref( url )
				return "PR" if url.nil? || url.empty?
				m = url.match( /\/pull\/(\d+)$/ )
				m ? "PR ##{m[1]}" : "PR"
			end
		end

		include Housekeep
	end
end
