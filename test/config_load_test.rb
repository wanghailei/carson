require_relative "test_helper"

class ConfigLoadTest < Minitest::Test
	include CarsonTestSupport

	def test_default_scope_path_groups_include_install_script_under_tool
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_includes config.path_groups.fetch( "tool" ), "install.sh"
	end

	def test_env_overrides_global_config_values
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"review" => { "required_disposition_prefix" => "Global:" },
						"style" => { "ruby_indentation" => "spaces" }
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path, "CARSON_REVIEW_DISPOSITION_PREFIX" => "Env:", "CARSON_RUBY_INDENTATION" => "either" ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "Env:", config.review_disposition_prefix
				assert_equal "either", config.ruby_indentation
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

private

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
end
