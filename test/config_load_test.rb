require_relative "test_helper"

class ConfigLoadTest < Minitest::Test
	include ButlerTestSupport

	def test_default_scope_pattern_is_lane_first
		config = Butler::Config.load( repo_root: Dir.pwd )
		assert_match config.branch_regex, "tool/review-refactor"
		refute_match config.branch_regex, "codex/tool/review-refactor"
	end

	def test_env_overrides_global_config_values
		Dir.mktmpdir( "butler-config-test", butler_tmp_root ) do |dir|
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
			with_env( "BUTLER_CONFIG_FILE" => config_path, "BUTLER_REVIEW_DISPOSITION_PREFIX" => "Env:", "BUTLER_RUBY_INDENTATION" => "either" ) do
				config = Butler::Config.load( repo_root: dir )
				assert_equal "Env:", config.review_disposition_prefix
				assert_equal "either", config.ruby_indentation
			end
		end
	end

	def test_invalid_global_config_raises_config_error
		Dir.mktmpdir( "butler-config-test", butler_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, "{invalid-json" )
			with_env( "BUTLER_CONFIG_FILE" => config_path ) do
				assert_raises( Butler::ConfigError ) { Butler::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_invalid_global_config_shape_raises_config_error
		Dir.mktmpdir( "butler-config-test", butler_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "review" => "invalid" } ) )
			with_env( "BUTLER_CONFIG_FILE" => config_path ) do
				assert_raises( Butler::ConfigError ) { Butler::Config.load( repo_root: dir ) }
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
