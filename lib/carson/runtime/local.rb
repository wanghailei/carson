module Carson
	class Runtime
		module Local
			def sync!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless working_tree_clean?
					puts_line "BLOCK: working tree is dirty; commit/stash first, then run carson sync."
					return EXIT_BLOCK
				end
				start_branch = current_branch
				switched = false
				git_system!( "fetch", config.git_remote, "--prune" )
				if start_branch != config.main_branch
					git_system!( "switch", config.main_branch )
					switched = true
				end
				git_system!( "pull", "--ff-only", config.git_remote, config.main_branch )
				ahead_count, behind_count, error_text = main_sync_counts
				if error_text
					puts_line "BLOCK: unable to verify main sync state (#{error_text})."
					return EXIT_BLOCK
				end
				if ahead_count.zero? && behind_count.zero?
					puts_line "OK: local #{config.main_branch} is now in sync with #{config.git_remote}/#{config.main_branch}."
					return EXIT_OK
				end
				puts_line "BLOCK: local #{config.main_branch} still diverges (ahead=#{ahead_count}, behind=#{behind_count})."
				EXIT_BLOCK
			ensure
				git_system!( "switch", start_branch ) if switched && branch_exists?( branch_name: start_branch )
			end

			# Removes stale local branches that track remote refs already deleted upstream.
			def prune!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				git_system!( "fetch", config.git_remote, "--prune" )
				active_branch = current_branch
				stale_branches = stale_local_branches
				return prune_no_stale_branches if stale_branches.empty?

				counters = prune_stale_branch_entries( stale_branches: stale_branches, active_branch: active_branch )
				puts_line "prune_summary: deleted=#{counters.fetch( :deleted )} skipped=#{counters.fetch( :skipped )}"
				EXIT_OK
			end

			def prune_no_stale_branches
				puts_line "OK: no stale local branches tracking deleted #{config.git_remote} branches."
				EXIT_OK
			end

			def prune_stale_branch_entries( stale_branches:, active_branch: )
				counters = { deleted: 0, skipped: 0 }
				stale_branches.each do |entry|
					outcome = prune_stale_branch_entry( entry: entry, active_branch: active_branch )
					counters[ outcome ] += 1
				end
				counters
			end

			def prune_stale_branch_entry( entry:, active_branch: )
				branch = entry.fetch( :branch )
				upstream = entry.fetch( :upstream )
				return prune_skip_stale_branch( type: :protected, branch: branch, upstream: upstream ) if config.protected_branches.include?( branch )
				return prune_skip_stale_branch( type: :current, branch: branch, upstream: upstream ) if branch == active_branch

				prune_delete_stale_branch( branch: branch, upstream: upstream )
			end

			def prune_skip_stale_branch( type:, branch:, upstream: )
				status = type == :protected ? "skip_protected_branch" : "skip_current_branch"
				puts_line "#{status}: #{branch} (upstream=#{upstream})"
				:skipped
			end

			def prune_delete_stale_branch( branch:, upstream: )
				stdout_text, stderr_text, success, = git_run( "branch", "-d", branch )
				return prune_safe_delete_success( branch: branch, upstream: upstream, stdout_text: stdout_text ) if success

				delete_error_text = normalise_branch_delete_error( error_text: stderr_text )
				prune_force_delete_stale_branch(
					branch: branch,
					upstream: upstream,
					delete_error_text: delete_error_text
				)
			end

			def prune_safe_delete_success( branch:, upstream:, stdout_text: )
				out.print stdout_text unless stdout_text.empty?
				puts_line "deleted_local_branch: #{branch} (upstream=#{upstream})"
				:deleted
			end

			def prune_force_delete_stale_branch( branch:, upstream:, delete_error_text: )
				merged_pr, force_error = force_delete_evidence_for_stale_branch(
					branch: branch,
					delete_error_text: delete_error_text
				)
				return prune_force_delete_skipped( branch: branch, upstream: upstream, delete_error_text: delete_error_text, force_error: force_error ) if merged_pr.nil?

				force_stdout, force_stderr, force_success, = git_run( "branch", "-D", branch )
				return prune_force_delete_success( branch: branch, upstream: upstream, merged_pr: merged_pr, force_stdout: force_stdout ) if force_success

				prune_force_delete_failed( branch: branch, upstream: upstream, force_stderr: force_stderr )
			end

			def prune_force_delete_success( branch:, upstream:, merged_pr:, force_stdout: )
				out.print force_stdout unless force_stdout.empty?
				puts_line "deleted_local_branch_force: #{branch} (upstream=#{upstream}) merged_pr=#{merged_pr.fetch( :url )}"
				:deleted
			end

			def prune_force_delete_failed( branch:, upstream:, force_stderr: )
				force_error_text = normalise_branch_delete_error( error_text: force_stderr )
				puts_line "fail_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error_text}"
				:skipped
			end

			def prune_force_delete_skipped( branch:, upstream:, delete_error_text:, force_error: )
				puts_line "skip_delete_branch: #{branch} (upstream=#{upstream}) reason=#{delete_error_text}"
				puts_line "skip_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error}" unless force_error.to_s.strip.empty?
				:skipped
			end

			def normalise_branch_delete_error( error_text: )
				text = error_text.to_s.strip
				text.empty? ? "unknown error" : text
			end

			# Installs required hook files and enforces repository hook path.
			def hook!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				FileUtils.mkdir_p( hooks_dir )
				missing_templates = config.required_hooks.reject { |name| File.file?( hook_template_path( hook_name: name ) ) }
				unless missing_templates.empty?
					puts_line "BLOCK: missing hook templates in Carson: #{missing_templates.join( ', ' )}."
					return EXIT_BLOCK
				end

				symlinked = symlink_hook_files
				unless symlinked.empty?
					puts_line "BLOCK: symlink hook files are not allowed: #{symlinked.join( ', ' )}."
					return EXIT_BLOCK
				end

				config.required_hooks.each do |hook_name|
					source_path = hook_template_path( hook_name: hook_name )
					target_path = File.join( hooks_dir, hook_name )
					FileUtils.cp( source_path, target_path )
					FileUtils.chmod( 0o755, target_path )
					puts_line "hook_written: #{relative_path( target_path )}"
				end
				git_system!( "config", "core.hooksPath", hooks_dir )
				puts_line "configured_hooks_path: #{hooks_dir}"
				check!
			end

			# One-command initialisation for new repositories: align remote naming, install hooks,
			# apply templates, and produce a first audit report.
			def init!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				print_header "Init"
				unless inside_git_work_tree?
					puts_line "ERROR: #{repo_root} is not a git repository."
					return EXIT_ERROR
				end
				align_remote_name_for_carson!
				hook_status = hook!
				return hook_status unless hook_status == EXIT_OK

				template_status = template_apply!
				return template_status unless template_status == EXIT_OK

				audit_status = audit!
				if audit_status == EXIT_OK
					puts_line "OK: Carson initialisation completed for #{repo_root}."
				elsif audit_status == EXIT_BLOCK
					puts_line "BLOCK: Carson initialisation completed with policy blocks; resolve and rerun carson audit."
				end
				audit_status
			end

			# Removes Carson-managed repository integration so a host repository can retire Carson cleanly.
			def offboard!
				print_header "Offboard"
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
						puts_line "removed_path: #{relative}"
						removed_count += 1
					else
						puts_line "skip_missing_path: #{relative}"
						missing_count += 1
					end
				end
				remove_empty_offboard_directories!
				puts_line "offboard_summary: removed=#{removed_count} missing=#{missing_count}"
				puts_line "OK: Carson offboard completed for #{repo_root}."
				EXIT_OK
			end

			# Strict hook health check used by humans, hooks, and CI paths.
			def check!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				print_header "Hooks Check"
				ok = hooks_health_report( strict: true )
				puts_line( ok ? "status: ok" : "status: block" )
				ok ? EXIT_OK : EXIT_BLOCK
			end

			# Read-only template drift check; returns block when managed files are out of sync.
			def template_check!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				print_header "Template Sync Check"
				results = template_results
				drift_count = results.count { |entry| entry.fetch( :status ) == "drift" }
				error_count = results.count { |entry| entry.fetch( :status ) == "error" }
				results.each do |entry|
					puts_line "template_file: #{entry.fetch( :file )} status=#{entry.fetch( :status )} reason=#{entry.fetch( :reason )}"
				end
				puts_line "template_summary: total=#{results.count} drift=#{drift_count} error=#{error_count}"
				return EXIT_ERROR if error_count.positive?

				drift_count.positive? ? EXIT_BLOCK : EXIT_OK
			end

			# Applies managed template files as full-file writes from Carson sources.
			def template_apply!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				print_header "Template Sync Apply"
				results = template_results
				applied = 0
				results.each do |entry|
					if entry.fetch( :status ) == "error"
						puts_line "template_file: #{entry.fetch( :file )} status=error reason=#{entry.fetch( :reason )}"
						next
					end

					file_path = File.join( repo_root, entry.fetch( :file ) )
					if entry.fetch( :status ) == "ok"
						puts_line "template_file: #{entry.fetch( :file )} status=ok reason=in_sync"
						next
					end

					FileUtils.mkdir_p( File.dirname( file_path ) )
					File.write( file_path, entry.fetch( :applied_content ) )
					puts_line "template_file: #{entry.fetch( :file )} status=updated reason=#{entry.fetch( :reason )}"
					applied += 1
				end

				error_count = results.count { |entry| entry.fetch( :status ) == "error" }
				puts_line "template_apply_summary: updated=#{applied} error=#{error_count}"
				error_count.positive? ? EXIT_ERROR : EXIT_OK
			end

			private

			def template_results
				config.template_managed_files.map { |managed_file| template_result_for_file( managed_file: managed_file ) }
			end

			# Calculates whole-file expected content and returns sync status plus apply payload.
			def template_result_for_file( managed_file: )
				template_path = File.join( github_templates_dir, File.basename( managed_file ) )
				return { file: managed_file, status: "error", reason: "missing template #{File.basename( managed_file )}", applied_content: nil } unless File.file?( template_path )

				expected_content = normalize_text( text: File.read( template_path ) )
				file_path = resolve_repo_path!( relative_path: managed_file, label: "template.managed_files entry #{managed_file}" )
				return { file: managed_file, status: "drift", reason: "missing_file", applied_content: expected_content } unless File.file?( file_path )

				current_content = normalize_text( text: File.read( file_path ) )
				return { file: managed_file, status: "ok", reason: "in_sync", applied_content: current_content } if current_content == expected_content

				{ file: managed_file, status: "drift", reason: "content_mismatch", applied_content: expected_content }
			end

			# Uses LF-only normalisation so platform newlines do not cause false drift.
			def normalize_text( text: )
				"#{text.to_s.gsub( "\r\n", "\n" ).rstrip}\n"
			end

			# GitHub managed template source directory inside Carson repository.
			def github_templates_dir
				File.join( tool_root, "templates", ".github" )
			end

			# Canonical hook template location inside Carson repository.
			def hook_template_path( hook_name: )
				File.join( tool_root, "assets", "hooks", hook_name )
			end

			# Reports full hook health and can enforce stricter action messaging in `check`.
			def hooks_health_report( strict: false )
				configured = configured_hooks_path
				expected = hooks_dir
				hooks_path_ok = print_hooks_path_status( configured: configured, expected: expected )
				print_required_hook_status
				hooks_integrity = hook_integrity_state
				hooks_ok = hooks_integrity_ok?( hooks_integrity: hooks_integrity )
				print_hook_action(
					strict: strict,
					hooks_ok: hooks_path_ok && hooks_ok,
					hooks_path_ok: hooks_path_ok,
					configured: configured,
					expected: expected
				)
				hooks_path_ok && hooks_ok
			end

			def print_hooks_path_status( configured:, expected: )
				configured_abs = configured.nil? ? nil : File.expand_path( configured )
				hooks_path_ok = configured_abs == expected
				puts_line "hooks_path: #{configured || '(unset)'}"
				puts_line "hooks_path_expected: #{expected}"
				puts_line( hooks_path_ok ? "hooks_path_status: ok" : "hooks_path_status: attention" )
				hooks_path_ok
			end

			def print_required_hook_status
				required_hook_paths.each do |path|
					exists = File.file?( path )
					symlink = File.symlink?( path )
					executable = exists && !symlink && File.executable?( path )
					puts_line "hook_file: #{relative_path( path )} exists=#{exists} symlink=#{symlink} executable=#{executable}"
				end
			end

			def hook_integrity_state
				{
					missing: missing_hook_files,
					non_executable: non_executable_hook_files,
					symlinked: symlink_hook_files
				}
			end

			def hooks_integrity_ok?( hooks_integrity: )
				missing_ok = hooks_integrity.fetch( :missing ).empty?
				non_executable_ok = hooks_integrity.fetch( :non_executable ).empty?
				symlinked_ok = hooks_integrity.fetch( :symlinked ).empty?
				missing_ok && non_executable_ok && symlinked_ok
			end

			def print_hook_action( strict:, hooks_ok:, hooks_path_ok:, configured:, expected: )
				return if hooks_ok

				if strict && !hooks_path_ok
					configured_text = configured.to_s.strip
					if configured_text.empty?
						puts_line "ACTION: hooks path is unset (expected=#{expected})."
					else
						puts_line "ACTION: hooks path mismatch (configured=#{configured_text}, expected=#{expected})."
					end
				end
				message = strict ? "ACTION: run carson hook to align hooks with Carson #{Carson::VERSION}." : "ACTION: run carson hook to enforce local main protections."
				puts_line message
			end

			# Returns ahead/behind counts for local main versus configured remote main.
			def main_sync_counts
				target = "#{config.main_branch}...#{config.git_remote}/#{config.main_branch}"
				stdout_text, stderr_text, success, = git_run( "rev-list", "--left-right", "--count", target )
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "git rev-list failed" if error_text.empty?
					return [ 0, 0, error_text ]
				end
				counts = stdout_text.to_s.strip.split( /\s+/ )
				return [ 0, 0, "unexpected rev-list output: #{stdout_text.to_s.strip}" ] if counts.length < 2

				[ counts[ 0 ].to_i, counts[ 1 ].to_i, nil ]
			end

			# Reads configured core.hooksPath and normalises empty values to nil.
			def configured_hooks_path
				stdout_text, = git_capture_soft( "config", "--get", "core.hooksPath" )
				value = stdout_text.to_s.strip
				value.empty? ? nil : value
			end

			# Fully-qualified required hook file locations in the target repository.
			def required_hook_paths
				config.required_hooks.map { |name| File.join( hooks_dir, name ) }
			end

			# Missing required hook files.
			def missing_hook_files
				required_hook_paths.reject { |path| File.file?( path ) }.map { |path| relative_path( path ) }
			end

			# Required hook files that exist but are not executable.
			def non_executable_hook_files
				required_hook_paths.select { |path| File.file?( path ) && !File.executable?( path ) }.map { |path| relative_path( path ) }
			end

			# Symlink hooks are disallowed to prevent bypassing managed hook content.
			def symlink_hook_files
				required_hook_paths.select { |path| File.symlink?( path ) }.map { |path| relative_path( path ) }
			end

			# Local directory where managed hooks are installed.
			def hooks_dir
				File.expand_path( File.join( config.hooks_base_path, Carson::VERSION ) )
			end

			# In outsider mode, Carson must not leave Carson-owned fingerprints in host repositories.
			def block_if_outsider_fingerprints!
				return nil unless outsider_mode?

				violations = outsider_fingerprint_violations
				return nil if violations.empty?

				violations.each { |entry| puts_line "BLOCK: #{entry}" }
				EXIT_BLOCK
			end

			# Carson source repository itself is excluded from host-repository fingerprint checks.
			def outsider_mode?
				File.expand_path( repo_root ) != File.expand_path( tool_root )
			end

			# Detects Carson-owned host artefacts that violate outsider boundary.
			def outsider_fingerprint_violations
				violations = []
				violations << "forbidden file .carson.yml detected" if File.file?( File.join( repo_root, ".carson.yml" ) )
				violations << "forbidden file bin/carson detected" if File.file?( File.join( repo_root, "bin", "carson" ) )
				violations << "forbidden directory .tools/carson detected" if Dir.exist?( File.join( repo_root, ".tools", "carson" ) )
				violations
			end

			# NOTE: prune only targets local branches that meet both conditions:
			# 1) branch tracks configured remote (`github/*` by default), and
			# 2) upstream tracking state is marked as gone after fetch --prune.
			# Branches without upstream tracking are intentionally excluded.
			def stale_local_branches
				git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" ).lines.map do |line|
					branch, upstream, track = line.strip.split( "\t", 3 )
					upstream = upstream.to_s
					track = track.to_s
					next if branch.to_s.empty? || upstream.empty?
					next unless upstream.start_with?( "#{config.git_remote}/" ) && track.include?( "gone" )

					{ branch: branch, upstream: upstream, track: track }
				end.compact
			end

			# Safe delete can fail after squash merges because branch tip is no longer an ancestor.
			def non_merged_delete_error?( error_text: )
				error_text.to_s.downcase.include?( "not fully merged" )
			end

				# Guarded force-delete policy for stale branches:
				# 1) safe delete failure must be merge-related (`not fully merged`),
				# 2) gh must confirm at least one merged PR for this exact branch into configured main.
				def force_delete_evidence_for_stale_branch( branch:, delete_error_text: )
					return [ nil, "safe delete failure is not merge-related" ] unless non_merged_delete_error?( error_text: delete_error_text )
					return [ nil, "gh CLI not available; cannot verify merged PR evidence" ] unless gh_available?

					tip_sha_text, tip_sha_error, tip_sha_success, = git_run( "rev-parse", "--verify", branch.to_s )
					unless tip_sha_success
						error_text = tip_sha_error.to_s.strip
						error_text = "unable to read local branch tip sha" if error_text.empty?
						return [ nil, error_text ]
					end
					branch_tip_sha = tip_sha_text.to_s.strip
					return [ nil, "unable to read local branch tip sha" ] if branch_tip_sha.empty?

					merged_pr_for_branch( branch: branch, branch_tip_sha: branch_tip_sha )
				end

			# Finds merged PR evidence for the exact local branch tip; this blocks old-PR false positives.
			def merged_pr_for_branch( branch:, branch_tip_sha: )
				owner, repo = repository_coordinates
				results = []
				page = 1
				loop do
					stdout_text, stderr_text, success, = gh_run(
					"api", "repos/#{owner}/#{repo}/pulls",
					"--method", "GET",
					"-f", "state=closed",
					"-f", "base=#{config.main_branch}",
					"-f", "head=#{owner}:#{branch}",
					"-f", "sort=updated",
					"-f", "direction=desc",
					"-f", "per_page=100",
					"-f", "page=#{page}"
					)
					unless success
						error_text = gh_error_text( stdout_text: stdout_text, stderr_text: stderr_text, fallback: "unable to query merged PR evidence for branch #{branch}" )
						return [ nil, error_text ]
					end
					page_nodes = Array( JSON.parse( stdout_text ) )
					break if page_nodes.empty?

					page_nodes.each do |entry|
						next unless entry.dig( "head", "ref" ).to_s == branch.to_s
						next unless entry.dig( "base", "ref" ).to_s == config.main_branch
						next unless entry.dig( "head", "sha" ).to_s == branch_tip_sha

						merged_at = parse_time_or_nil( text: entry[ "merged_at" ] )
						next if merged_at.nil?

						results << {
						number: entry[ "number" ],
						url: entry[ "html_url" ].to_s,
						merged_at: merged_at.utc.iso8601,
						head_sha: entry.dig( "head", "sha" ).to_s
						}
					end
					page += 1
				end
				latest = results.max_by { |item| item.fetch( :merged_at ) }
				return [ nil, "no merged PR evidence for branch tip #{branch_tip_sha} into #{config.main_branch}" ] if latest.nil?

				[ latest, nil ]
			rescue JSON::ParserError => e
				[ nil, "invalid gh JSON response (#{e.message})" ]
			rescue StandardError => e
				[ nil, e.message ]
			end

			# Thin `gh` monitor for PR and required checks; local audit continues on API gaps.
			def working_tree_clean?
				git_capture!( "status", "--porcelain" ).strip.empty?
			end

			def inside_git_work_tree?
				stdout_text, = git_capture_soft( "rev-parse", "--is-inside-work-tree" )
				stdout_text.to_s.strip == "true"
			end

			def disable_carson_hooks_path!
				configured = configured_hooks_path
				if configured.nil?
					puts_line "hooks_path: (unset)"
					return EXIT_OK
				end
				puts_line "hooks_path: #{configured}"
				configured_abs = File.expand_path( configured, repo_root )
				unless carson_managed_hooks_path?( configured_abs: configured_abs )
					puts_line "hooks_path_kept: #{configured} (not Carson-managed)"
					return EXIT_OK
				end
				git_system!( "config", "--unset", "core.hooksPath" )
				puts_line "hooks_path_unset: core.hooksPath"
				EXIT_OK
			rescue StandardError => e
				puts_line "ERROR: unable to update core.hooksPath (#{e.message})"
				EXIT_ERROR
			end

			def carson_managed_hooks_path?( configured_abs: )
				hooks_root = File.join( File.expand_path( config.hooks_base_path ), "" )
				return true if configured_abs.start_with?( hooks_root )

				carson_hook_files_match_templates?( hooks_path: configured_abs )
			end

			def carson_hook_files_match_templates?( hooks_path: )
				return false unless Dir.exist?( hooks_path )
				config.required_hooks.all? do |hook_name|
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
				( config.template_managed_files + [
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
					puts_line "removed_empty_dir: #{relative}"
				end
			end

			# Ensures Carson expected remote naming (`github`) while keeping existing
			# repositories safe when neither `github` nor `origin` exists.
			def align_remote_name_for_carson!
				if git_remote_exists?( remote_name: config.git_remote )
					puts_line "remote_ok: #{config.git_remote}"
					return
				end
				if git_remote_exists?( remote_name: "origin" )
					git_system!( "remote", "rename", "origin", config.git_remote )
					puts_line "remote_renamed: origin -> #{config.git_remote}"
					return
				end
				puts_line "WARN: no #{config.git_remote} or origin remote configured; continue with local baseline only."
			end

			# Uses `git remote get-url` as existence check to avoid parsing remote lists.
			def git_remote_exists?( remote_name: )
				_, _, success, = git_run( "remote", "get-url", remote_name.to_s )
				success
			end
		end

		include Local
	end
end
