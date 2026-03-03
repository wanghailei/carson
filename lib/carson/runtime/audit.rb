require "cgi"
require "open3"

module Carson
	class Runtime
		module Audit
			def audit!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				audit_state = "ok"
				audit_concise_problems = []
				puts_verbose ""
				puts_verbose "[Repository]"
				puts_verbose "root: #{repo_root}"
				puts_verbose "current_branch: #{current_branch}"
				puts_verbose ""
				puts_verbose "[Working Tree]"
				puts_verbose git_capture!( "status", "--short", "--branch" ).strip
				puts_verbose ""
				puts_verbose "[Hooks]"
				hooks_ok = hooks_health_report
				unless hooks_ok
					audit_state = "block"
					audit_concise_problems << "Hooks: mismatch — run carson prepare."
				end
				puts_verbose ""
				puts_verbose "[Local Lint Quality]"
				local_lint_quality = local_lint_quality_report
				if local_lint_quality.fetch( :status ) == "block"
					audit_state = "block"
					blocking_langs = local_lint_quality.fetch( :languages ).select { |l| l.fetch( :status ) == "block" }
					blocking_langs.each do |lang|
						exit_code = lang.fetch( :exit_code, 1 )
						audit_concise_problems << "Lint: #{lang.fetch( :language )} failed (exit #{exit_code})."
					end
				end
				puts_verbose ""
				puts_verbose "[Main Sync Status]"
				ahead_count, behind_count, main_error = main_sync_counts
				if main_error
					puts_verbose "main_vs_remote_main: unknown"
					puts_verbose "WARN: unable to calculate main sync status (#{main_error})."
					audit_state = "attention" if audit_state == "ok"
				elsif ahead_count.positive?
					puts_verbose "main_vs_remote_main_ahead: #{ahead_count}"
					puts_verbose "main_vs_remote_main_behind: #{behind_count}"
					puts_verbose "ACTION: local #{config.main_branch} is ahead of #{config.git_remote}/#{config.main_branch} by #{ahead_count} commit#{plural_suffix( count: ahead_count )}; reset local drift before commit/push workflows."
					audit_state = "block"
					audit_concise_problems << "Main sync (#{config.git_remote}): ahead by #{ahead_count} — git fetch #{config.git_remote}, or carson setup to switch remote."
				elsif behind_count.positive?
					puts_verbose "main_vs_remote_main_ahead: #{ahead_count}"
					puts_verbose "main_vs_remote_main_behind: #{behind_count}"
					puts_verbose "ACTION: local #{config.main_branch} is behind #{config.git_remote}/#{config.main_branch} by #{behind_count} commit#{plural_suffix( count: behind_count )}; run carson sync."
					audit_state = "attention" if audit_state == "ok"
					audit_concise_problems << "Main sync (#{config.git_remote}): behind by #{behind_count} — run carson sync."
				else
					puts_verbose "main_vs_remote_main_ahead: 0"
					puts_verbose "main_vs_remote_main_behind: 0"
					puts_verbose "ACTION: local #{config.main_branch} is in sync with #{config.git_remote}/#{config.main_branch}."
				end
				puts_verbose ""
				puts_verbose "[PR and Required Checks (gh)]"
				monitor_report = pr_and_check_report
				audit_state = "attention" if audit_state == "ok" && monitor_report.fetch( :status ) != "ok"
				puts_verbose ""
				puts_verbose "[Default Branch CI Baseline (gh)]"
				default_branch_baseline = default_branch_ci_baseline_report
				audit_state = "block" if default_branch_baseline.fetch( :status ) == "block"
				audit_state = "attention" if audit_state == "ok" && default_branch_baseline.fetch( :status ) != "ok"
				scope_guard = print_scope_integrity_guard
				audit_state = "attention" if audit_state == "ok" && scope_guard.fetch( :status ) == "attention"
					write_and_print_pr_monitor_report(
						report: monitor_report.merge(
							local_lint_quality: local_lint_quality,
							default_branch_baseline: default_branch_baseline,
							audit_status: audit_state
						)
					)
				puts_verbose ""
				puts_verbose "[Audit Result]"
				puts_verbose "status: #{audit_state}"
				puts_verbose( audit_state == "block" ? "ACTION: local policy block must be resolved before commit/push." : "ACTION: no local hard block detected." )
				unless verbose?
					audit_concise_problems.each { |problem| puts_line problem }
					puts_line "Audit: #{audit_state}"
				end
				audit_state == "block" ? EXIT_BLOCK : EXIT_OK
			end

		private
			def pr_and_check_report
				report = {
				generated_at: Time.now.utc.iso8601,
				branch: current_branch,
				status: "ok",
				skip_reason: nil,
				pr: nil,
				checks: {
				status: "unknown",
				skip_reason: nil,
				required_total: 0,
				failing_count: 0,
				pending_count: 0,
				failing: [],
				pending: []
				}
				}
				unless gh_available?
					report[ :status ] = "skipped"
					report[ :skip_reason ] = "gh CLI not available in PATH"
					puts_verbose "SKIP: #{report.fetch( :skip_reason )}"
					return report
				end
				pr_stdout, pr_stderr, pr_success, = gh_run( "pr", "view", current_branch, "--json", "number,title,url,state,reviewDecision" )
				unless pr_success
					error_text = gh_error_text( stdout_text: pr_stdout, stderr_text: pr_stderr, fallback: "unable to read PR for branch #{current_branch}" )
					report[ :status ] = "skipped"
					report[ :skip_reason ] = error_text
					puts_verbose "SKIP: #{error_text}"
					return report
				end
				pr_data = JSON.parse( pr_stdout )
				report[ :pr ] = {
				number: pr_data[ "number" ],
				title: pr_data[ "title" ].to_s,
				url: pr_data[ "url" ].to_s,
				state: pr_data[ "state" ].to_s,
				review_decision: blank_to( value: pr_data[ "reviewDecision" ], default: "NONE" )
				}
				puts_verbose "pr: ##{report.dig( :pr, :number )} #{report.dig( :pr, :title )}"
				puts_verbose "url: #{report.dig( :pr, :url )}"
				puts_verbose "review_decision: #{report.dig( :pr, :review_decision )}"
				checks_stdout, checks_stderr, checks_success, checks_exit = gh_run( "pr", "checks", report.dig( :pr, :number ).to_s, "--required", "--json", "name,state,bucket,workflow,link" )
				if checks_stdout.to_s.strip.empty?
					error_text = gh_error_text( stdout_text: checks_stdout, stderr_text: checks_stderr, fallback: "required checks unavailable" )
					report[ :checks ][ :status ] = "skipped"
					report[ :checks ][ :skip_reason ] = error_text
					report[ :status ] = "attention"
					puts_verbose "checks: SKIP (#{error_text})"
					return report
				end
				checks_data = JSON.parse( checks_stdout )
				failing = checks_data.select { |entry| entry[ "bucket" ].to_s == "fail" || entry[ "state" ].to_s.upcase == "FAILURE" }
				pending = checks_data.select { |entry| entry[ "bucket" ].to_s == "pending" }
				report[ :checks ][ :status ] = checks_success ? "ok" : ( checks_exit == 8 ? "pending" : "attention" )
				report[ :checks ][ :required_total ] = checks_data.count
				report[ :checks ][ :failing_count ] = failing.count
				report[ :checks ][ :pending_count ] = pending.count
				report[ :checks ][ :failing ] = normalise_check_entries( entries: failing )
				report[ :checks ][ :pending ] = normalise_check_entries( entries: pending )
				puts_verbose "required_checks_total: #{report.dig( :checks, :required_total )}"
				puts_verbose "required_checks_failing: #{report.dig( :checks, :failing_count )}"
				puts_verbose "required_checks_pending: #{report.dig( :checks, :pending_count )}"
				report.dig( :checks, :failing ).each { |entry| puts_verbose "check_fail: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report.dig( :checks, :pending ).each { |entry| puts_verbose "check_pending: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report[ :status ] = "attention" if report.dig( :checks, :failing_count ).positive? || report.dig( :checks, :pending_count ).positive?
				report
				rescue JSON::ParserError => e
					report[ :status ] = "skipped"
					report[ :skip_reason ] = "invalid gh JSON response (#{e.message})"
					puts_verbose "SKIP: #{report.fetch( :skip_reason )}"
					report
				end

			# Enforces configured lint policy before governance passes.
			# Runs lint.command and gates on exit code. Skips when lint.command is not set.
			def local_lint_quality_report
				unless config.lint_command
					report = {
						status: "ok",
						skip_reason: "lint.command not configured",
						target_source: "none",
						target_files_count: 0,
						blocking_languages: 0,
						languages: []
					}
					puts_verbose "lint: SKIP (lint.command not configured)"
					return report
				end

				lint_command_report
			rescue StandardError => e
				report = {
					status: "block",
					skip_reason: e.message,
					target_source: "unknown",
					target_files_count: 0,
					blocking_languages: 0,
					languages: []
				}
				puts_line "BLOCK: local lint quality check failed (#{e.message})."
				report
			end

			# Runs the lint.command and returns a structured report.
			def lint_command_report
				target_files, target_source = lint_target_files
				advisory = config.lint_enforcement == "advisory"
				command_value = config.lint_command
				command_string = command_value.is_a?( Array ) ? command_value.join( " " ) : command_value.to_s

				report = {
					status: "ok",
					skip_reason: nil,
					target_source: target_source,
					target_files_count: target_files.count,
					blocking_languages: 0,
					languages: []
				}
				puts_verbose "lint_target_source: #{target_source}"
				puts_verbose "lint_target_files_total: #{target_files.count}"
				puts_verbose "lint_command: #{command_string}"
				puts_verbose "lint_enforcement: #{config.lint_enforcement}"

				args = command_string.split( /\s+/ )
				command_name = args.first.to_s.strip
				unless command_available_for_lint?( command_name: command_name )
					language_report = {
						language: "lint.command",
						enabled: true,
						status: "block",
						reason: "command not available: #{command_name}",
						file_count: target_files.count,
						files: target_files,
						command: args,
						config_files: [],
						exit_code: EXIT_BLOCK
					}
					report[ :languages ] << language_report
					report[ :status ] = advisory ? "ok" : "block"
					report[ :blocking_languages ] = advisory ? 0 : 1
					puts_verbose "lint_command_status: #{language_report.fetch( :status )}"
					puts_line "WARN: lint command not available: #{command_name}" if advisory
					return report
				end

				stdout_text, stderr_text, success, exit_code = local_command( *args )
				language_report = {
					language: "lint.command",
					enabled: true,
					status: success ? "ok" : "block",
					reason: success ? nil : summarise_command_output(
						stdout_text: stdout_text,
						stderr_text: stderr_text,
						fallback: "lint command failed"
					),
					file_count: target_files.count,
					files: target_files,
					command: args,
					config_files: [],
					exit_code: exit_code
				}
				report[ :languages ] << language_report

				unless success
					if advisory
						report[ :status ] = "ok"
						puts_verbose "lint_command_status: advisory_warn (exit #{exit_code})"
						puts_line "WARN: lint command failed (exit #{exit_code}) — advisory mode, not blocking."
					else
						report[ :status ] = "block"
						report[ :blocking_languages ] = 1
						puts_verbose "lint_command_status: block (exit #{exit_code})"
					end
				else
					puts_verbose "lint_command_status: ok"
				end

				report
			end

			# File selection precedence:
			# 1) staged files for local commit-time execution
			# 2) PR changed files in GitHub pull_request events
			# 3) full repository tracked files in GitHub non-PR events
			# 4) local working-tree changed files as fallback
			def lint_target_files
				staged = existing_repo_files( paths: staged_files )
				return [ staged, "staged" ] unless staged.empty?

				if github_pull_request_event?
					files = lint_target_files_for_pull_request
					return [ files, "github_pull_request" ] unless files.nil?
					puts_verbose "WARN: unable to resolve pull request changed files; falling back to full repository files."
				end

				if github_actions_environment?
					return [ lint_target_files_for_non_pr_ci, "github_full_repository" ]
				end

				[ existing_repo_files( paths: changed_files ), "working_tree" ]
			end

			def lint_target_files_for_pull_request
				base_ref = ENV.fetch( "GITHUB_BASE_REF", "" ).to_s.strip
				return nil if base_ref.empty?

				remote_name = config.git_remote
				unless git_remote_exists?( remote_name: remote_name )
					remote_name = "origin" if git_remote_exists?( remote_name: "origin" )
				end

				_, _, fetch_success, = git_run( "fetch", "--no-tags", "--depth", "1", remote_name, base_ref )
				return nil unless fetch_success

				base = "#{remote_name}/#{base_ref}"
				stdout_text, _, success, = git_run(
					"diff", "--name-only", "--diff-filter=ACMRTUXB", "#{base}...HEAD"
				)
				return nil unless success

				paths = stdout_text.lines.map { |line| line.to_s.strip }.reject( &:empty? )
				existing_repo_files( paths: paths )
			end

			def lint_target_files_for_non_pr_ci
				stdout_text = git_capture!( "ls-files" )
				paths = stdout_text.lines.map { |line| line.to_s.strip }.reject( &:empty? )
				existing_repo_files( paths: paths )
			end

			def github_actions_environment?
				ENV.fetch( "GITHUB_ACTIONS", "" ).to_s.strip.casecmp( "true" ).zero?
			end

			def github_pull_request_event?
				return false unless github_actions_environment?

				event_name = ENV.fetch( "GITHUB_EVENT_NAME", "" ).to_s.strip
				[ "pull_request", "pull_request_target" ].include?( event_name )
			end

			def existing_repo_files( paths: )
				Array( paths ).map do |relative|
					next if relative.to_s.strip.empty?
					absolute = resolve_repo_path!( relative_path: relative, label: "lint target file #{relative}" )
					next unless File.file?( absolute )
					relative
				end.compact.uniq
			end

			def command_available_for_lint?( command_name: )
				return false if command_name.to_s.strip.empty?

				if command_name.include?( "/" )
					path = if command_name.start_with?( "~" )
						File.expand_path( command_name )
					elsif command_name.start_with?( "/" )
						command_name
					else
						File.expand_path( command_name, repo_root )
					end
					return File.executable?( path )
				end
				path_entries = ENV.fetch( "PATH", "" ).split( File::PATH_SEPARATOR )
				path_entries.any? do |entry|
					next false if entry.to_s.strip.empty?
					File.executable?( File.join( entry, command_name ) )
				end
			end

			# Local command runner for repository-context tools used by audit lint checks.
			def local_command( *args )
				stdout_text, stderr_text, status = Open3.capture3( *args, chdir: repo_root )
				[ stdout_text, stderr_text, status.success?, status.exitstatus ]
			end

			# Compacts command output to one-line diagnostics for audit logs and JSON report payloads.
			def summarise_command_output( stdout_text:, stderr_text:, fallback: )
				combined = [ stderr_text.to_s, stdout_text.to_s ].join( "\n" )
				lines = combined.lines.map { |line| line.to_s.strip }.reject( &:empty? )
				return fallback if lines.empty?
				lines.first( 12 ).join( " | " )
			end

			# Evaluates default-branch CI health so stale workflow drift blocks before merge.
			def default_branch_ci_baseline_report
				report = {
				status: "ok",
				skip_reason: nil,
				repository: nil,
				default_branch: nil,
				head_sha: nil,
				workflows_total: 0,
				check_runs_total: 0,
				failing_count: 0,
				pending_count: 0,
				advisory_failing_count: 0,
				advisory_pending_count: 0,
				no_check_evidence: false,
				failing: [],
				pending: [],
				advisory_failing: [],
				advisory_pending: []
				}
				unless gh_available?
					report[ :status ] = "skipped"
					report[ :skip_reason ] = "gh CLI not available in PATH"
					puts_verbose "baseline: SKIP (#{report.fetch( :skip_reason )})"
					return report
				end
				owner, repo = repository_coordinates
				report[ :repository ] = "#{owner}/#{repo}"
				repository_data = gh_json_payload!(
				"api", "repos/#{owner}/#{repo}",
				"--method", "GET",
				fallback: "unable to read repository metadata for #{owner}/#{repo}"
				)
				default_branch = blank_to( value: repository_data[ "default_branch" ], default: config.main_branch )
				report[ :default_branch ] = default_branch
				branch_data = gh_json_payload!(
				"api", "repos/#{owner}/#{repo}/branches/#{CGI.escape( default_branch )}",
				"--method", "GET",
				fallback: "unable to read default branch #{default_branch}"
				)
				head_sha = branch_data.dig( "commit", "sha" ).to_s.strip
				raise "default branch #{default_branch} has no commit SHA" if head_sha.empty?
				report[ :head_sha ] = head_sha
				workflow_entries = default_branch_workflow_entries(
				owner: owner,
				repo: repo,
				default_branch: default_branch
				)
				report[ :workflows_total ] = workflow_entries.count
				check_runs_payload = gh_json_payload!(
				"api", "repos/#{owner}/#{repo}/commits/#{head_sha}/check-runs",
				"--method", "GET",
				fallback: "unable to read check-runs for #{default_branch}@#{head_sha}"
				)
				check_runs = Array( check_runs_payload[ "check_runs" ] )
				failing, pending = partition_default_branch_check_runs( check_runs: check_runs )
				advisory_names = config.audit_advisory_check_names
				critical_failing, advisory_failing = separate_advisory_check_entries( entries: failing, advisory_names: advisory_names )
				critical_pending, advisory_pending = separate_advisory_check_entries( entries: pending, advisory_names: advisory_names )
				report[ :check_runs_total ] = check_runs.count
				report[ :failing ] = normalise_default_branch_check_entries( entries: critical_failing )
				report[ :pending ] = normalise_default_branch_check_entries( entries: critical_pending )
				report[ :advisory_failing ] = normalise_default_branch_check_entries( entries: advisory_failing )
				report[ :advisory_pending ] = normalise_default_branch_check_entries( entries: advisory_pending )
				report[ :failing_count ] = report.fetch( :failing ).count
				report[ :pending_count ] = report.fetch( :pending ).count
				report[ :advisory_failing_count ] = report.fetch( :advisory_failing ).count
				report[ :advisory_pending_count ] = report.fetch( :advisory_pending ).count
				report[ :no_check_evidence ] = report.fetch( :workflows_total ).positive? && report.fetch( :check_runs_total ).zero?
				report[ :status ] = "block" if report.fetch( :failing_count ).positive?
				report[ :status ] = "block" if report.fetch( :pending_count ).positive?
				report[ :status ] = "block" if report.fetch( :no_check_evidence )
				report[ :status ] = "attention" if report.fetch( :status ) == "ok" && ( report.fetch( :advisory_failing_count ).positive? || report.fetch( :advisory_pending_count ).positive? )
				puts_verbose "default_branch_repository: #{report.fetch( :repository )}"
				puts_verbose "default_branch_name: #{report.fetch( :default_branch )}"
				puts_verbose "default_branch_head_sha: #{report.fetch( :head_sha )}"
				puts_verbose "default_branch_workflows_total: #{report.fetch( :workflows_total )}"
				puts_verbose "default_branch_check_runs_total: #{report.fetch( :check_runs_total )}"
				puts_verbose "default_branch_failing: #{report.fetch( :failing_count )}"
				puts_verbose "default_branch_pending: #{report.fetch( :pending_count )}"
				puts_verbose "default_branch_advisory_failing: #{report.fetch( :advisory_failing_count )}"
				puts_verbose "default_branch_advisory_pending: #{report.fetch( :advisory_pending_count )}"
				report.fetch( :failing ).each { |entry| puts_verbose "default_branch_check_fail: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report.fetch( :pending ).each { |entry| puts_verbose "default_branch_check_pending: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report.fetch( :advisory_failing ).each { |entry| puts_verbose "default_branch_check_advisory_fail: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (advisory) #{entry.fetch( :link )}".strip }
				report.fetch( :advisory_pending ).each { |entry| puts_verbose "default_branch_check_advisory_pending: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (advisory) #{entry.fetch( :link )}".strip }
				if report.fetch( :no_check_evidence )
					puts_verbose "ACTION: default branch has workflow files but no check-runs; align workflow triggers and branch protection check names."
				end
				report
			rescue JSON::ParserError => e
				report[ :status ] = "skipped"
				report[ :skip_reason ] = "invalid gh JSON response (#{e.message})"
				puts_verbose "baseline: SKIP (#{report.fetch( :skip_reason )})"
				report
			rescue StandardError => e
				report[ :status ] = "skipped"
				report[ :skip_reason ] = e.message
				puts_verbose "baseline: SKIP (#{report.fetch( :skip_reason )})"
				report
			end

			# Reads JSON API payloads and raises a detailed error when gh reports non-success.
			def gh_json_payload!( *args, fallback: )
				stdout_text, stderr_text, success, = gh_run( *args )
				unless success
					error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: fallback )
					raise error_text
				end
				JSON.parse( stdout_text )
			end

			# Reads workflow files from default branch; missing workflow directory is valid and returns none.
			def default_branch_workflow_entries( owner:, repo:, default_branch: )
				stdout_text, stderr_text, success, = gh_run(
				"api", "repos/#{owner}/#{repo}/contents/.github/workflows",
				"--method", "GET",
				"-f", "ref=#{default_branch}"
				)
				unless success
					error_text = gh_error_text(
					stdout_text: stdout_text,
					stderr_text: stderr_text,
					fallback: "unable to read workflow files for #{default_branch}"
					)
					return [] if error_text.match?( /\b404\b/ )
					raise error_text
				end
				payload = JSON.parse( stdout_text )
				Array( payload ).select do |entry|
					entry.is_a?( Hash ) &&
						entry[ "type" ].to_s == "file" &&
						entry[ "name" ].to_s.match?( /\.ya?ml\z/i )
				end
			end

			# Splits default-branch check-runs into failing and pending policy buckets.
			def partition_default_branch_check_runs( check_runs: )
				failing = []
				pending = []
				Array( check_runs ).each do |entry|
					if default_branch_check_run_failing?( entry: entry )
						failing << entry
					elsif default_branch_check_run_pending?( entry: entry )
						pending << entry
					end
				end
				[ failing, pending ]
			end

			# Separates check-run entries into critical and advisory buckets based on configured advisory names.
			def separate_advisory_check_entries( entries:, advisory_names: )
				advisory, critical = Array( entries ).partition do |entry|
					advisory_names.include?( entry[ "name" ].to_s.strip )
				end
				[ critical, advisory ]
			end

			# Failing means completed with a non-successful conclusion.
			def default_branch_check_run_failing?( entry: )
				status = entry[ "status" ].to_s.strip.downcase
				conclusion = entry[ "conclusion" ].to_s.strip.downcase
				status == "completed" && !conclusion.empty? && !%w[success neutral skipped].include?( conclusion )
			end

			# Pending includes non-completed checks and completed checks missing conclusion.
			def default_branch_check_run_pending?( entry: )
				status = entry[ "status" ].to_s.strip.downcase
				conclusion = entry[ "conclusion" ].to_s.strip.downcase
				return true if status.empty?
				return true unless status == "completed"

				conclusion.empty?
			end

			# Normalises default-branch check-runs to report layout used by markdown output.
			def normalise_default_branch_check_entries( entries: )
				Array( entries ).map do |entry|
					state = if entry[ "status" ].to_s.strip.downcase == "completed"
						blank_to( value: entry[ "conclusion" ], default: "UNKNOWN" )
					else
						blank_to( value: entry[ "status" ], default: "UNKNOWN" )
					end
					{
					workflow: blank_to( value: entry.dig( "app", "name" ), default: "workflow" ),
					name: blank_to( value: entry[ "name" ], default: "check" ),
					state: state.upcase,
					link: entry[ "html_url" ].to_s
					}
				end
			end

			# Writes monitor report artefacts and prints their locations.
			def write_and_print_pr_monitor_report( report: )
				markdown_path, json_path = write_pr_monitor_report( report: report )
				puts_verbose "report_markdown: #{markdown_path}"
				puts_verbose "report_json: #{json_path}"
			rescue StandardError => e
				puts_verbose "report_write: SKIP (#{e.message})"
			end

			# Persists report in both machine-readable JSON and human-readable Markdown.
			def write_pr_monitor_report( report: )
				report_dir = report_dir_path
				FileUtils.mkdir_p( report_dir )
				markdown_path = File.join( report_dir, REPORT_MD )
				json_path = File.join( report_dir, REPORT_JSON )
				File.write( json_path, JSON.pretty_generate( report ) )
				File.write( markdown_path, render_pr_monitor_markdown( report: report ) )
				[ markdown_path, json_path ]
			end

			# Renders Markdown summary used by humans during merge-readiness reviews.
			def render_pr_monitor_markdown( report: )
				lines = []
				lines << "# Carson PR Monitor Report"
				lines << ""
				lines << "- Generated at: #{report.fetch( :generated_at )}"
				lines << "- Branch: #{report.fetch( :branch )}"
				lines << "- Audit status: #{report.fetch( :audit_status, 'unknown' )}"
				lines << "- Monitor status: #{report.fetch( :status )}"
				lines << "- Skip reason: #{report.fetch( :skip_reason )}" unless report.fetch( :skip_reason ).nil?
				lines << ""
				lines << "## PR"
				pr = report[ :pr ]
				if pr.nil?
					lines << "- not available"
				else
					lines << "- Number: ##{pr.fetch( :number )}"
					lines << "- Title: #{pr.fetch( :title )}"
					lines << "- URL: #{pr.fetch( :url )}"
					lines << "- State: #{pr.fetch( :state )}"
					lines << "- Review decision: #{pr.fetch( :review_decision )}"
				end
				lines << ""
				lines << "## Required Checks"
				checks = report.fetch( :checks )
				lines << "- Status: #{checks.fetch( :status )}"
				lines << "- Skip reason: #{checks.fetch( :skip_reason )}" unless checks.fetch( :skip_reason ).nil?
				lines << "- Total: #{checks.fetch( :required_total )}"
				lines << "- Failing: #{checks.fetch( :failing_count )}"
				lines << "- Pending: #{checks.fetch( :pending_count )}"
				lines << ""
				lines << "### Failing"
				if checks.fetch( :failing ).empty?
					lines << "- none"
				else
					checks.fetch( :failing ).each { |entry| lines << "- #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (#{entry.fetch( :state )}) #{entry.fetch( :link )}".strip }
				end
				lines << ""
				lines << "### Pending"
				if checks.fetch( :pending ).empty?
					lines << "- none"
				else
					checks.fetch( :pending ).each { |entry| lines << "- #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (#{entry.fetch( :state )}) #{entry.fetch( :link )}".strip }
				end
				lines << ""
				lines << "## Local Lint Quality"
				lint_quality = report[ :local_lint_quality ]
				if lint_quality.nil?
					lines << "- not available"
				else
					lines << "- Status: #{lint_quality.fetch( :status )}"
					lines << "- Skip reason: #{lint_quality.fetch( :skip_reason )}" unless lint_quality.fetch( :skip_reason ).nil?
					lines << "- Target source: #{lint_quality.fetch( :target_source )}"
					lines << "- Target files: #{lint_quality.fetch( :target_files_count )}"
					lines << "- Blocking languages: #{lint_quality.fetch( :blocking_languages )}"
					lines << ""
					lines << "### Language Results"
					if lint_quality.fetch( :languages ).empty?
						lines << "- none"
					else
						lint_quality.fetch( :languages ).each do |entry|
							lines << "- #{entry.fetch( :language )}: status=#{entry.fetch( :status )} files=#{entry.fetch( :file_count )} exit=#{entry.fetch( :exit_code )}"
							lines << "  reason: #{entry.fetch( :reason )}" unless entry.fetch( :reason ).nil?
						end
					end
				end
				lines << ""
				lines << "## Default Branch CI Baseline"
				baseline = report[ :default_branch_baseline ]
				if baseline.nil?
					lines << "- not available"
				else
					lines << "- Status: #{baseline.fetch( :status )}"
					lines << "- Skip reason: #{baseline.fetch( :skip_reason )}" unless baseline.fetch( :skip_reason ).nil?
					lines << "- Repository: #{baseline.fetch( :repository )}" unless baseline.fetch( :repository ).nil?
					lines << "- Branch: #{baseline.fetch( :default_branch )}" unless baseline.fetch( :default_branch ).nil?
					lines << "- Head SHA: #{baseline.fetch( :head_sha )}" unless baseline.fetch( :head_sha ).nil?
					lines << "- Workflow files: #{baseline.fetch( :workflows_total )}"
					lines << "- Check-runs: #{baseline.fetch( :check_runs_total )}"
					lines << "- Failing: #{baseline.fetch( :failing_count )}"
					lines << "- Pending: #{baseline.fetch( :pending_count )}"
					lines << "- No check evidence: #{baseline.fetch( :no_check_evidence )}"
					lines << ""
					lines << "### Baseline Failing"
					if baseline.fetch( :failing ).empty?
						lines << "- none"
					else
						baseline.fetch( :failing ).each { |entry| lines << "- #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (#{entry.fetch( :state )}) #{entry.fetch( :link )}".strip }
					end
					lines << ""
					lines << "### Baseline Pending"
					if baseline.fetch( :pending ).empty?
						lines << "- none"
					else
						baseline.fetch( :pending ).each { |entry| lines << "- #{entry.fetch( :workflow )} / #{entry.fetch( :name )} (#{entry.fetch( :state )}) #{entry.fetch( :link )}".strip }
					end
				end
				lines << ""
				lines.join( "\n" )
			end

			# Evaluates scope integrity using staged paths first, then working-tree paths as fallback.
			def print_scope_integrity_guard
				staged = staged_files
				files = staged.empty? ? changed_files : staged
				files_source = staged.empty? ? "working_tree" : "staged"
				return { status: "ok", split_required: false } if files.empty?

				scope = scope_integrity_status( files: files, branch: current_branch )
				puts_verbose ""
				puts_verbose "[Scope Integrity Guard]"
				puts_verbose "scope_file_source: #{files_source}"
				puts_verbose "scope_file_count: #{files.count}"
				puts_verbose "branch: #{scope.fetch( :branch )}"
				puts_verbose "scope_basis: changed_paths_only"
				puts_verbose "detected_groups: #{scope.fetch( :detected_groups ).sort.join( ', ' )}"
				puts_verbose "core_groups: #{scope.fetch( :core_groups ).empty? ? 'none' : scope.fetch( :core_groups ).sort.join( ', ' )}"
				puts_verbose "non_doc_groups: #{scope.fetch( :non_doc_groups ).empty? ? 'none' : scope.fetch( :non_doc_groups ).sort.join( ', ' )}"
				puts_verbose "docs_only_changes: #{scope.fetch( :docs_only )}"
				puts_verbose "unmatched_paths_count: #{scope.fetch( :unmatched_paths ).count}"
				scope.fetch( :unmatched_paths ).each { |path| puts_verbose "unmatched_path: #{path}" }
				puts_verbose "violating_files_count: #{scope.fetch( :violating_files ).count}"
				scope.fetch( :violating_files ).each { |path| puts_verbose "violating_file: #{path} (group=#{scope.fetch( :grouped_paths ).fetch( path )})" }
				puts_verbose "checklist_single_business_intent: pass"
				puts_verbose "checklist_single_scope_group: #{scope.fetch( :split_required ) ? 'advisory' : 'pass'}"
				puts_verbose "checklist_cross_boundary_changes_justified: #{( scope.fetch( :split_required ) || scope.fetch( :misc_present ) ) ? 'advisory' : 'pass'}"
				if scope.fetch( :split_required )
					puts_verbose "ACTION: multiple module groups detected (informational only)."
				elsif scope.fetch( :misc_present )
					puts_verbose "ACTION: unmatched paths detected; classify via scope.path_groups for stricter module checks."
				else
					puts_verbose "ACTION: scope integrity is within commit policy."
				end
				{ status: scope.fetch( :status ), split_required: scope.fetch( :split_required ) }
			end

			# Evaluates whether changed files stay within one core module group.
			def scope_integrity_status( files:, branch: )
				grouped_paths = files.map { |path| [ path, scope_group_for_path( path: path ) ] }.to_h
				detected_groups = grouped_paths.values.uniq
				non_doc_groups = detected_groups - [ "docs" ]
				# Tests are supporting changes; they may travel with one core module group.
				core_groups = non_doc_groups - [ "test", "misc" ]
				mixed_core_groups = core_groups.length > 1
				misc_present = non_doc_groups.include?( "misc" )
				split_required = mixed_core_groups
				unmatched_paths = files.select { |path| grouped_paths.fetch( path ) == "misc" }
				violating_files = if split_required
					files.select do |path|
						group = grouped_paths.fetch( path )
						next false if [ "docs", "test", "misc" ].include?( group )
						core_groups.include?( group )
					end
				else
					[]
				end
				{
				branch: branch,
				grouped_paths: grouped_paths,
				detected_groups: detected_groups,
				non_doc_groups: non_doc_groups,
				core_groups: core_groups,
				docs_only: non_doc_groups.empty?,
				mixed_core_groups: mixed_core_groups,
				misc_present: misc_present,
				split_required: split_required,
				unmatched_paths: unmatched_paths,
				violating_files: violating_files,
				status: ( split_required || misc_present ) ? "attention" : "ok"
				}
			end

			# Resolves a path to configured scope group; unmatched paths become misc.
			def scope_group_for_path( path: )
				config.path_groups.each do |group, patterns|
					return group if patterns.any? { |pattern| pattern_matches_path?( pattern: pattern, path: path ) }
				end
				"misc"
			end

			# Supports directory-wide /** prefixes and fnmatch for other patterns.
			def pattern_matches_path?( pattern:, path: )
				if pattern.end_with?( "/**" )
					prefix = pattern.delete_suffix( "/**" )
					return path == prefix || path.start_with?( "#{prefix}/" )
				end
				File.fnmatch?( pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH )
			end

			# Uses index-only paths so commit hooks evaluate exactly what is being committed.
			def staged_files
				git_capture!( "diff", "--cached", "--name-only" ).lines.map do |line|
					raw_path = line.to_s.strip
					next if raw_path.empty?
					raw_path.split( " -> " ).last
				end.compact
			end

			# Parses `git status --porcelain` and normalises rename targets.
			def changed_files
				git_capture!( "status", "--porcelain" ).lines.map do |line|
					raw_path = line[ 3.. ].to_s.strip
					next if raw_path.empty?
					raw_path.split( " -> " ).last
				end.compact
			end

			# True when there are no staged/unstaged/untracked file changes.
		end

		include Audit
	end
end
