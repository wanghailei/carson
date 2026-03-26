# Tests for Carson configuration loading and validation.
require_relative "test_helper"

class ConfigLoadTest < Minitest::Test
	include CarsonTestSupport

	def test_env_overrides_global_config_values
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"review" => { "disposition" => "Global:" }
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path, "CARSON_REVIEW_DISPOSITION" => "Env:" ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "Env:", config.review_disposition
			end
		end
	end

	def test_invalid_global_config_raises_config_error
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, "{invalid-json" )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_invalid_global_config_shape_raises_config_error
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "review" => "invalid" } ) )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_runtime_paths_fall_back_to_tmpdir_when_home_is_invalid
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			tmpdir = File.join( dir, "custom-tmpdir" )
			FileUtils.mkdir_p( tmpdir )
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( {} ) )

			with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => "relative-home", "TMPDIR" => tmpdir ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal File.join( tmpdir, "carson", "hooks" ), config.hooks_path
				assert_equal File.join( tmpdir, "carson", "state.json" ), config.govern_state_path
			end
		end
	end

	def test_govern_state_path_falls_back_to_tmp_when_home_and_tmpdir_are_invalid
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( {} ) )

			with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => "relative-home", "TMPDIR" => "relative-tmpdir" ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "/tmp/carson/state.json", config.govern_state_path
			end
		end
	end

end
