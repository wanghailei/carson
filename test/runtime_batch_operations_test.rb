# Tests for Layer 2 batch operations: portfolio safety, refresh_all,
# and batch-pending bookkeeping.
require_relative "test_helper"

class RuntimeBatchOperationsTest < Minitest::Test
	include CarsonTestSupport

	# --- portfolio_repo_safety ---

	def test_portfolio_repo_safety_clean_repo_is_safe
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo = create_git_repo( parent: tmp_dir, name: "clean-repo" )
			runtime, runtime_root = build_runtime
			safety = runtime.send( :portfolio_repo_safety, repo_path: repo )
			assert_equal true, safety.fetch( :safe )
			assert_empty safety.fetch( :reasons )
			destroy_runtime_repo( repo_root: runtime_root )
		end
	end

	def test_portfolio_repo_safety_dirty_repo_is_unsafe
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo = create_git_repo( parent: tmp_dir, name: "dirty-repo" )
			File.write( File.join( repo, "uncommitted.txt" ), "dirty" )
			runtime, runtime_root = build_runtime
			safety = runtime.send( :portfolio_repo_safety, repo_path: repo )
			assert_equal false, safety.fetch( :safe )
			assert_includes safety.fetch( :reasons ).join( " " ), "uncommitted changes"
			destroy_runtime_repo( repo_root: runtime_root )
		end
	end

	def test_portfolio_repo_safety_non_git_directory_passes_through
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			non_git = File.join( tmp_dir, "not-a-repo" )
			FileUtils.mkdir_p( non_git )
			runtime, runtime_root = build_runtime
			safety = runtime.send( :portfolio_repo_safety, repo_path: non_git )
			assert_equal true, safety.fetch( :safe )
			destroy_runtime_repo( repo_root: runtime_root )
		end
	end

	# --- refresh_all! safety integration ---

	def test_refresh_all_skips_dirty_repo
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )
			clean_repo = create_git_repo( parent: tmp_dir, name: "clean" )
			dirty_repo = create_git_repo( parent: tmp_dir, name: "dirty" )
			File.write( File.join( dirty_repo, "uncommitted.txt" ), "dirty" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ clean_repo, dirty_repo ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => hooks_base
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: clean_repo,
					tool_root: tool_root,
					output: output,
					error: error
				)
				status = runtime.refresh_all!
				output = output.string
				assert_includes output, "clean: OK"
				assert_includes output, "dirty: PENDING (uncommitted changes)"
				assert_equal Carson::Runtime::EXIT_ERROR, status
			end
		end
	end

	# --- batch_pending_path ---

	def test_batch_pending_path_returns_expected_location
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			with_env( "HOME" => tmp_dir ) do
				runtime, repo_root = build_runtime
				path = runtime.send( :batch_pending_path )
				expected = File.join( tmp_dir, ".carson", "cache", "batch_pending.json" )
				assert_equal expected, path
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- record / load / clear batch pending ---

	def test_record_and_load_batch_pending
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			with_env( "HOME" => tmp_dir ) do
				runtime, repo_root = build_runtime
				runtime.send( :record_batch_skip, command: "refresh", repo_path: "/tmp/repo-a", reason: "uncommitted changes" )
				data = runtime.send( :load_batch_pending )
				assert_equal 1, data[ "refresh" ][ "/tmp/repo-a" ][ "attempts" ]
				assert_equal "uncommitted changes", data[ "refresh" ][ "/tmp/repo-a" ][ "reason" ]
				refute_nil data[ "refresh" ][ "/tmp/repo-a" ][ "skipped_at" ]

				# Second record increments attempts.
				runtime.send( :record_batch_skip, command: "refresh", repo_path: "/tmp/repo-a", reason: "still dirty" )
				data = runtime.send( :load_batch_pending )
				assert_equal 2, data[ "refresh" ][ "/tmp/repo-a" ][ "attempts" ]
				assert_equal "still dirty", data[ "refresh" ][ "/tmp/repo-a" ][ "reason" ]
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_clear_batch_success_removes_entry
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			with_env( "HOME" => tmp_dir ) do
				runtime, repo_root = build_runtime
				runtime.send( :record_batch_skip, command: "refresh", repo_path: "/tmp/repo-a", reason: "dirty" )
				runtime.send( :record_batch_skip, command: "refresh", repo_path: "/tmp/repo-b", reason: "worktrees" )
				runtime.send( :clear_batch_success, command: "refresh", repo_path: "/tmp/repo-a" )

				data = runtime.send( :load_batch_pending )
				assert_nil data.dig( "refresh", "/tmp/repo-a" )
				refute_nil data.dig( "refresh", "/tmp/repo-b" )

				# Clearing the last entry removes the command key entirely.
				runtime.send( :clear_batch_success, command: "refresh", repo_path: "/tmp/repo-b" )
				data = runtime.send( :load_batch_pending )
				assert_nil data[ "refresh" ]
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- refresh_all! pending integration ---

	def test_refresh_all_records_pending_for_skipped_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )
			clean_repo = create_git_repo( parent: tmp_dir, name: "clean" )
			dirty_repo = create_git_repo( parent: tmp_dir, name: "dirty" )
			File.write( File.join( dirty_repo, "uncommitted.txt" ), "dirty" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ clean_repo, dirty_repo ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => hooks_base
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: clean_repo,
					tool_root: tool_root,
					output: output,
					error: error
				)
				runtime.refresh_all!

				# Verify the pending log was written.
				pending = runtime.send( :pending_repos_for, command: "refresh" )
				pending_paths = pending.map { |entry| entry[ :path ] }
				assert_includes pending_paths, dirty_repo
				refute_includes pending_paths, clean_repo

				output = output.string
				assert_includes output, "still pending (will retry on next run)"
			end
		end
	end

	def test_refresh_all_clears_pending_on_success
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )
			repo = create_git_repo( parent: tmp_dir, name: "repo-a" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => hooks_base
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo,
					tool_root: tool_root,
					output: output,
					error: error
				)

				# Seed a pending entry, then run refresh which should succeed and clear it.
				runtime.send( :record_batch_skip, command: "refresh", repo_path: repo, reason: "was dirty" )
				runtime.refresh_all!

				pending = runtime.send( :pending_repos_for, command: "refresh" )
				pending_paths = pending.map { |entry| entry[ :path ] }
				refute_includes pending_paths, repo
			end
		end
	end

	def test_refresh_all_reports_pending_from_previous_run
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			hooks_base = File.join( tmp_dir, "hooks" )
			repo = create_git_repo( parent: tmp_dir, name: "repo-a" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo ] )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => hooks_base
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo,
					tool_root: tool_root,
					output: output,
					error: error
				)

				# Seed a pending entry from a previous run.
				runtime.send( :record_batch_skip, command: "refresh", repo_path: "/tmp/old-repo", reason: "was dirty" )

				runtime.refresh_all!
				output = output.string
				assert_includes output, "1 repo pending from previous run"
			end
		end
	end

private

	def create_git_repo( parent:, name: )
		path = File.join( parent, name )
		FileUtils.mkdir_p( path )
		system( "git", "init", "--initial-branch=main", path, out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "config", "user.email", "test@test.local", out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "commit", "--allow-empty", "-m", "initial", out: File::NULL, err: File::NULL )
		path
	end

	def write_config( path:, repos: )
		data = { "govern" => { "repos" => repos } }
		File.write( path, JSON.generate( data ) )
	end
end
