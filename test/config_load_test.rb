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

	def test_default_advisory_check_names_includes_scheduled_review_sweep
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_includes config.audit_advisory_check_names, "Scheduled review sweep"
	end

	def test_advisory_check_names_env_override
		with_env( "CARSON_AUDIT_ADVISORY_CHECK_NAMES" => "Custom sweep,Other check" ) do
			config = Carson::Config.load( repo_root: Dir.pwd )
			assert_equal [ "Custom sweep", "Other check" ], config.audit_advisory_check_names
		end
	end

end
