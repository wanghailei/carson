module Butler
	class Runtime
		module AuditOps
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
					puts_line "ACTION: local #{config.main_branch} is behind #{config.git_remote}/#{config.main_branch} by #{behind_count} commit#{plural_suffix( count: behind_count )}; run butler sync."
					audit_state = "attention" if audit_state == "ok"
				else
					puts_line "main_vs_remote_main_ahead: 0"
					puts_line "main_vs_remote_main_behind: 0"
					puts_line "ACTION: local #{config.main_branch} is in sync with #{config.git_remote}/#{config.main_branch}."
				end
				print_header "PR and Required Checks (gh)"
				monitor_report = pr_and_check_report
				audit_state = "attention" if audit_state == "ok" && monitor_report.fetch( :status ) != "ok"
				scope_guard = print_scope_integrity_guard
				audit_state = "attention" if audit_state == "ok" && scope_guard.fetch( :status ) == "attention"
				write_and_print_pr_monitor_report( report: monitor_report.merge( audit_status: audit_state ) )
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
				lines << "# Butler PR Monitor Report"
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
				lines.join( "\n" )
			end

			# Waits once before polling so asynchronous AI reviewers have time to post feedback.
			def print_scope_integrity_guard
				files = changed_files
				return { status: "ok", split_required: false, unknown_lane: false } if files.empty?

				scope = scope_integrity_status( files: files, branch: current_branch )
				print_header "Scope Integrity Guard"
				puts_line "branch: #{scope.fetch( :branch )}"
				puts_line "branch_lane: #{scope.fetch( :lane ) || 'unknown'}"
				puts_line "primary_group: #{scope.fetch( :primary_group ) || 'unknown'}"
				puts_line "detected_groups: #{scope.fetch( :detected_groups ).sort.join( ', ' )}"
				puts_line "non_doc_groups: #{scope.fetch( :non_doc_groups ).empty? ? 'none' : scope.fetch( :non_doc_groups ).sort.join( ', ' )}"
				puts_line "docs_only_changes: #{scope.fetch( :docs_only )}"
				puts_line "violating_files_count: #{scope.fetch( :violating_files ).count}"
				scope.fetch( :violating_files ).each { |path| puts_line "violating_file: #{path} (group=#{scope.fetch( :grouped_paths ).fetch( path )})" }
				puts_line "checklist_single_business_intent: #{scope.fetch( :split_required ) ? 'needs_review' : 'pass'}"
				puts_line "checklist_single_scope_group: #{( scope.fetch( :mixed_non_doc ) || scope.fetch( :misc_present ) ) ? 'needs_split' : 'pass'}"
				puts_line "checklist_cross_boundary_changes_justified: #{( scope.fetch( :mismatched_lane_scope ) || scope.fetch( :unknown_lane ) ) ? 'needs_explanation' : 'pass'}"
				if scope.fetch( :unknown_lane )
					puts_line "ACTION: branch naming must match #{config.branch_pattern}; supported lanes: #{config.lane_group_map.keys.join( ', ' )}."
					return { status: "attention", split_required: scope.fetch( :split_required ), unknown_lane: true }
				end
				puts_line( scope.fetch( :split_required ) ? "ACTION: split/re-branch is required before commit." : "ACTION: scope integrity is within commit policy." )
				{ status: scope.fetch( :status ), split_required: scope.fetch( :split_required ), unknown_lane: false }
			end

			# Evaluates whether changed files stay within one non-doc scope boundary.
			def scope_integrity_status( files:, branch: )
				lane = branch_lane( branch_name: branch )
				primary_group = config.lane_group_map[ lane ]
				grouped_paths = files.map { |path| [ path, scope_group_for_path( path: path ) ] }.to_h
				detected_groups = grouped_paths.values.uniq
				non_doc_groups = detected_groups - [ "docs" ]
				unknown_lane = lane.nil? || primary_group.nil?
				mixed_non_doc = non_doc_groups.length > 1
				mismatched_lane_scope = !unknown_lane && non_doc_groups.length == 1 && non_doc_groups.first != primary_group
				misc_present = non_doc_groups.include?( "misc" )
				split_required = mixed_non_doc || mismatched_lane_scope || misc_present
				violating_files = files.select do |path|
					group = grouped_paths.fetch( path )
					next true if group == "misc"
					next false if group == "docs"
					next true if unknown_lane || mixed_non_doc
					group != primary_group
				end
				{
				branch: branch,
				lane: lane,
				primary_group: primary_group,
				grouped_paths: grouped_paths,
				detected_groups: detected_groups,
				non_doc_groups: non_doc_groups,
				docs_only: non_doc_groups.empty?,
				unknown_lane: unknown_lane,
				mixed_non_doc: mixed_non_doc,
				mismatched_lane_scope: mismatched_lane_scope,
				misc_present: misc_present,
				split_required: split_required,
				violating_files: violating_files,
				status: ( unknown_lane || split_required ) ? "attention" : "ok"
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

			# Extracts lane from configured branch naming pattern.
			def branch_lane( branch_name: )
				match = config.branch_regex.match( branch_name.to_s )
				return nil if match.nil?
				return match[ "lane" ] if match.names.include?( "lane" )
				match[ 1 ]
			end

			# Parses `git status --porcelain` and normalises rename targets.
			def changed_files
				git_capture!( "status", "--porcelain" ).lines.filter_map do |line|
					raw_path = line[ 3.. ].to_s.strip
					next if raw_path.empty?
					raw_path.split( " -> " ).last
				end
			end

			# True when there are no staged/unstaged/untracked file changes.
		end

		include AuditOps
	end
end
