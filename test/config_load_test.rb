require_relative "test_helper"

class ConfigLoadTest < Minitest::Test
	include CarsonTestSupport

	def test_default_scope_path_groups_include_install_script_under_tool
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_includes config.path_groups.fetch( "tool" ), "install.sh"
	end

	def test_default_lint_languages_include_core_language_keys
		config = Carson::Config.load( repo_root: Dir.pwd )
		%w[ruby javascript css html erb].each do |language|
			assert_includes config.lint_languages.keys, language
		end
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

	def test_lint_languages_override_loads_custom_command_and_paths
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"lint" => {
							"languages" => {
								"ruby" => {
									"enabled" => true,
									"globs" => [ "**/*.rb" ],
									"command" => [ "ruby", "~/AI/CODING/ruby/custom_lint.rb", "{files}" ],
									"config_files" => [ "~/AI/CODING/ruby/custom_lint.rb" ]
								}
							}
						}
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				ruby_entry = config.lint_languages.fetch( "ruby" )
				assert_equal [ "ruby", "~/AI/CODING/ruby/custom_lint.rb", "{files}" ], ruby_entry.fetch( :command )
				assert_equal [ File.expand_path( "~/AI/CODING/ruby/custom_lint.rb" ) ], ruby_entry.fetch( :config_files )
			end
		end
	end

	def test_invalid_lint_command_shape_raises_config_error
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"lint" => {
							"languages" => {
								"ruby" => {
									"enabled" => true,
									"globs" => [ "**/*.rb" ],
									"command" => "invalid",
									"config_files" => [ "~/AI/CODING/ruby/lint.rb" ]
								}
							}
						}
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_invalid_lint_globs_raises_config_error
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"lint" => {
							"languages" => {
								"ruby" => {
									"enabled" => true,
									"globs" => [],
									"command" => [ "ruby", "~/AI/CODING/ruby/lint.rb", "{files}" ],
									"config_files" => [ "~/AI/CODING/ruby/lint.rb" ]
								}
							}
						}
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_invalid_lint_enabled_type_raises_config_error_with_full_path
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write(
				config_path,
				JSON.generate(
					{
						"lint" => {
							"languages" => {
								"ruby" => {
									"enabled" => "yes",
									"globs" => [ "**/*.rb" ],
									"command" => [ "ruby", "~/AI/CODING/ruby/lint.rb", "{files}" ],
									"config_files" => [ "~/AI/CODING/ruby/lint.rb" ]
								}
							}
						}
					}
				)
			)
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				error = assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
				assert_match( /lint\.languages\.ruby\.enabled/, error.message )
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
