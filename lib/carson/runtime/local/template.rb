module Carson
	class Runtime
		module Local
			TEMPLATE_SYNC_BRANCH = "carson/template-sync".freeze

			SUPERSEDED = [
				".github/carson-instructions.md",
				".github/workflows/carson-lint.yml",
				".github/.mega-linter.yml"
			].freeze

			# Read-only template drift check; returns block when managed files are out of sync.
			def template_check!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				puts_verbose ""
				puts_verbose "[Template Sync Check]"
				results = template_results
				stale = template_superseded_present
				drift_count = results.count { |entry| entry.fetch( :status ) == "drift" }
				error_count = results.count { |entry| entry.fetch( :status ) == "error" }
				stale_count = stale.count
				results.each do |entry|
					puts_verbose "template_file: #{entry.fetch( :file )} status=#{entry.fetch( :status )} reason=#{entry.fetch( :reason )}"
				end
				stale.each { |file| puts_verbose "template_file: #{file} status=stale reason=superseded" }
				puts_verbose "template_summary: total=#{results.count} drift=#{drift_count} stale=#{stale_count} error=#{error_count}"
				unless verbose?
					if ( drift_count + stale_count ).positive?
						summary_parts = []
						summary_parts << "#{drift_count} of #{results.count} drifted" if drift_count.positive?
						summary_parts << "#{stale_count} stale" if stale_count.positive?
						puts_line "Templates: #{summary_parts.join( ", " )}"
						results.select { |entry| entry.fetch( :status ) == "drift" }.each { |entry| puts_line "  #{entry.fetch( :file )}" }
						stale.each { |file| puts_line "  #{file} — superseded" }
					else
						puts_line "Templates: #{results.count} files in sync"
					end
				end
				return EXIT_ERROR if error_count.positive?

				( drift_count + stale_count ).positive? ? EXIT_BLOCK : EXIT_OK
			end

			# Applies managed template files as full-file writes from Carson sources.
			# Also removes superseded files that are no longer part of the managed set.
			def template_apply!( push_prep: false )
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				puts_verbose ""
				puts_verbose "[Template Sync Apply]"
				results = template_results
				stale = template_superseded_present
				applied = 0
				results.each do |entry|
					if entry.fetch( :status ) == "error"
						puts_verbose "template_file: #{entry.fetch( :file )} status=error reason=#{entry.fetch( :reason )}"
						next
					end

					file_path = File.join( repo_root, entry.fetch( :file ) )
					if entry.fetch( :status ) == "ok"
						puts_verbose "template_file: #{entry.fetch( :file )} status=ok reason=in_sync"
						next
					end

					FileUtils.mkdir_p( File.dirname( file_path ) )
					File.write( file_path, entry.fetch( :applied_content ) )
					puts_verbose "template_file: #{entry.fetch( :file )} status=updated reason=#{entry.fetch( :reason )}"
					applied += 1
				end

				removed = 0
				stale.each do |file|
					file_path = resolve_repo_path!( relative_path: file, label: "superseded file #{file}" )
					File.delete( file_path )
					puts_verbose "template_file: #{file} status=removed reason=superseded"
					removed += 1
				end

				error_count = results.count { |entry| entry.fetch( :status ) == "error" }
				puts_verbose "template_apply_summary: updated=#{applied} removed=#{removed} error=#{error_count}"
				unless verbose?
					if applied.positive? || removed.positive?
						summary_parts = []
						summary_parts << "#{applied} updated" if applied.positive?
						summary_parts << "#{removed} removed" if removed.positive?
						puts_line "Templates applied (#{summary_parts.join( ", " )})."
					else
						puts_line "Templates in sync."
					end
				end
				return EXIT_ERROR if error_count.positive?

				return EXIT_BLOCK if push_prep && push_prep_commit!
				EXIT_OK
			end

		private

			# Orchestrates worktree-based template propagation to the remote.
			def template_propagate!( drift_count: )
				if drift_count.zero?
					puts_verbose "template_propagate: skip (no drift)"
					return { status: :skip, reason: "no drift" }
				end

				unless git_remote_exists?( remote_name: config.git_remote )
					puts_verbose "template_propagate: skip (no remote #{config.git_remote})"
					return { status: :skip, reason: "no remote" }
				end

				worktree_dir = nil
				begin
					worktree_dir = template_propagate_create_worktree!
					template_propagate_write_files!( worktree_dir: worktree_dir )
					committed = template_propagate_commit!( worktree_dir: worktree_dir )
					unless committed
						puts_verbose "template_propagate: skip (no changes after write)"
						return { status: :skip, reason: "no changes" }
					end
					result = template_propagate_deliver!( worktree_dir: worktree_dir )
					template_propagate_report!( result: result )
					result
				rescue StandardError => e
					puts_verbose "template_propagate: error (#{e.message})"
					{ status: :error, reason: e.message }
				ensure
					template_propagate_cleanup!( worktree_dir: worktree_dir ) if worktree_dir
				end
			end

			def template_propagate_create_worktree!
				worktree_dir = File.join( Dir.tmpdir, "carson-template-sync-#{Process.pid}-#{Time.now.to_i}" )
				wt_git = Adapters::Git.new( repo_root: worktree_dir )

				git_system!( "fetch", config.git_remote, config.main_branch )
				git_system!( "worktree", "add", "--detach", worktree_dir, "#{config.git_remote}/#{config.main_branch}" )
				wt_git.run( "checkout", "-B", TEMPLATE_SYNC_BRANCH )
				wt_git.run( "config", "core.hooksPath", "/dev/null" )
				puts_verbose "template_propagate: worktree created at #{worktree_dir}"
				worktree_dir
			end

			def template_propagate_write_files!( worktree_dir: )
				config.template_managed_files.each do |managed_file|
					template_path = template_source_path( managed_file: managed_file )
					next if template_path.nil?

					target_path = File.join( worktree_dir, managed_file )
					FileUtils.mkdir_p( File.dirname( target_path ) )
					expected_content = normalize_text( text: File.read( template_path ) )
					File.write( target_path, expected_content )
					puts_verbose "template_propagate: wrote #{managed_file}"
				end

				template_superseded_present_in( root: worktree_dir ).each do |file|
					file_path = File.join( worktree_dir, file )
					File.delete( file_path )
					puts_verbose "template_propagate: removed superseded #{file}"
				end
			end

			def template_propagate_commit!( worktree_dir: )
				wt_git = Adapters::Git.new( repo_root: worktree_dir )
				wt_git.run( "add", "--all" )

				_, _, no_diff, = wt_git.run( "diff", "--cached", "--quiet" )
				return false if no_diff

				wt_git.run( "commit", "-m", "chore: sync Carson #{Carson::VERSION} managed templates" )
				puts_verbose "template_propagate: committed"
				true
			end

			def template_propagate_deliver!( worktree_dir: )
				if config.workflow_style == "trunk"
					template_propagate_deliver_trunk!( worktree_dir: worktree_dir )
				else
					template_propagate_deliver_branch!( worktree_dir: worktree_dir )
				end
			end

			def template_propagate_deliver_trunk!( worktree_dir: )
				wt_git = Adapters::Git.new( repo_root: worktree_dir )
				stdout_text, stderr_text, success, = wt_git.run( "push", config.git_remote, "HEAD:refs/heads/#{config.main_branch}" )
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "push to #{config.main_branch} failed" if error_text.empty?
					raise error_text
				end
				puts_verbose "template_propagate: pushed to #{config.main_branch}"
				{ status: :pushed, ref: config.main_branch }
			end

			def template_propagate_deliver_branch!( worktree_dir: )
				wt_git = Adapters::Git.new( repo_root: worktree_dir )
				stdout_text, stderr_text, success, = wt_git.run( "push", "--force-with-lease", config.git_remote, "#{TEMPLATE_SYNC_BRANCH}:#{TEMPLATE_SYNC_BRANCH}" )
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "push #{TEMPLATE_SYNC_BRANCH} failed" if error_text.empty?
					raise error_text
				end
				puts_verbose "template_propagate: pushed #{TEMPLATE_SYNC_BRANCH}"

				pr_url = template_propagate_ensure_pr!( worktree_dir: worktree_dir )
				{ status: :pr, branch: TEMPLATE_SYNC_BRANCH, pr_url: pr_url }
			end

			def template_propagate_ensure_pr!( worktree_dir: )
				wt_gh = Adapters::GitHub.new( repo_root: worktree_dir )

				stdout_text, _, success, = wt_gh.run(
					"pr", "list",
					"--head", TEMPLATE_SYNC_BRANCH,
					"--base", config.main_branch,
					"--state", "open",
					"--json", "url",
					"--jq", ".[0].url"
				)
				existing_url = stdout_text.to_s.strip
				if success && !existing_url.empty?
					puts_verbose "template_propagate: existing PR #{existing_url}"
					return existing_url
				end

				stdout_text, stderr_text, success, = wt_gh.run(
					"pr", "create",
					"--head", TEMPLATE_SYNC_BRANCH,
					"--base", config.main_branch,
					"--title", "chore: sync Carson #{Carson::VERSION} managed templates",
					"--body", "Auto-generated by `carson refresh`.\n\nUpdates managed template files to match Carson #{Carson::VERSION}."
				)
				unless success
					error_text = stderr_text.to_s.strip
					error_text = "gh pr create failed" if error_text.empty?
					raise error_text
				end
				pr_url = stdout_text.to_s.strip
				puts_verbose "template_propagate: created PR #{pr_url}"
				pr_url
			end

			def template_propagate_cleanup!( worktree_dir: )
				# Try safe removal first; fall back to force only for Carson's own sync worktree.
				_, _, safe_success, = git_run( "worktree", "remove", worktree_dir )
				git_run( "worktree", "remove", "--force", worktree_dir ) unless safe_success
				git_run( "branch", "-D", TEMPLATE_SYNC_BRANCH )
				puts_verbose "template_propagate: worktree and local branch cleaned up"
			rescue StandardError => e
				puts_verbose "template_propagate: cleanup warning (#{e.message})"
			end

			def template_propagate_report!( result: )
				case result.fetch( :status )
				when :pushed
					puts_line "Templates pushed to #{result.fetch( :ref )}."
				when :pr
					puts_line "Template sync PR: #{result.fetch( :pr_url )}"
				end
			end

			def template_superseded_present_in( root: )
				SUPERSEDED.select do |file|
					File.file?( File.join( root, file ) )
				end
			end

			def template_results
				config.template_managed_files.map { |managed_file| template_result_for_file( managed_file: managed_file ) }
			end

			def template_superseded_present
				SUPERSEDED.select do |file|
					file_path = resolve_repo_path!( relative_path: file, label: "superseded file #{file}" )
					File.file?( file_path )
				end
			end

			def template_result_for_file( managed_file: )
				template_path = template_source_path( managed_file: managed_file )
				return { file: managed_file, status: "error", reason: "missing template #{File.basename( managed_file )}", applied_content: nil } if template_path.nil?

				expected_content = normalize_text( text: File.read( template_path ) )
				file_path = resolve_repo_path!( relative_path: managed_file, label: "template.managed_files entry #{managed_file}" )
				return { file: managed_file, status: "drift", reason: "missing_file", applied_content: expected_content } unless File.file?( file_path )

				current_content = normalize_text( text: File.read( file_path ) )
				return { file: managed_file, status: "ok", reason: "in_sync", applied_content: current_content } if current_content == expected_content

				{ file: managed_file, status: "drift", reason: "content_mismatch", applied_content: expected_content }
			end

			def normalize_text( text: )
				"#{text.to_s.gsub( "\r\n", "\n" ).rstrip}\n"
			end

			def github_templates_dir
				File.join( tool_root, "templates", ".github" )
			end

			def template_source_path( managed_file: )
				relative_within_github = managed_file.delete_prefix( ".github/" )

				canonical = config.template_canonical
				if canonical && !canonical.empty?
					canonical_path = File.join( canonical, relative_within_github )
					return canonical_path if File.file?( canonical_path )
				end

				template_path = File.join( github_templates_dir, relative_within_github )
				return template_path if File.file?( template_path )

				basename_path = File.join( github_templates_dir, File.basename( managed_file ) )
				return basename_path if File.file?( basename_path )

				nil
			end

			def push_prep_commit!
				return if current_branch == config.main_branch

				dirty = managed_dirty_paths
				return if dirty.empty?

				git_system!( "add", *dirty )
				git_system!( "commit", "-m", "chore: sync Carson managed files" )
				puts_line "Carson committed managed file updates. Push again to include them."
				true
			end

			def managed_dirty_paths
				template_paths = config.template_managed_files + SUPERSEDED
				linters_glob   = Dir.glob( File.join( repo_root, ".github/linters/**/*" ) )
					.select { |p| File.file?( p ) }
					.map { |p| p.delete_prefix( "#{repo_root}/" ) }
				candidates = ( template_paths + linters_glob ).uniq
				return [] if candidates.empty?

				stdout_text, = git_capture_soft( "status", "--porcelain", "--", *candidates )
				stdout_text.to_s.lines
					.map { |l| l[ 3.. ].strip }
					.reject( &:empty? )
			end
		end
	end
end
