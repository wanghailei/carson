require_relative "test_helper"

class RuntimeReposTest < Minitest::Test
	include CarsonTestSupport

	def test_repos_returns_exit_ok
		runtime, repo_root = build_runtime
		result = runtime.repos!
		assert_equal Carson::Runtime::EXIT_OK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_repos_shows_no_repos_message_when_empty
		runtime, repo_root = build_runtime
		runtime.repos!
		output = runtime.instance_variable_get( :@out ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_repos_lists_governed_repos
		config_path = File.join( Dir.tmpdir, "carson-repos-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/repo-a", "/tmp/repo-b" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			runtime.repos!
			output = runtime.instance_variable_get( :@out ).string
			assert_includes output, "Governed repositories (2)"
			assert_includes output, "/tmp/repo-a"
			assert_includes output, "/tmp/repo-b"
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end

	def test_repos_json_output
		config_path = File.join( Dir.tmpdir, "carson-repos-json-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/repo-x" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			runtime.repos!( json_output: true )
			output = runtime.instance_variable_get( :@out ).string
			data = JSON.parse( output )
			assert_equal "repos", data[ "command" ]
			assert_equal [ "/tmp/repo-x" ], data[ "repos" ]
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end

	def test_repos_json_output_empty
		runtime, repo_root = build_runtime
		runtime.repos!( json_output: true )
		output = runtime.instance_variable_get( :@out ).string
		data = JSON.parse( output )
		assert_equal "repos", data[ "command" ]
		assert_equal [], data[ "repos" ]
		destroy_runtime_repo( repo_root: repo_root )
	end
end
