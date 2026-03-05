require "cgi"

module Carson
	class Runtime
		module Audit
			def audit!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?
				unless head_exists?
					puts_line "No commits yet — audit skipped for initial commit."
					return EXIT_OK
				end
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
					audit_concise_problems << "Hooks: mismatch — run carson refresh."
				end
				puts_verbose ""
				puts_verbose "[Main Sync Status]"
				ahead_count, behind_count, main_error = main_sync_counts
				if main_error
					puts_verbose "main_vs_remote_main: unknown"
					puts_verbose "WARN: unable to calculate main sync status (#{main_error})."
					audit_state = "attention" if audit_state == "ok"
					audit_concise_problems << "Main sync: unable to determine — check remote connectivity."
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
				if monitor_report.fetch( :status ) == "skipped"
					audit_concise_problems << "Checks: skipped (#{monitor_report.fetch( :skip_reason )})."
				elsif monitor_report.fetch( :status ) == "attention"
					checks = monitor_report.fetch( :checks )
					fail_n = checks.fetch( :failing_count )
					pend_n = checks.fetch( :pending_count )
					total = checks.fetch( :required_total )
					if fail_n.positive? && pend_n.positive?
						audit_concise_problems << "Checks: #{fail_n} failing, #{pend_n} pending of #{total} required."
					elsif fail_n.positive?
						audit_concise_problems << "Checks: #{fail_n} of #{total} failing."
					elsif pend_n.positive?
						audit_concise_problems << "Checks: pending (#{total - pend_n} of #{total} complete)."
					elsif checks.fetch( :status ) == "skipped"
						audit_concise_problems << "Checks: skipped (#{checks.fetch( :skip_reason )})."
					end
				end
				puts_verbose ""
				puts_verbose "[Default Branch CI Baseline (gh)]"
				default_branch_baseline = default_branch_ci_baseline_report
				audit_state = "block" if default_branch_baseline.fetch( :status ) == "block"
				audit_state = "attention" if audit_state == "ok" && default_branch_baseline.fetch( :status ) != "ok"
				baseline_st = default_branch_baseline.fetch( :status )
				if baseline_st == "block"
					parts = []
					parts << "#{default_branch_baseline.fetch( :failing_count )} failing" if default_branch_baseline.fetch( :failing_count ).positive?
					parts << "#{default_branch_baseline.fetch( :pending_count )} pending" if default_branch_baseline.fetch( :pending_count ).positive?
					parts << "no check-runs for active workflows" if default_branch_baseline.fetch( :no_check_evidence )
					audit_concise_problems << "Baseline (#{default_branch_baseline.fetch( :default_branch, config.main_branch )}): #{parts.join( ', ' )} — merge blocked."
				elsif baseline_st == "attention"
					parts = []
					parts << "#{default_branch_baseline.fetch( :advisory_failing_count )} advisory failing" if default_branch_baseline.fetch( :advisory_failing_count ).positive?
					parts << "#{default_branch_baseline.fetch( :advisory_pending_count )} advisory pending" if default_branch_baseline.fetch( :advisory_pending_count ).positive?
					audit_concise_problems << "Baseline (#{default_branch_baseline.fetch( :default_branch, config.main_branch )}): #{parts.join( ', ' )}."
				elsif baseline_st == "skipped"
					audit_concise_problems << "Baseline: skipped (#{default_branch_baseline.fetch( :skip_reason )})."
				end
				if config.template_canonical.nil? || config.template_canonical.to_s.empty?
					puts_verbose ""
					puts_verbose "[Canonical Templates]"
					puts_verbose "HINT: canonical templates not configured — run carson setup to enable."
					audit_concise_problems << "Hint: canonical templates not configured — run carson setup to enable."
				end
					write_and_print_pr_monitor_report(
						report: monitor_report.merge(
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
				pending = checks_data.select { |entry| entry[ "bucket" ].to_s == "pending" }
				failing = checks_data.select { |entry| check_entry_failing?( entry: entry ) }
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

			# Returns true when a required-check entry is in a non-passing, non-pending state.
			# Cancelled, errored, timed-out, and any unknown bucket all count as failing.
			def check_entry_failing?( entry: )
				!%w[pass pending].include?( entry[ "bucket" ].to_s )
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

			# True when there are no staged/unstaged/untracked file changes.
		end

		include Audit
	end
end
