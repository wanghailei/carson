module Carson
	class Runtime
		module Local
		private

			# Installs required hook files and enforces repository hook path.
			def prepare!
				fingerprint_status = block_if_outsider_fingerprints!
				return fingerprint_status unless fingerprint_status.nil?

				FileUtils.mkdir_p( hooks_dir )
				missing_templates = config.managed_hooks.reject { |name| File.file?( hook_template_path( hook_name: name ) ) }
				unless missing_templates.empty?
					puts_line "BLOCK: missing hook templates in Carson: #{missing_templates.join( ', ' )}."
					return EXIT_BLOCK
				end

				symlinked = symlink_hook_files
				unless symlinked.empty?
					puts_line "BLOCK: symlink hook files are not allowed: #{symlinked.join( ', ' )}."
					return EXIT_BLOCK
				end

				config.managed_hooks.each do |hook_name|
					source_path = hook_template_path( hook_name: hook_name )
					target_path = File.join( hooks_dir, hook_name )
					FileUtils.cp( source_path, target_path )
					FileUtils.chmod( 0o755, target_path )
					puts_verbose "hook_written: #{relative_path( target_path )}"
				end
				git_system!( "config", "core.hooksPath", hooks_dir )
				File.write( File.join( hooks_dir, "workflow_style" ), config.workflow_style )
				puts_verbose "configured_hooks_path: #{hooks_dir}"
				puts_line "Hooks installed (#{config.managed_hooks.count} hooks)."
				EXIT_OK
			end

			# Canonical hook template location inside Carson repository.
			def hook_template_path( hook_name: )
				File.join( tool_root, "hooks", hook_name )
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
				puts_verbose "hooks_path: #{configured || '(unset)'}"
				puts_verbose "hooks_path_expected: #{expected}"
				puts_verbose( hooks_path_ok ? "hooks_path_status: ok" : "hooks_path_status: attention" )
				hooks_path_ok
			end

			def print_required_hook_status
				required_hook_paths.each do |path|
					exists = File.file?( path )
					symlink = File.symlink?( path )
					executable = exists && !symlink && File.executable?( path )
					puts_verbose "hook_file: #{relative_path( path )} exists=#{exists} symlink=#{symlink} executable=#{executable}"
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
						puts_verbose "ACTION: hooks path is unset (expected=#{expected})."
					else
						puts_verbose "ACTION: hooks path mismatch (configured=#{configured_text}, expected=#{expected})."
					end
				end
				message = strict ? "ACTION: run carson prepare to align hooks with Carson #{Carson::VERSION}." : "ACTION: run carson prepare to enforce local main protections."
				puts_verbose message
			end

			# Reads configured core.hooksPath and normalises empty values to nil.
			def configured_hooks_path
				stdout_text, = git_capture_soft( "config", "--get", "core.hooksPath" )
				value = stdout_text.to_s.strip
				value.empty? ? nil : value
			end

			# Fully-qualified required hook file locations in the target repository.
			def required_hook_paths
				config.managed_hooks.map { |name| File.join( hooks_dir, name ) }
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
				File.expand_path( File.join( config.hooks_path, Carson::VERSION ) )
			end
		end
	end
end
