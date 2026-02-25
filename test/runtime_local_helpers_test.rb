require_relative "test_helper"

class RuntimeLocalHelpersTest < Minitest::Test
	include CarsonTestSupport

	def test_check_reports_hooks_path_mismatch_with_upgrade_action
		Dir.mktmpdir( "carson-hooks-upgrade-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			hooks_base = File.join( tmp_dir, "hooks" )
			previous_hooks_path = File.join( hooks_base, "previous-version" )
			FileUtils.mkdir_p( previous_hooks_path )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_HOOKS_BASE_PATH" => hooks_base
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				expected_hooks_path = runtime.send( :hooks_dir )
				FileUtils.mkdir_p( expected_hooks_path )
				runtime.send( :config ).required_hooks.each do |hook_name|
					path = File.join( expected_hooks_path, hook_name )
					File.write( path, "#!/usr/bin/env bash\n" )
					FileUtils.chmod( 0o755, path )
				end
				system( "git", "-C", repo_root, "config", "core.hooksPath", previous_hooks_path, out: File::NULL, err: File::NULL )

				status = runtime.check!
				output = out.string
				assert_equal Carson::Runtime::EXIT_BLOCK, status
				assert_includes output, "hooks_path_status: attention"
				assert_includes output, "ACTION: hooks path mismatch (configured=#{previous_hooks_path}, expected=#{expected_hooks_path})."
				assert_includes output, "ACTION: run carson hook to align hooks with Carson #{Carson::VERSION}."
			end
		end
	end
end
