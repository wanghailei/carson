# Tests for Layer 2 batch operations: --all variants of
# template check, audit, sync, status, prune, and portfolio safety.
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

	# --- template_check_all! ---

	def test_template_check_all_no_repos
		runtime, repo_root = build_runtime
		result = runtime.template_check_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_template_check_all_with_missing_path
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ "/tmp/nonexistent-batch-#{$$}" ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.template_check_all!
				assert_equal Carson::Runtime::EXIT_BLOCK, result
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "FAIL (path not found)"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_template_check_all_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.template_check_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "Template check all (2 repos)"
				assert_includes output, "Template check complete:"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- audit_all! ---

	def test_audit_all_no_repos
		runtime, repo_root = build_runtime
		result = runtime.audit_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_all_with_missing_path
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ "/tmp/nonexistent-audit-#{$$}" ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.audit_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "FAIL (path not found)"
				assert_includes output, "0 ok"
				assert_includes output, "1 failed"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_audit_all_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.audit_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "Audit all (2 repos)"
				assert_includes output, "Audit all complete:"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- sync_all! ---

	def test_sync_all_no_repos
		runtime, repo_root = build_runtime
		result = runtime.sync_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_sync_all_with_missing_path
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ "/tmp/nonexistent-sync-#{$$}" ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.sync_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "FAIL (path not found)"
				assert_includes output, "Sync all complete:"
				assert_includes output, "1 failed"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_sync_all_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.sync_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "Sync all (2 repos)"
				assert_includes output, "Sync all complete:"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- status_all! ---

	def test_status_all_no_repos
		runtime, repo_root = build_runtime
		result = runtime.status_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_all_with_missing_path
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			missing = File.join( tmp_dir, "gone-repo" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, missing ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.status_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "repo-a:"
				assert_includes output, "gone-repo: MISSING"
				assert_equal Carson::Runtime::EXIT_OK, result
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_status_all_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.status_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "Portfolio (2 repos)"
				assert_includes output, "repo-a:"
				assert_includes output, "repo-b:"
				assert_equal Carson::Runtime::EXIT_OK, result
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_status_all_json_no_repos
		runtime, repo_root = build_runtime
		result = runtime.status_all!( json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_all_json_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.status_all!( json_output: true )
				output = runtime.instance_variable_get( :@out ).string
				data = JSON.parse( output )
				assert_equal "status", data[ "command" ]
				assert_kind_of Array, data[ "repos" ]
				assert_equal 1, data[ "repos" ].length
				assert_equal "repo-a", data[ "repos" ].first[ "name" ]
				assert_equal Carson::Runtime::EXIT_OK, result
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	# --- prune_all! ---

	def test_prune_all_no_repos
		runtime, repo_root = build_runtime
		result = runtime.prune_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_prune_all_with_missing_path
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ "/tmp/nonexistent-prune-#{$$}" ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.prune_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "FAIL (path not found)"
				assert_includes output, "Prune all complete:"
				assert_includes output, "1 failed"
				destroy_runtime_repo( repo_root: repo_root )
			end
		end
	end

	def test_prune_all_with_repos
		Dir.mktmpdir( "carson-batch-test", carson_tmp_root ) do |tmp_dir|
			repo_a = create_git_repo( parent: tmp_dir, name: "repo-a" )
			repo_b = create_git_repo( parent: tmp_dir, name: "repo-b" )
			config_path = File.join( tmp_dir, "config.json" )
			write_config( path: config_path, repos: [ repo_a, repo_b ] )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				runtime, repo_root = build_runtime
				result = runtime.prune_all!
				output = runtime.instance_variable_get( :@out ).string
				assert_includes output, "Prune all (2 repos)"
				assert_includes output, "Prune all complete:"
				destroy_runtime_repo( repo_root: repo_root )
			end
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
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: clean_repo,
					tool_root: tool_root,
					out: out,
					err: err
				)
				status = runtime.refresh_all!
				output = out.string
				assert_includes output, "clean: OK"
				assert_includes output, "dirty: SKIP (uncommitted changes)"
				assert_equal Carson::Runtime::EXIT_ERROR, status
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
