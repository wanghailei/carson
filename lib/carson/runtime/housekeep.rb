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
			def housekeep!( json_output: false )
				housekeep_one( repo_path: repo_root, json_output: json_output )
			end

			# Resolves a target name to a governed repo, then serves it.
			def housekeep_target!( target:, json_output: false )
				repo_path = resolve_governed_repo( target: target )
				unless repo_path
					result = { command: "housekeep", status: "error", error: "Not a governed repository: #{target}", recovery: "Run carson repos to see governed repositories." }
					return housekeep_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				housekeep_one( repo_path: repo_path, json_output: json_output )
			end

			# Knocks each governed repo's gate in turn.
			def housekeep_all!( json_output: false )
				repos = config.govern_repos
				if repos.empty?
					result = { command: "housekeep", status: "error", error: "No governed repositories configured.", recovery: "Run carson onboard in each repo to register." }
					return housekeep_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

				results = []
				repos.each { |repo_path| results << housekeep_one_entry( repo_path: repo_path, silent: json_output ) }

				succeeded = results.count { |r| r[ :status ] == "ok" }
				failed = results.count { |r| r[ :status ] != "ok" }
				result = { command: "housekeep", status: failed.zero? ? "ok" : "partial", repos: results, succeeded: succeeded, failed: failed }
				housekeep_finish( result: result, exit_code: failed.zero? ? EXIT_OK : EXIT_ERROR, json_output: json_output, results: results, succeeded: succeeded, failed: failed )
			end

			# Removes dead worktrees — those whose content is on main or with merged PR evidence.
			# Unblocks prune for the branches they hold.
			# Two-layer dead check:
			#   1. Content-absorbed: delegates to sweep_stale_worktrees! (shared, no gh needed).
			#   2. Merged PR evidence: covers rebase/squash where main has since evolved
			#      the same files (requires gh).
			def reap_dead_worktrees!
				# Layer 1: sweep agent-owned worktrees whose content is on main.
				sweep_stale_worktrees!

				# Layer 2: merged PR evidence for remaining worktrees.
				return unless gh_available?

				main_root = main_worktree_root
				worktree_list.each do |wt|
					path = wt.fetch( :path )
					branch = wt.fetch( :branch, nil )
					next if path == main_root
					next unless branch
					next if cwd_inside_worktree?( worktree_path: path )

					tip_sha = git_capture!( "rev-parse", "--verify", branch ).strip rescue nil
					next unless tip_sha

					merged_pr, = merged_pr_for_branch( branch: branch, branch_tip_sha: tip_sha )
					next if merged_pr.nil?

					# Remove the worktree (no --force: refuses if dirty working tree).
					_, _, rm_success, = git_run( "worktree", "remove", path )
					next unless rm_success

					puts_verbose "reaped dead worktree: #{File.basename( path )} (branch: #{branch})"

					# Delete the local branch now that no worktree holds it.
					if !config.protected_branches.include?( branch )
						git_run( "branch", "-D", branch )
						puts_verbose "deleted branch: #{branch}"
					end
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

				buf = verbose? ? out : StringIO.new
				err_buf = verbose? ? err : StringIO.new
				rt = Runtime.new( repo_root: repo_path, tool_root: tool_root, out: buf, err: err_buf, verbose: verbose? )

				sync_status = rt.sync!
				if sync_status == EXIT_OK
					rt.reap_dead_worktrees!
					prune_status = rt.prune!
				end

				ok = sync_status == EXIT_OK && prune_status == EXIT_OK
				unless verbose? || silent
					summary = strip_badge( buf.string.lines.last.to_s.strip )
					puts_line "#{repo_name}: #{summary.empty? ? 'OK' : summary}"
				end

				{ name: repo_name, path: repo_path, status: ok ? "ok" : "error" }
			rescue StandardError => e
				puts_line "#{repo_name}: FAIL (#{e.message})" unless silent
				{ name: repo_name, path: repo_path, status: "error", error: e.message }
			end

			# Strips the Carson badge prefix from a message to avoid double-badging.
			def strip_badge( text )
				text.sub( /\A#{Regexp.escape( BADGE )}\s*/, "" )
			end

			# Resolves a user-supplied target to a governed repository path.
			# Accepts: exact path, expandable path, or basename match (case-insensitive).
			def resolve_governed_repo( target: )
				repos = config.govern_repos
				expanded = File.expand_path( target )
				return expanded if repos.include?( expanded )

				downcased = File.basename( target ).downcase
				repos.find { |r| File.basename( r ).downcase == downcased }
			end

			# Unified output — JSON or human-readable.
			def housekeep_finish( result:, exit_code:, json_output:, results: nil, succeeded: nil, failed: nil )
				result[ :exit_code ] = exit_code

				if json_output
					out.puts JSON.pretty_generate( result )
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
		end

		include Housekeep
	end
end
