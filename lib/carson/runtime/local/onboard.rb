module Carson
	class Runtime
		module Local
			# One-command onboarding for new repositories: detect remote, install hooks,
			# apply templates, and run initial audit.
			def onboard!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless inside_git_work_tree?
					puts_line "ERROR: #{repo_root} is not a git repository."
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
					puts_line "ERROR: #{repo_root} is not a git repository."
					return EXIT_ERROR
				end

				if verbose?
					puts_verbose ""
					puts_verbose "[Refresh]"
					hook_status = prepare!
					return hook_status unless hook_status == EXIT_OK

					drift_count = template_results.count { |entry| entry.fetch( :status ) != "ok" }
					template_status = template_apply!
					return template_status unless template_status == EXIT_OK

					@template_sync_result = template_propagate!( drift_count: drift_count )

					audit_status = audit!
					if audit_status == EXIT_OK
						puts_line "OK: Carson refresh completed for #{repo_root}."
					elsif audit_status == EXIT_BLOCK
						puts_line "BLOCK: Carson refresh completed with policy blocks; resolve and rerun carson audit."
					end
					return audit_status
				end

				puts_line "Refresh"
				hook_status = with_captured_output { prepare! }
				return hook_status unless hook_status == EXIT_OK
				puts_line "Hooks installed (#{config.managed_hooks.count} hooks)."

				template_drift_count = template_results.count { |entry| entry.fetch( :status ) != "ok" }
				template_status = with_captured_output { template_apply! }
				return template_status unless template_status == EXIT_OK
				if template_drift_count.positive?
					puts_line "Templates applied (#{template_drift_count} updated)."
				else
					puts_line "Templates in sync."
				end

				@template_sync_result = template_propagate!( drift_count: template_drift_count )

				audit_status = audit!
				puts_line "Refresh complete."
				audit_status
			end

			# Re-applies hooks, templates, and audit across all governed repositories.
			def refresh_all!
				repos = config.govern_repos
				if repos.empty?
					puts_line "No governed repositories configured."
					puts_line "  Run carson onboard in each repo to register."
					return EXIT_ERROR
				end

				puts_line ""
				puts_line "Refresh all (#{repos.length} repo#{plural_suffix( count: repos.length )})"
				refreshed = 0
				failed = 0

				repos.each do |repo_path|
					repo_name = File.basename( repo_path )
					unless Dir.exist?( repo_path )
						puts_line "#{repo_name}: FAIL (path not found)"
						failed += 1
						next
					end

					status = refresh_single_repo( repo_path: repo_path, repo_name: repo_name )
					if status == EXIT_ERROR
						failed += 1
					else
						refreshed += 1
					end
				end

				puts_line ""
				puts_line "Refresh all complete: #{refreshed} refreshed, #{failed} failed."
				failed.zero? ? EXIT_OK : EXIT_ERROR
			end

			# Removes Carson-managed repository integration so a host repository can retire Carson cleanly.
			def offboard!
				puts_verbose ""
				puts_verbose "[Offboard]"
				unless inside_git_work_tree?
					puts_line "ERROR: #{repo_root} is not a git repository."
					return EXIT_ERROR
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
				EXIT_OK
			end

		private

			# Concise onboard orchestration: hooks, templates, remote, audit, guidance.
			def onboard_apply!
				hook_status = with_captured_output { prepare! }
				return hook_status unless hook_status == EXIT_OK
				puts_line "Hooks installed (#{config.managed_hooks.count} hooks)."

				template_drift_count = template_results.count { |entry| entry.fetch( :status ) != "ok" }
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

				prompt_govern_registration! if self.in.respond_to?( :tty? ) && self.in.tty?

				puts_line ""
				puts_line "Your repository is set up. Carson has placed files in your"
				puts_line "project's .github/ directory — pull request templates,"
				puts_line "guidelines for AI coding assistants, and any CI or lint"
				puts_line "rules you've configured. Once pushed to GitHub, they'll"
				puts_line "ensure every pull request follows a consistent standard"
				puts_line "and all checks run automatically."
				puts_line ""
				puts_line "Before your first push, have a look through .github/ to"
				puts_line "make sure everything is to your liking."
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
			rescue StandardError => e
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
					puts_line "WARN: remote '#{config.git_remote}' not found; run carson setup to configure."
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
					rt = Runtime.new( repo_root: repo_path, tool_root: tool_root, out: out, err: err, verbose: true )
				else
					rt = Runtime.new( repo_root: repo_path, tool_root: tool_root, out: StringIO.new, err: StringIO.new )
				end
				status = rt.refresh!
				label = refresh_status_label( status: status )
				sync_suffix = refresh_sync_suffix( result: rt.template_sync_result )
				puts_line "#{repo_name}: #{label}#{sync_suffix}"
				status
			rescue StandardError => e
				puts_line "#{repo_name}: FAIL (#{e.message})"
				EXIT_ERROR
			end

			def refresh_status_label( status: )
				case status
				when EXIT_OK then "OK"
				when EXIT_BLOCK then "BLOCK"
				else "FAIL"
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
			rescue StandardError => e
				puts_line "ERROR: unable to update core.hooksPath (#{e.message})"
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
