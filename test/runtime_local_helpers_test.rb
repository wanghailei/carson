require_relative "test_helper"

class RuntimeLocalHelpersTest < Minitest::Test
	include CarsonTestSupport

	# Builds a real git repo in a temp dir, yields runtime and the repo_root.
	def with_git_repo
		Dir.mktmpdir( "carson-managed-dirty-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			# Create an initial commit so HEAD exists.
			readme = File.join( repo_root, "README.md" )
			File.write( readme, "init\n" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				out: out,
				err: err
			)
			yield runtime, repo_root
		end
	end

	def test_managed_dirty_paths_includes_tracked_modified_file
		with_git_repo do |runtime, repo_root|
			# Commit a tracked managed file, then modify it.
			managed_rel = "managed.txt"
			managed_abs = File.join( repo_root, managed_rel )
			File.write( managed_abs, "original\n" )
			system( "git", "-C", repo_root, "add", managed_rel, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "add managed", out: File::NULL, err: File::NULL )
			File.write( managed_abs, "changed\n" )

			runtime.send( :config ).instance_variable_set( :@template_managed_files, [ managed_rel ] )
			runtime.send( :config ).instance_variable_set( :@template_superseded_files, [] )

			dirty = runtime.send( :managed_dirty_paths )
			assert_includes dirty, managed_rel
		end
	end

	def test_managed_dirty_paths_includes_untracked_file
		with_git_repo do |runtime, repo_root|
			# Write a new managed file that has never been committed (untracked).
			managed_rel = "new_managed.txt"
			managed_abs = File.join( repo_root, managed_rel )
			File.write( managed_abs, "brand new\n" )

			runtime.send( :config ).instance_variable_set( :@template_managed_files, [ managed_rel ] )
			runtime.send( :config ).instance_variable_set( :@template_superseded_files, [] )

			dirty = runtime.send( :managed_dirty_paths )
			assert_includes dirty, managed_rel
		end
	end

	def test_inspect_reports_hooks_path_mismatch_with_upgrade_action
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
					err: err,
					verbose: true
				)
				expected_hooks_path = runtime.send( :hooks_dir )
				FileUtils.mkdir_p( expected_hooks_path )
				runtime.send( :config ).required_hooks.each do |hook_name|
					path = File.join( expected_hooks_path, hook_name )
					File.write( path, "#!/usr/bin/env bash\n" )
					FileUtils.chmod( 0o755, path )
				end
				system( "git", "-C", repo_root, "config", "core.hooksPath", previous_hooks_path, out: File::NULL, err: File::NULL )

				status = runtime.inspect!
				output = out.string
				assert_equal Carson::Runtime::EXIT_BLOCK, status
				assert_includes output, "hooks_path_status: attention"
				assert_includes output, "ACTION: hooks path mismatch (configured=#{previous_hooks_path}, expected=#{expected_hooks_path})."
				assert_includes output, "ACTION: run carson prepare to align hooks with Carson #{Carson::VERSION}."
			end
		end
	end
end
