# Tests for carson housekeep — sync + prune per repo.
require_relative "test_helper"

class RuntimeHousekeepTest < Minitest::Test
	include CarsonTestSupport

	# --- housekeep --all ---

	def test_housekeep_all_no_repos_returns_error
		runtime, repo_root = build_runtime
		result = runtime.housekeep_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_all_no_repos_json
		runtime, repo_root = build_runtime
		result = runtime.housekeep_all!( json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		data = JSON.parse( output )
		assert_equal "housekeep", data[ "command" ]
		assert_equal "error", data[ "status" ]
		assert_includes data[ "error" ], "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_all_with_missing_path
		config_path = File.join( Dir.tmpdir, "carson-housekeep-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/nonexistent-repo-#{$$}" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			result = runtime.housekeep_all!
			assert_equal Carson::Runtime::EXIT_ERROR, result
			output = runtime.instance_variable_get( :@out ).string
			assert_includes output, "SKIP (path not found)"
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end

	# --- housekeep <target> ---

	def test_housekeep_target_unknown_repo_returns_error
		runtime, repo_root = build_runtime
		result = runtime.housekeep_target!( target: "/nonexistent/repo" )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "Not a governed repository"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_target_unknown_repo_json
		runtime, repo_root = build_runtime
		result = runtime.housekeep_target!( target: "/nonexistent/repo", json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@out ).string
		data = JSON.parse( output )
		assert_equal "housekeep", data[ "command" ]
		assert_equal "error", data[ "status" ]
		assert_includes data[ "error" ], "Not a governed repository"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- resolve_governed_repo ---

	def test_resolve_governed_repo_by_basename
		config_path = File.join( Dir.tmpdir, "carson-housekeep-resolve-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/Users/test/AI", "/Users/test/carson" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			resolved = runtime.send( :resolve_governed_repo, target: "AI" )
			assert_equal "/Users/test/AI", resolved

			resolved_lower = runtime.send( :resolve_governed_repo, target: "ai" )
			assert_equal "/Users/test/AI", resolved_lower

			resolved_nil = runtime.send( :resolve_governed_repo, target: "nonexistent" )
			assert_nil resolved_nil
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end
end
