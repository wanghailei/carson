require_relative "test_helper"

class RuntimeLintSetupTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-lint-setup-test", carson_tmp_root )
		@repo_root = File.join( @tmp_dir, "repo" )
		FileUtils.mkdir_p( @repo_root )
		system( "git", "init", @repo_root, out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if @tmp_dir && File.directory?( @tmp_dir )
	end

	def test_lint_policy_copies_coding_files_to_github_linters
		source_root = build_source_tree( files: { "rubocop.yml" => "AllCops:\n  DisabledByDefault: true\n" } )
		runtime = build_runtime_for_setup

		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: source_root, ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert File.file?( File.join( @repo_root, ".github", "linters", "rubocop.yml" ) )
		end
	end

	def test_lint_policy_copies_multiple_config_files
		source_root = build_source_tree( files: {
			"rubocop.yml" => "AllCops:\n  DisabledByDefault: true\n",
			"ruff.toml" => "[lint]\nselect = [\"E\", \"F\"]\n",
			"biome.json" => "{}\n"
		} )
		runtime = build_runtime_for_setup

		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: source_root, ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_OK, status
			linters_dir = File.join( @repo_root, ".github", "linters" )
			assert File.file?( File.join( linters_dir, "rubocop.yml" ) )
			assert File.file?( File.join( linters_dir, "ruff.toml" ) )
			assert File.file?( File.join( linters_dir, "biome.json" ) )
		end
	end

	def test_lint_policy_clones_git_source_url
		source_root = build_git_source_repository
		runtime = build_runtime_for_setup

		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: "file://#{source_root}", ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert File.file?( File.join( @repo_root, ".github", "linters", "rubocop.yml" ) )
		end
	end

	def test_lint_policy_returns_runtime_error_when_source_is_missing
		runtime = build_runtime_for_setup
		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: File.join( @tmp_dir, "missing-source" ), ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_ERROR, status
		end
	end

private

	def build_runtime_for_setup
		config_path = File.join( @tmp_dir, "config.json" )
		File.write( config_path, JSON.generate( { "lint" => { "command" => "true" } } ) )
		with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => @tmp_dir ) do
			Carson::Runtime.new(
				repo_root: @repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				out: StringIO.new,
				err: StringIO.new,
				verbose: true
			)
		end
	end

	def build_source_tree( files: {} )
		source_root = File.join( @tmp_dir, "source" )
		FileUtils.mkdir_p( source_root )
		files.each do |name, content|
			File.write( File.join( source_root, name ), content )
		end
		source_root
	end

	def build_git_source_repository
		source_root = build_source_tree( files: { "rubocop.yml" => "AllCops:\n  DisabledByDefault: true\n" } )
		system( "git", "init", source_root, out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "config", "user.name", "Carson Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "config", "user.email", "carson-test@example.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "commit", "-m", "seed", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "branch", "-M", "main", out: File::NULL, err: File::NULL )
		source_root
	end

end
