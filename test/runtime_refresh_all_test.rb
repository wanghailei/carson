require_relative "test_helper"

class RuntimeRefreshAllTest < Minitest::Test
	include CarsonTestSupport

	def test_refresh_all_empty_config
		Dir.mktmpdir( "carson-refresh-all-test", carson_tmp_root ) do |tmp_dir|
			repo_root = File.join( tmp_dir, "repo" )
			FileUtils.mkdir_p( repo_root )
			system( "git", "init", repo_root, out: File::NULL, err: File::NULL )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_HOOKS_BASE_PATH" => File.join( tmp_dir, "hooks" )
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err
				)
				status = runtime.refresh_all!
				assert_equal Carson::Runtime::EXIT_ERROR, status
				assert_includes out.string, "no governed repositories configured"
			end
		end
	end

	def test_refresh_all_with_repos
		Dir.mktmpdir( "carson-refresh-all-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )

			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )

			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => hooks_base
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_a,
					tool_root: tool_root,
					out: out,
					err: err
				)
				status = runtime.refresh_all!
				output = out.string

				assert_includes output, "Refresh all (2 repos)"
				assert_includes output, "repo-a: OK"
				assert_includes output, "repo-b: OK"
				assert_includes output, "2 refreshed, 0 failed"
				assert_equal Carson::Runtime::EXIT_OK, status
			end
		end
	end

	def test_refresh_all_missing_path
		Dir.mktmpdir( "carson-refresh-all-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )

			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			missing_path = File.join( tmp_dir, "nonexistent-repo" )

			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, missing_path ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => hooks_base
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_a,
					tool_root: tool_root,
					out: out,
					err: err
				)
				status = runtime.refresh_all!
				output = out.string

				assert_includes output, "repo-a: OK"
				assert_includes output, "nonexistent-repo: FAIL (path not found)"
				assert_includes output, "1 refreshed, 1 failed"
				assert_equal Carson::Runtime::EXIT_ERROR, status
			end
		end
	end

	def test_refresh_all_continues_on_failure
		Dir.mktmpdir( "carson-refresh-all-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )

			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			# A directory that exists but is not a git repo
			non_git_dir = File.join( tmp_dir, "not-a-repo" )
			FileUtils.mkdir_p( non_git_dir )
			repo_c = create_git_repo( parent: tmp_dir, name: "repo-c" )

			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, non_git_dir, repo_c ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => hooks_base
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_a,
					tool_root: tool_root,
					out: out,
					err: err
				)
				status = runtime.refresh_all!
				output = out.string

				assert_includes output, "repo-a: OK"
				assert_includes output, "not-a-repo: FAIL"
				assert_includes output, "repo-c: OK"
				assert_includes output, "2 refreshed, 1 failed"
				assert_equal Carson::Runtime::EXIT_ERROR, status
			end
		end
	end

private

	def create_git_repo( parent:, name: )
		path = File.join( parent, name )
		FileUtils.mkdir_p( path )
		system( "git", "init", path, out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "commit", "--allow-empty", "-m", "initial", out: File::NULL, err: File::NULL )
		path
	end

	def write_config( path:, repos: )
		data = { "govern" => { "repos" => repos } }
		File.write( path, JSON.generate( data ) )
	end
end
