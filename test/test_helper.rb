# Shared test infrastructure and helpers for the Carson test suite.
require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../lib/carson"

module CarsonTestSupport
	def carson_tmp_root
		candidate = ENV.fetch( "CARSON_TEST_TMPDIR", File.join( Dir.tmpdir, "carson-test" ) )
		FileUtils.mkdir_p( candidate )
		candidate
	rescue StandardError
		"/tmp"
	end

	def build_runtime( tool_root: nil, verbose: true )
		repo_root = Dir.mktmpdir( "carson-runtime-test", carson_tmp_root )
		output = StringIO.new
		error = StringIO.new
		resolved_tool_root = tool_root.nil? ? repo_root : tool_root
		config_path = ENV.fetch( "CARSON_CONFIG_FILE", "" ).to_s.strip
		config_path = write_test_config( repo_root: repo_root ) if config_path.empty?
		runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime = Carson::Runtime.new( repo_root: repo_root, tool_root: resolved_tool_root, output: output, error: error, verbose: verbose )
		end
		[ runtime, repo_root ]
	end

	def destroy_runtime_repo( repo_root: )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end

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

	def write_test_config( repo_root: )
		path = File.join( repo_root, "carson-config.json" )
		File.write(
			path,
			JSON.generate(
				{
					"govern" => {
						"state_path" => File.join( repo_root, "carson-state.json" )
					}
				}
			)
		)
		path
	end

	def with_feature_worktree_runtimes( branch_name:, worktree_name: )
		Dir.mktmpdir( "carson-worktree-runtime-test", carson_tmp_root ) do |tmp_dir|
			remote_path = File.join( tmp_dir, "remote.git" )
			repo_root = File.join( tmp_dir, "repo" )
			worktree_path = File.join( repo_root, ".claude", "worktrees", worktree_name )

			system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
			system( "git", "clone", remote_path, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "README.md" ), "# Test" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, out: File::NULL, err: File::NULL )

			config_path = write_test_config( repo_root: repo_root )
			root_runtime = nil
			worktree_runtime = nil
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				root_runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					output: StringIO.new,
					error: StringIO.new,
					verbose: false
				)
				worktree_runtime = Carson::Runtime.new(
					repo_root: worktree_path,
					tool_root: File.expand_path( "..", __dir__ ),
					output: StringIO.new,
					error: StringIO.new,
					verbose: false
				)
			end

			yield root_runtime, worktree_runtime, repo_root, worktree_path
		end
	end
end

ENV["CARSON_CONFIG_FILE"] = File.join( Dir.tmpdir, "carson-nonexistent-test-config.json" )
ENV["HOME"] = File.join( Dir.tmpdir, "carson-test-home" )
ENV["CARSON_TEST_TMPDIR"] = File.join( Dir.tmpdir, "carson-test" )
FileUtils.mkdir_p( ENV.fetch( "HOME" ) )
FileUtils.mkdir_p( ENV.fetch( "CARSON_TEST_TMPDIR" ) )
