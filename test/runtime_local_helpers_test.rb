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

			dirty = runtime.send( :managed_dirty_paths )
			assert_includes dirty, managed_rel
		end
	end
end
