# Tests for the template.canonical config key.
# Verifies that canonical files are discovered and appended to managed_files,
# and that absence of canonical config is a no-op.
require_relative "test_helper"

class ConfigCanonicalTest < Minitest::Test
	include CarsonTestSupport

	def test_default_canonical_is_nil
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_nil config.template_canonical
	end

	def test_canonical_discovers_files_and_appends_to_managed_files
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			# Create a canonical directory with two files.
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( File.join( canonical_dir, "workflows" ) )
			File.write( File.join( canonical_dir, "workflows", "lint.yml" ), "name: Lint\n" )
			File.write( File.join( canonical_dir, "dependabot.yml" ), "version: 2\n" )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal canonical_dir, config.template_canonical
				assert_includes config.template_managed_files, ".github/dependabot.yml"
				assert_includes config.template_managed_files, ".github/workflows/lint.yml"
			end
		end
	end

	def test_canonical_does_not_duplicate_existing_managed_files
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			# Create a canonical directory containing a file that Carson already manages.
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "carson.md" ), "override\n" )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				# .github/carson.md should appear exactly once.
				count = config.template_managed_files.count { |f| f == ".github/carson.md" }
				assert_equal 1, count
			end
		end
	end

	def test_canonical_absent_directory_is_noop
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => "/nonexistent/path" } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "/nonexistent/path", config.template_canonical
				# Only Carson's built-in governance files should be present.
				assert_equal 5, config.template_managed_files.count
			end
		end
	end

	def test_canonical_nil_value_is_noop
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_nil config.template_canonical
		assert_equal 5, config.template_managed_files.count
	end

	def test_lint_files_are_superseded
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_includes config.template_superseded_files, ".github/workflows/carson-lint.yml"
		assert_includes config.template_superseded_files, ".github/.mega-linter.yml"
		refute_includes config.template_managed_files, ".github/workflows/carson-lint.yml"
		refute_includes config.template_managed_files, ".github/.mega-linter.yml"
	end

	def test_canonical_path_expands_tilde
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => "~/some-dir" } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => dir ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal File.join( dir, "some-dir" ), config.template_canonical
			end
		end
	end
end
