require_relative "test_helper"

class RuntimeLocalHelpersTest < Minitest::Test
	include CarsonTestSupport

	def test_normalise_porcelain_path_decodes_quoted_paths
		runtime, repo_root = build_runtime
		assert_equal "a b.txt", runtime.send( :normalise_porcelain_path, path_text: "\"a b.txt\"" )
		assert_equal "quote\"name.txt", runtime.send( :normalise_porcelain_path, path_text: "\"quote\\\"name.txt\"" )
	ensure
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_normalise_porcelain_path_leaves_plain_paths
		runtime, repo_root = build_runtime
		assert_equal "lib/foo.rb", runtime.send( :normalise_porcelain_path, path_text: "lib/foo.rb" )
		assert_equal "docs/guide.md", runtime.send( :normalise_porcelain_path, path_text: "docs/guide.md" )
	ensure
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_check_reports_hooks_path_mismatch_with_upgrade_action
		Dir.mktmpdir( "carson-hooks-upgrade-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			hooks_base = File.join( tmp_dir, "hooks" )
			legacy_hooks_path = File.join( hooks_base, "legacy-version" )
			FileUtils.mkdir_p( legacy_hooks_path )

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
				system( "git", "-C", repo_root, "config", "core.hooksPath", legacy_hooks_path, out: File::NULL, err: File::NULL )

				status = runtime.check!
				output = out.string
				assert_equal Carson::Runtime::EXIT_BLOCK, status
				assert_includes output, "hooks_path_status: attention"
				assert_includes output, "ACTION: hooks path mismatch (configured=#{legacy_hooks_path}, expected=#{expected_hooks_path})."
				assert_includes output, "ACTION: run carson hook to align hooks with Carson #{Carson::VERSION}."
			end
		end
	end

	private

	def with_env( pairs )
		previous = {}
		pairs.each do |key, value|
			previous[ key ] = ENV.key?( key ) ? ENV.fetch( key ) : :__missing__
			ENV[ key ] = value
		end
		yield
	ensure
		pairs.each_key do |key|
			value = previous.fetch( key )
			if value == :__missing__
				ENV.delete( key )
			else
				ENV[ key ] = value
			end
		end
	end
end
