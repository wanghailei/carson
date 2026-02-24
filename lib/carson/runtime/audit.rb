require "cgi"

module Carson
	class Runtime
		module Audit
			def audit!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				audit_state = "ok"
				print_header "Repository"
				puts_line "root: #{repo_root}"
				puts_line "current_branch: #{current_branch}"
				print_header "Working Tree"
				puts_line git_capture!( "status", "--short", "--branch" ).strip
				print_header "Hooks"
				hooks_ok = hooks_health_report
				audit_state = "block" unless hooks_ok
				print_header "Main Sync Status"
				ahead_count, behind_count, main_error = main_sync_counts
				if main_error
					puts_line "main_vs_remote_main: unknown"
					puts_line "WARN: unable to calculate main sync status (#{main_error})."
					audit_state = "attention" if audit_state == "ok"
				elsif ahead_count.positive?
					puts_line "main_vs_remote_main_ahead: #{ahead_count}"
					puts_line "main_vs_remote_main_behind: #{behind_count}"
					puts_line "ACTION: local #{config.main_branch} is ahead of #{config.git_remote}/#{config.main_branch} by #{ahead_count} commit#{plural_suffix( count: ahead_count )}; reset local drift before commit/push workflows."
					audit_state = "block"
				elsif behind_count.positive?
					puts_line "main_vs_remote_main_ahead: #{ahead_count}"
					puts_line "main_vs_remote_main_behind: #{behind_count}"
					puts_line "ACTION: local #{config.main_branch} is behind #{config.git_remote}/#{config.main_branch} by #{behind_count} commit#{plural_suffix( count: behind_count )}; run carson sync."
					audit_state = "attention" if audit_state == "ok"
				else
					puts_line "main_vs_remote_main_ahead: 0"
					puts_line "main_vs_remote_main_behind: 0"
					puts_line "ACTION: local #{config.main_branch} is in sync with #{config.git_remote}/#{config.main_branch}."
				end
				print_header "PR and Required Checks (gh)"
				monitor_report = pr_and_check_report
				audit_state = "attention" if audit_state == "ok" && monitor_report.fetch( :status ) != "ok"
				print_header "Default Branch CI Baseline (gh)"
				default_branch_baseline = default_branch_ci_baseline_report
				audit_state = "block" if default_branch_baseline.fetch( :status ) == "block"
				audit_state = "attention" if audit_state == "ok" && default_branch_baseline.fetch( :status ) != "ok"
				scope_guard = print_scope_integrity_guard
				audit_state = "block" if scope_guard.fetch( :split_required )
				audit_state = "attention" if audit_state == "ok" && scope_guard.fetch( :status ) == "attention"
				write_and_print_pr_monitor_report(
					report: monitor_report.merge(
						default_branch_baseline: default_branch_baseline,
						audit_status: audit_state
					)
				)
				print_header "Audit Result"
				puts_line "status: #{audit_state}"
				puts_line( audit_state == "block" ? "ACTION: local policy block must be resolved before commit/push." : "ACTION: no local hard block detected." )
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
					puts_line "SKIP: #{report.fetch( :skip_reason )}"
					return report
				end
				pr_stdout, pr_stderr, pr_success, = gh_run( "pr", "view", current_branch, "--json", "number,title,url,state,reviewDecision" )
				unless pr_success
					error_text = gh_error_text( stdout_text: pr_stdout, stderr_text: pr_stderr, fallback: "unable to read PR for branch #{current_branch}" )
					report[ :status ] = "skipped"
					report[ :skip_reason ] = error_text
					puts_line "SKIP: #{error_text}"
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
				puts_line "pr: ##{report.dig( :pr, :number )} #{report.dig( :pr, :title )}"
				puts_line "url: #{report.dig( :pr, :url )}"
				puts_line "review_decision: #{report.dig( :pr, :review_decision )}"
				checks_stdout, checks_stderr, checks_success, checks_exit = gh_run( "pr", "checks", report.dig( :pr, :number ).to_s, "--required", "--json", "name,state,bucket,workflow,link" )
				if checks_stdout.to_s.strip.empty?
					error_text = gh_error_text( stdout_text: checks_stdout, stderr_text: checks_stderr, fallback: "required checks unavailable" )
					report[ :checks ][ :status ] = "skipped"
					report[ :checks ][ :skip_reason ] = error_text
					report[ :status ] = "attention"
					puts_line "checks: SKIP (#{error_text})"
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
				puts_line "required_checks_total: #{report.dig( :checks, :required_total )}"
				puts_line "required_checks_failing: #{report.dig( :checks, :failing_count )}"
				puts_line "required_checks_pending: #{report.dig( :checks, :pending_count )}"
				report.dig( :checks, :failing ).each { |entry| puts_line "check_fail: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report.dig( :checks, :pending ).each { |entry| puts_line "check_pending: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report[ :status ] = "attention" if report.dig( :checks, :failing_count ).positive? || report.dig( :checks, :pending_count ).positive?
				report
				rescue JSON::ParserError => e
					report[ :status ] = "skipped"
					report[ :skip_reason ] = "invalid gh JSON response (#{e.message})"
					puts_line "SKIP: #{report.fetch( :skip_reason )}"
					report
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
				no_check_evidence: false,
				failing: [],
				pending: []
				}
				unless gh_available?
					report[ :status ] = "skipped"
					report[ :skip_reason ] = "gh CLI not available in PATH"
					puts_line "baseline: SKIP (#{report.fetch( :skip_reason )})"
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
				report[ :check_runs_total ] = check_runs.count
				report[ :failing ] = normalise_default_branch_check_entries( entries: failing )
				report[ :pending ] = normalise_default_branch_check_entries( entries: pending )
				report[ :failing_count ] = report.fetch( :failing ).count
				report[ :pending_count ] = report.fetch( :pending ).count
				report[ :no_check_evidence ] = report.fetch( :workflows_total ).positive? && report.fetch( :check_runs_total ).zero?
				report[ :status ] = "block" if report.fetch( :failing_count ).positive?
				report[ :status ] = "block" if report.fetch( :pending_count ).positive?
				report[ :status ] = "block" if report.fetch( :no_check_evidence )
				puts_line "default_branch_repository: #{report.fetch( :repository )}"
				puts_line "default_branch_name: #{report.fetch( :default_branch )}"
				puts_line "default_branch_head_sha: #{report.fetch( :head_sha )}"
				puts_line "default_branch_workflows_total: #{report.fetch( :workflows_total )}"
				puts_line "default_branch_check_runs_total: #{report.fetch( :check_runs_total )}"
				puts_line "default_branch_failing: #{report.fetch( :failing_count )}"
				puts_line "default_branch_pending: #{report.fetch( :pending_count )}"
				report.fetch( :failing ).each { |entry| puts_line "default_branch_check_fail: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				report.fetch( :pending ).each { |entry| puts_line "default_branch_check_pending: #{entry.fetch( :workflow )} / #{entry.fetch( :name )} #{entry.fetch( :link )}".strip }
				if report.fetch( :no_check_evidence )
					puts_line "ACTION: default branch has workflow files but no check-runs; align workflow triggers and branch protection check names."
				end
				report
			rescue JSON::ParserError => e
				report[ :status ] = "skipped"
				report[ :skip_reason ] = "invalid gh JSON response (#{e.message})"
				puts_line "baseline: SKIP (#{report.fetch( :skip_reason )})"
				report
			rescue StandardError => e
				report[ :status ] = "skipped"
				report[ :skip_reason ] = e.message
				puts_line "baseline: SKIP (#{report.fetch( :skip_reason )})"
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
				puts_line "report_markdown: #{markdown_path}"
				puts_line "report_json: #{json_path}"
			rescue StandardError => e
				puts_line "report_write: SKIP (#{e.message})"
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
				print_header "Scope Integrity Guard"
				puts_line "scope_file_source: #{files_source}"
				puts_line "scope_file_count: #{files.count}"
				puts_line "branch: #{scope.fetch( :branch )}"
				puts_line "scope_basis: changed_paths_only"
				puts_line "detected_groups: #{scope.fetch( :detected_groups ).sort.join( ', ' )}"
				puts_line "core_groups: #{scope.fetch( :core_groups ).empty? ? 'none' : scope.fetch( :core_groups ).sort.join( ', ' )}"
				puts_line "non_doc_groups: #{scope.fetch( :non_doc_groups ).empty? ? 'none' : scope.fetch( :non_doc_groups ).sort.join( ', ' )}"
				puts_line "docs_only_changes: #{scope.fetch( :docs_only )}"
				puts_line "unmatched_paths_count: #{scope.fetch( :unmatched_paths ).count}"
				scope.fetch( :unmatched_paths ).each { |path| puts_line "unmatched_path: #{path}" }
				puts_line "violating_files_count: #{scope.fetch( :violating_files ).count}"
				scope.fetch( :violating_files ).each { |path| puts_line "violating_file: #{path} (group=#{scope.fetch( :grouped_paths ).fetch( path )})" }
				puts_line "checklist_single_business_intent: #{scope.fetch( :split_required ) ? 'needs_review' : 'pass'}"
				puts_line "checklist_single_scope_group: #{scope.fetch( :split_required ) ? 'needs_split' : 'pass'}"
				puts_line "checklist_cross_boundary_changes_justified: #{( scope.fetch( :split_required ) || scope.fetch( :misc_present ) ) ? 'needs_explanation' : 'pass'}"
				if scope.fetch( :split_required )
					puts_line "ACTION: split/re-branch is required before commit; multiple module groups detected."
				elsif scope.fetch( :misc_present )
					puts_line "ACTION: unmatched paths detected; classify via scope.path_groups for stricter module checks."
				else
					puts_line "ACTION: scope integrity is within commit policy."
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
