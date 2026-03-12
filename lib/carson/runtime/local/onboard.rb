# Repository onboarding and refresh lifecycle.
# Onboard: detect remote, install hooks, apply templates, run initial audit.
# Refresh: re-apply hooks and templates after Carson upgrade.
# Refresh all: batch refresh across governed portfolio with safety checks.
module Carson
	class Runtime
		module Local
			# One-command onboarding for new repositories: detect remote, install hooks,
			# apply templates, and run initial audit.
			def onboard!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless inside_git_work_tree?
					puts_line "#{repo_root} is not a git repository."
					return EXIT_ERROR
				end

				repo_name = File.basename( repo_root )
				puts_line ""
				puts_line "Onboarding #{repo_name}..."

				if !global_config_exists? || !git_remote_exists?( remote_name: config.git_remote )
					if self.in.respond_to?( :tty? ) && self.in.tty?
						setup_status = setup!
						return setup_status unless setup_status == EXIT_OK
					else
						silent_setup!
					end
				end

				onboard_apply!
			end

			# Re-applies hooks, templates, and audit after upgrading Carson.
			def refresh!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless inside_git_work_tree?
					puts_line "#{repo_root} is not a git repository."
					return EXIT_ERROR
				end

				if verbose?
					puts_verbose ""
					puts_verbose "[Refresh]"
					hook_status = prepare!
					return hook_status unless hook_status == EXIT_OK

					drift_count = template_results.count { it.fetch( :status ) != "ok" }
					stale_count = template_superseded_present.count
					template_status = template_apply!
					return template_status unless template_status == EXIT_OK

					@template_sync_result = template_propagate!( drift_count: drift_count + stale_count )

					audit_status = audit!
					if audit_status == EXIT_OK
						puts_line "OK: Carson refresh completed for #{repo_root}."
					elsif audit_status == EXIT_BLOCK
						puts_line "Refresh complete — some checks need attention. Run carson audit for details."
					end
					return audit_status
				end

				puts_line "Refresh"
				hook_status = with_captured_output { prepare! }
				return hook_status unless hook_status == EXIT_OK
				puts_line "Hooks installed (#{config.managed_hooks.count} hooks)."

				template_drift_count = template_results.count { it.fetch( :status ) != "ok" }
				stale_count = template_superseded_present.count
				template_status = with_captured_output { template_apply! }
				return template_status unless template_status == EXIT_OK
				total_drift = template_drift_count + stale_count
				if total_drift.positive?
					puts_line "Templates applied (#{template_drift_count} updated, #{stale_count} removed)."
				else
					puts_line "Templates in sync."
				end

				@template_sync_result = template_propagate!( drift_count: total_drift )

				audit_status = audit!
				puts_line "Refresh complete."
				audit_status
			end

			# Re-applies hooks, templates, and audit across all governed repositories.
			# Checks each repo for safety (active worktrees, uncommitted changes) and
			# marks unsafe repos as pending to avoid disrupting active work.
			def refresh_all!
				repos = config.govern_repos
				if repos.empty?
					puts_line "No governed repositories configured."
					puts_line "  Run carson onboard in each repo to register."
					return EXIT_ERROR
				end

				pending_before = pending_repos_for( command: "refresh" )
				if pending_before.any?
					puts_line "#{pending_before.length} repo#{plural_suffix( count: pending_before.length )} pending from previous run"
				end

				puts_line ""
				puts_line "Refresh all (#{repos.length} repo#{plural_suffix( count: repos.length )})"
				refreshed = 0
				pending = 0
				failed = 0

				repos.each do |repo_path|
					repo_name = File.basename( repo_path )
					unless Dir.exist?( repo_path )
						puts_line "#{repo_name}: not found"
						record_batch_skip( command: "refresh", repo_path: repo_path, reason: "path not found" )
						failed += 1
						next
					end

					safety = portfolio_repo_safety( repo_path: repo_path )
					unless safety.fetch( :safe )
						reason = safety.fetch( :reasons ).join( ", " )
						puts_line "#{repo_name}: PENDING (#{reason})"
						record_batch_skip( command: "refresh", repo_path: repo_path, reason: reason )
						pending += 1
						next
					end

					status = refresh_single_repo( repo_path: repo_path, repo_name: repo_name )
					if status == EXIT_ERROR
						failed += 1
					else
						clear_batch_success( command: "refresh", repo_path: repo_path )
						refreshed += 1
					end
				end

				puts_line ""
				parts = [ "#{refreshed} refreshed" ]
				parts << "#{pending} still pending (will retry on next run)" if pending.positive?
				parts << "#{failed} failed" if failed.positive?
				puts_line "Refresh all complete: #{parts.join( ', ' )}."
				failed.zero? && pending.zero? ? EXIT_OK : EXIT_ERROR
			end

			def prune_all!
				repos = config.govern_repos
				if repos.empty?
					puts_line "No governed repositories configured."
					puts_line "  Run carson onboard in each repo to register."
					return EXIT_ERROR
				end

				puts_line ""
				puts_line "Prune all (#{repos.length} repo#{plural_suffix( count: repos.length )})"
				succeeded = 0
				failed = 0

				repos.each do |repo_path|
					repo_name = File.basename( repo_path )
					unless Dir.exist?( repo_path )
						puts_line "#{repo_name}: not found"
						record_batch_skip( command: "prune", repo_path: repo_path, reason: "path not found" )
						failed += 1
						next
					end

					begin
						buffer = verbose? ? output : StringIO.new
						error_buffer = verbose? ? error : StringIO.new
						scoped_runtime = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: buffer, error: error_buffer, verbose: verbose? )
						status = scoped_runtime.prune!
						unless verbose?
							summary = buffer.string.lines.last.to_s.strip
							puts_line "#{repo_name}: #{summary.empty? ? 'OK' : summary}"
						end
						if status == EXIT_ERROR
							record_batch_skip( command: "prune", repo_path: repo_path, reason: "prune failed" )
							failed += 1
						else
							clear_batch_success( command: "prune", repo_path: repo_path )
							succeeded += 1
						end
					rescue StandardError => exception
						puts_line "#{repo_name}: could not complete (#{exception.message})"
						record_batch_skip( command: "prune", repo_path: repo_path, reason: exception.message )
						failed += 1
					end
				end

				puts_line ""
				puts_line "Prune all complete: #{succeeded} pruned, #{failed} failed."
				failed.zero? ? EXIT_OK : EXIT_ERROR
			end

			# Removes Carson-managed repository integration so a host repository can retire Carson cleanly.
			def offboard!
				puts_verbose ""
				puts_verbose "[Offboard]"
				unless inside_git_work_tree?
					puts_line "#{repo_root} is not a git repository."
					return EXIT_ERROR
				end
				if self.in.respond_to?( :tty? ) && self.in.tty?
					puts_line ""
					puts_line "This will remove Carson hooks, managed .github/ files,"
					puts_line "and deregister this repository from portfolio governance."
					puts_line "Continue?"
					unless prompt_yes_no( default: false )
						puts_line "Offboard cancelled."
						return EXIT_OK
					end
				end

				hooks_status = disable_carson_hooks_path!
				return hooks_status unless hooks_status == EXIT_OK

				removed_count = 0
				missing_count = 0
				offboard_cleanup_targets.each do |relative|
					absolute = resolve_repo_path!( relative_path: relative, label: "offboard target #{relative}" )
					if File.exist?( absolute )
						FileUtils.rm_rf( absolute )
						puts_verbose "removed_path: #{relative}"
						removed_count += 1
					else
						puts_verbose "skip_missing_path: #{relative}"
						missing_count += 1
					end
				end
				remove_empty_offboard_directories!
				remove_govern_repo!( repo_path: File.expand_path( repo_root ) )
				puts_verbose "govern_deregistered: #{File.expand_path( repo_root )}"
				puts_verbose "offboard_summary: removed=#{removed_count} missing=#{missing_count}"
				if verbose?
					puts_line "OK: Carson offboard completed for #{repo_root}."
				else
					puts_line "Removed #{removed_count} file#{plural_suffix( count: removed_count )}. Offboard complete."
				end
				puts_line ""
				puts_line "Next: commit the removals and push to finalise offboarding."
				EXIT_OK
			end

		private

			# Concise onboard orchestration: hooks, templates, remote, audit, guidance.
			def onboard_apply!
				hook_status = with_captured_output { prepare! }
				return hook_status unless hook_status == EXIT_OK
				puts_line "Hooks installed (#{config.managed_hooks.count} hooks)."

				template_drift_count = template_results.count { it.fetch( :status ) != "ok" }
				template_status = with_captured_output { template_apply! }
				return template_status unless template_status == EXIT_OK
				if template_drift_count.positive?
					puts_line "Templates synced (#{template_drift_count} file#{plural_suffix( count: template_drift_count )} updated)."
				else
					puts_line "Templates in sync."
				end

				onboard_report_remote!
				audit_status = onboard_run_audit!

				puts_line ""
				puts_line "Carson at your service."

				auto_register_govern!

				puts_line ""
				puts_line "Your repository is set up. If you have configured"
				puts_line "lint.canonical, Carson has placed your canonical"
				puts_line "policy files in the project's .github/ directory."
				puts_line "Once pushed to GitHub, they'll ensure every pull"
				puts_line "request follows a consistent standard and all"
				puts_line "checks run automatically."
				puts_line ""
				puts_line "To adjust any setting: carson setup"

				audit_status
			end

			# Friendly remote status for onboard output.
			def onboard_report_remote!
				if git_remote_exists?( remote_name: config.git_remote )
					puts_line "Remote: #{config.git_remote} (connected)."
				else
					puts_line "Remote not configured yet — carson setup will walk you through it."
				end
			end

			# Runs audit with captured output; reports summary instead of full detail.
			def onboard_run_audit!
				audit_error = nil
				audit_status = with_captured_output { audit! }
			rescue StandardError => exception
				audit_error = e
				audit_status = EXIT_OK
			ensure
				return onboard_print_audit_result( status: audit_status, error: audit_error )
			end

			def onboard_print_audit_result( status:, error: )
				if error
					if error.message.to_s.match?( /HEAD|rev-parse/ )
						puts_line "No commits yet — run carson audit after your first commit."
					else
						puts_line "Audit skipped — run carson audit for details."
					end
					return EXIT_OK
				end

				if status == EXIT_BLOCK
					puts_line "Some checks need attention — run carson audit for details."
				end
				status
			end

			# Verifies configured remote exists and logs status without mutating remotes.
			def report_detected_remote!
				if git_remote_exists?( remote_name: config.git_remote )
					puts_verbose "remote_ok: #{config.git_remote}"
				else
					puts_line "Remote '#{config.git_remote}' not found — run carson setup to configure."
				end
			end

			def refresh_sync_suffix( result: )
				return "" if result.nil?

				case result.fetch( :status )
				when :pushed then " (templates pushed to #{result.fetch( :ref )})"
				when :pr then " (PR: #{result.fetch( :pr_url )})"
				else ""
				end
			end

			# Refreshes a single governed repository using a scoped Runtime.
			def refresh_single_repo( repo_path:, repo_name: )
				if verbose?
					scoped_runtime = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: output, error: error, verbose: true )
				else
					scoped_runtime = Runtime.new( repo_root: repo_path, tool_root: tool_root, output: StringIO.new, error: StringIO.new )
				end
				status = scoped_runtime.refresh!
				label = refresh_status_label( status: status )
				sync_suffix = refresh_sync_suffix( result: scoped_runtime.template_sync_result )
				puts_line "#{repo_name}: #{label}#{sync_suffix}"
				status
			rescue StandardError => exception
				puts_line "#{repo_name}: could not complete (#{exception.message})"
				EXIT_ERROR
			end

			def refresh_status_label( status: )
				case status
				when EXIT_OK then "OK"
				when EXIT_BLOCK then "BLOCK"
				else "incomplete"
				end
			end

			def disable_carson_hooks_path!
				configured = configured_hooks_path
				if configured.nil?
					puts_verbose "hooks_path: (unset)"
					return EXIT_OK
				end
				puts_verbose "hooks_path: #{configured}"
				configured_abs = File.expand_path( configured, repo_root )
				unless carson_managed_hooks_path?( configured_abs: configured_abs )
					puts_verbose "hooks_path_kept: #{configured} (not Carson-managed)"
					return EXIT_OK
				end
				git_system!( "config", "--unset", "core.hooksPath" )
				puts_verbose "hooks_path_unset: core.hooksPath"
				EXIT_OK
			rescue StandardError => exception
				puts_line "Could not update core.hooksPath: #{exception.message}"
				EXIT_ERROR
			end

			def carson_managed_hooks_path?( configured_abs: )
				hooks_root = File.join( File.expand_path( config.hooks_path ), "" )
				return true if configured_abs.start_with?( hooks_root )

				carson_hook_files_match_templates?( hooks_path: configured_abs )
			end

			def carson_hook_files_match_templates?( hooks_path: )
				return false unless Dir.exist?( hooks_path )
				config.managed_hooks.all? do |hook_name|
					installed_path = File.join( hooks_path, hook_name )
					template_path = hook_template_path( hook_name: hook_name )
					next false unless File.file?( installed_path ) && File.file?( template_path )

					installed_content = normalize_text( text: File.read( installed_path ) )
					template_content = normalize_text( text: File.read( template_path ) )
					installed_content == template_content
				end
			rescue StandardError
				false
			end

			def offboard_cleanup_targets
				( config.template_managed_files + SUPERSEDED + [
					".github/workflows/carson-governance.yml",
					".github/workflows/carson_policy.yml",
					".carson.yml",
					"bin/carson",
					".tools/carson"
				] ).uniq
			end

			def remove_empty_offboard_directories!
				[ ".github/workflows", ".github", ".tools", "bin" ].each do |relative|
					absolute = resolve_repo_path!( relative_path: relative, label: "offboard cleanup directory #{relative}" )
					next unless Dir.exist?( absolute )
					next unless Dir.empty?( absolute )

					Dir.rmdir( absolute )
					puts_verbose "removed_empty_dir: #{relative}"
				end
			end
		end
	end
end
