# Tests for the lint.canonical config key and legacy template.canonical alias.
# Verifies that canonical files are discovered and appended to managed_files,
# and that absence of canonical config is a no-op.
require_relative "test_helper"

class ConfigCanonicalTest < Minitest::Test
	include CarsonTestSupport

	def test_default_canonical_is_nil
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_nil config.lint_canonical
		assert_nil config.template_canonical
	end

	def test_canonical_discovers_files_and_appends_to_managed_files
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			# Explicit .github files stay rooted under .github; flat policy files go to .github/linters.
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( File.join( canonical_dir, "workflows" ) )
			File.write( File.join( canonical_dir, "workflows", "lint.yml" ), "name: Lint\n" )
			File.write( File.join( canonical_dir, "labeler.yml" ), "bug:\n" )
			File.write( File.join( canonical_dir, "rubocop.yml" ), "AllCops:\n" )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal canonical_dir, config.lint_canonical
				assert_equal canonical_dir, config.template_canonical
				assert_includes config.template_managed_files, ".github/labeler.yml"
				assert_includes config.template_managed_files, ".github/linters/rubocop.yml"
				assert_includes config.template_managed_files, ".github/workflows/lint.yml"
			end
		end
	end

	def test_canonical_honours_explicit_dot_github_paths
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( File.join( canonical_dir, ".github" ) )
			File.write( File.join( canonical_dir, ".github", "release-drafter.yml" ), "template: notes\n" )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_includes config.template_managed_files, ".github/release-drafter.yml"
			end
		end
	end

	def test_legacy_template_canonical_alias_still_loads
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal canonical_dir, config.lint_canonical
				assert_equal canonical_dir, config.template_canonical
			end
		end
	end

	def test_lint_canonical_wins_over_legacy_template_alias
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate(
				{
					"lint" => { "canonical" => "/tmp/new-canonical" },
					"template" => { "canonical" => "/tmp/old-canonical" }
				}
			) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "/tmp/new-canonical", config.lint_canonical
				assert_equal "/tmp/new-canonical", config.template_canonical
			end
		end
	end

	def test_canonical_does_not_duplicate_managed_files
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			# Create a canonical directory containing a known GitHub root file.
			canonical_dir = File.join( dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "carson.md" ), "override\n" )

			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				# .github/carson.md should appear exactly once.
				count = config.template_managed_files.count { |file| file == ".github/carson.md" }
				assert_equal 1, count
			end
		end
	end

	def test_canonical_absent_directory_is_noop
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => "/nonexistent/path" } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal "/nonexistent/path", config.lint_canonical
				assert_equal "/nonexistent/path", config.template_canonical
				# No built-in governance files; managed_files is empty by default.
				assert_equal 0, config.template_managed_files.count
			end
		end
	end

	def test_canonical_nil_value_is_noop
		config = Carson::Config.load( repo_root: Dir.pwd )
		assert_nil config.lint_canonical
		assert_nil config.template_canonical
		assert_equal 0, config.template_managed_files.count
	end

	def test_lint_files_are_superseded
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/biome.json"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/erb-lint.yml"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/rubocop.yml"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/ruff.toml"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/workflows/carson-lint.yml"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/.mega-linter.yml"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/carson.md"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/copilot-instructions.md"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/CLAUDE.md"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/AGENTS.md"
		assert_includes Carson::Runtime::Local::SUPERSEDED, ".github/pull_request_template.md"
		config = Carson::Config.load( repo_root: Dir.pwd )
		refute_includes config.template_managed_files, ".github/workflows/carson-lint.yml"
		refute_includes config.template_managed_files, ".github/.mega-linter.yml"
	end

	def test_canonical_path_expands_tilde
		Dir.mktmpdir( "carson-canonical-test", carson_tmp_root ) do |dir|
			config_path = File.join( dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => "~/some-dir" } } ) )

			with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => dir ) do
				config = Carson::Config.load( repo_root: dir )
				assert_equal File.join( dir, "some-dir" ), config.lint_canonical
				assert_equal File.join( dir, "some-dir" ), config.template_canonical
			end
		end
	end
end
