module Butler
	class Runtime
		module LocalOps
			def sync!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				unless working_tree_clean?
					puts_line "BLOCK: working tree is dirty; commit/stash first, then run butler sync."
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
				if stale_branches.empty?
					puts_line "OK: no stale local branches tracking deleted #{config.git_remote} branches."
					return EXIT_OK
				end
				deleted_count = 0
				skipped_count = 0
				stale_branches.each do |entry|
					branch = entry.fetch( :branch )
					upstream = entry.fetch( :upstream )
					if config.protected_branches.include?( branch )
						puts_line "skip_protected_branch: #{branch} (upstream=#{upstream})"
						skipped_count += 1
						next
					end
					if branch == active_branch
						puts_line "skip_current_branch: #{branch} (upstream=#{upstream})"
						skipped_count += 1
						next
					end
					stdout_text, stderr_text, success, = git_run( "branch", "-d", branch )
					if success
						out.print stdout_text unless stdout_text.empty?
						puts_line "deleted_local_branch: #{branch} (upstream=#{upstream})"
						deleted_count += 1
						next
					end
					error_text = stderr_text.to_s.strip
					error_text = "unknown error" if error_text.empty?
					merged_pr, force_error = force_delete_evidence_for_stale_branch(
					branch: branch,
					delete_error_text: error_text
					)
					unless merged_pr.nil?
						force_stdout, force_stderr, force_success, = git_run( "branch", "-D", branch )
						if force_success
							out.print force_stdout unless force_stdout.empty?
							puts_line "deleted_local_branch_force: #{branch} (upstream=#{upstream}) merged_pr=#{merged_pr.fetch( :url )}"
							deleted_count += 1
							next
						end
						force_text = force_stderr.to_s.strip
						force_text = "unknown error" if force_text.empty?
						puts_line "fail_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_text}"
						skipped_count += 1
						next
					end
					puts_line "skip_delete_branch: #{branch} (upstream=#{upstream}) reason=#{error_text}"
					puts_line "skip_force_delete_branch: #{branch} (upstream=#{upstream}) reason=#{force_error}" unless force_error.nil? || force_error.empty?
					skipped_count += 1
				end
				puts_line "prune_summary: deleted=#{deleted_count} skipped=#{skipped_count}"
				EXIT_OK
			end

			# Installs required hook files and enforces repository hook path.
			def hook!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				FileUtils.mkdir_p( hooks_dir )
				missing_templates = config.required_hooks.reject { |name| File.file?( hook_template_path( hook_name: name ) ) }
				unless missing_templates.empty?
					puts_line "BLOCK: missing hook templates in Butler: #{missing_templates.join( ', ' )}."
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
					align_remote_name_for_butler!
					hook_status = hook!
					return hook_status unless hook_status == EXIT_OK

					template_status = template_apply!
					return template_status unless template_status == EXIT_OK

					audit_status = audit!
					if audit_status == EXIT_OK
						puts_line "OK: Butler initialisation completed for #{repo_root}."
					elsif audit_status == EXIT_BLOCK
						puts_line "BLOCK: Butler initialisation completed with policy blocks; resolve and rerun butler audit."
					end
					audit_status
				end

				# Removes Butler-managed repository integration so a host repository can retire Butler cleanly.
				def offboard!
					print_header "Offboard"
					unless inside_git_work_tree?
						puts_line "ERROR: #{repo_root} is not a git repository."
						return EXIT_ERROR
					end
					hooks_status = disable_butler_hooks_path!
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
					puts_line "OK: Butler offboard completed for #{repo_root}."
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

			# Applies managed template files as full-file writes from Butler sources.
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

			# GitHub managed template source directory inside Butler repository.
			def github_templates_dir
				File.join( tool_root, "templates", ".github" )
			end

			# Canonical hook template location inside Butler repository.
			def hook_template_path( hook_name: )
				File.join( tool_root, "assets", "hooks", hook_name )
			end

			# Reports full hook health and can enforce stricter action messaging in `check`.
			def hooks_health_report( strict: false )
				configured = configured_hooks_path
				expected = hooks_dir
				configured_abs = configured.nil? ? nil : File.expand_path( configured )
				hooks_path_ok = configured_abs == expected
				puts_line "hooks_path: #{configured || '(unset)'}"
				puts_line "hooks_path_expected: #{expected}"
				puts_line( hooks_path_ok ? "hooks_path_status: ok" : "hooks_path_status: attention" )
				required_hook_paths.each do |path|
					exists = File.file?( path )
					symlink = File.symlink?( path )
					executable = exists && !symlink && File.executable?( path )
					puts_line "hook_file: #{relative_path( path )} exists=#{exists} symlink=#{symlink} executable=#{executable}"
				end
				missing = missing_hook_files
				non_exec = non_executable_hook_files
				symlinked = symlink_hook_files
				if strict
					puts_line "ACTION: run butler hook." unless hooks_path_ok && missing.empty? && non_exec.empty? && symlinked.empty?
				else
					puts_line "ACTION: run butler hook to enforce local main protections." unless hooks_path_ok && missing.empty? && non_exec.empty? && symlinked.empty?
				end
				hooks_path_ok && missing.empty? && non_exec.empty? && symlinked.empty?
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
				File.expand_path( File.join( config.hooks_base_path, Butler::VERSION ) )
			end

			# In outsider mode, Butler must not leave Butler-owned fingerprints in host repositories.
			def block_if_outsider_fingerprints!
				return nil unless outsider_mode?

				violations = outsider_fingerprint_violations
				return nil if violations.empty?

				violations.each { |entry| puts_line "BLOCK: #{entry}" }
				EXIT_BLOCK
			end

			# Butler source repository itself is excluded from host-repository fingerprint checks.
			def outsider_mode?
				File.expand_path( repo_root ) != File.expand_path( tool_root )
			end

			# Detects Butler-owned host artefacts that violate outsider boundary.
			def outsider_fingerprint_violations
				violations = []
				violations << "forbidden file .butler.yml detected" if File.file?( File.join( repo_root, ".butler.yml" ) )
				violations << "forbidden file bin/butler detected" if File.file?( File.join( repo_root, "bin", "butler" ) )
				violations << "forbidden directory .tools/butler detected" if Dir.exist?( File.join( repo_root, ".tools", "butler" ) )
				violations.concat( legacy_marker_violations )
				violations
			end

			# Legacy template markers are disallowed in outsider mode.
			def legacy_marker_violations
				files = []
				legacy_marker_token = "butler:#{%w[c o m m o n].join}:"
				Dir.glob( File.join( repo_root, "**", "*" ), File::FNM_DOTMATCH ).each do |absolute|
					next if absolute.include?( "/.git/" )
					next unless File.file?( absolute )
					next unless File.read( absolute ).include?( legacy_marker_token )

					relative = absolute.sub( "#{repo_root}/", "" )
					files << "forbidden legacy marker detected in #{relative}"
				end
				files
			end

			# NOTE: prune only targets local branches that meet both conditions:
			# 1) branch tracks configured remote (`github/*` by default), and
			# 2) upstream tracking state is marked as gone after fetch --prune.
			# Branches without upstream tracking are intentionally excluded.
			def stale_local_branches
				git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" ).lines.filter_map do |line|
					branch, upstream, track = line.strip.split( "\t", 3 )
					upstream = upstream.to_s
					track = track.to_s
					next if branch.to_s.empty? || upstream.empty?
					next unless upstream.start_with?( "#{config.git_remote}/" ) && track.include?( "gone" )

					{ branch: branch, upstream: upstream, track: track }
				end
			end

			# Safe delete can fail after squash merges because branch tip is no longer an ancestor.
			def non_merged_delete_error?( error_text: )
				error_text.to_s.downcase.include?( "not fully merged" )
			end

			# Guarded force-delete policy for stale branches:
			# 1) branch must match managed codex lane pattern,
			# 2) safe delete failure must be merge-related (`not fully merged`),
			# 3) gh must confirm at least one merged PR for this exact branch into configured main.
			def force_delete_evidence_for_stale_branch( branch:, delete_error_text: )
				return [ nil, "safe delete failure is not merge-related" ] unless non_merged_delete_error?( error_text: delete_error_text )
				return [ nil, "branch does not match managed pattern #{config.branch_pattern}" ] if config.branch_regex.match( branch.to_s ).nil?
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

				def disable_butler_hooks_path!
					configured = configured_hooks_path
					if configured.nil?
						puts_line "hooks_path: (unset)"
						return EXIT_OK
					end
					puts_line "hooks_path: #{configured}"
					configured_abs = File.expand_path( configured, repo_root )
					unless butler_managed_hooks_path?( configured_abs: configured_abs )
						puts_line "hooks_path_kept: #{configured} (not Butler-managed)"
						return EXIT_OK
					end
					git_system!( "config", "--unset", "core.hooksPath" )
					puts_line "hooks_path_unset: core.hooksPath"
					EXIT_OK
				rescue StandardError => e
					puts_line "ERROR: unable to update core.hooksPath (#{e.message})"
					EXIT_ERROR
				end

				def butler_managed_hooks_path?( configured_abs: )
					hooks_root = File.join( File.expand_path( config.hooks_base_path ), "" )
					configured_abs.start_with?( hooks_root )
				end

				def offboard_cleanup_targets
					( config.template_managed_files + [
						".github/workflows/butler-governance.yml",
						".github/workflows/butler_policy.yml",
						".butler.yml",
						"bin/butler",
						".tools/butler"
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

				# Ensures Butler expected remote naming (`github`) while keeping existing
				# repositories safe when neither `github` nor `origin` exists.
				def align_remote_name_for_butler!
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

		include LocalOps
	end
end
