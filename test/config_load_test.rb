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

	def test_default_lint_command_is_nil
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_nil config.lint_command
	end

	def test_default_lint_enforcement_is_strict
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_equal "strict", config.lint_enforcement
	end

	def test_default_lint_policy_source
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_equal "wanghailei/lint.git", config.lint_policy_source
	end

	def test_lint_command_string_value
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "command" => "make lint" } } ) )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "make lint", config.lint_command
			end
		end
	end

	def test_lint_command_array_value
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "command" => [ "trunk", "check" ] } } ) )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal [ "trunk", "check" ], config.lint_command
			end
		end
	end

	def test_lint_enforcement_advisory
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "enforcement" => "advisory" } } ) )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "advisory", config.lint_enforcement
			end
		end
	end

	def test_lint_enforcement_invalid_raises_config_error
		Dir.mktmpdir( "carson-config-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "enforcement" => "maybe" } } ) )
			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				assert_raises( Carson::ConfigError ) { Carson::Config.load( repo_root: dir ) }
			end
		end
	end

	def test_lint_command_env_override
		with_env( "CARSON_LINT_COMMAND" => "ruff check" ) do
			config = Carson::Config.load( repo_root: Dir.pwd )
			assert_equal "ruff check", config.lint_command
		end
	end

end
