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

	def test_lint_setup_copies_coding_files_from_local_source
		source_root = build_source_tree( include_javascript: false )
		runtime = build_runtime_for_setup( include_javascript: false )

		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: source_root, ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert File.file?( File.join( @tmp_dir, "AI", "CODING", "ruby", "lint.rb" ) )
		end
	end

	def test_lint_setup_clones_git_source_url
		source_repo = build_git_source_repository
		runtime = build_runtime_for_setup( include_javascript: false )

		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: "file://#{source_repo}", ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert File.file?( File.join( @tmp_dir, "AI", "CODING", "ruby", "lint.rb" ) )
		end
	end

	def test_lint_setup_returns_runtime_error_when_source_is_missing
		runtime = build_runtime_for_setup( include_javascript: false )
		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: File.join( @tmp_dir, "missing-source" ), ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_ERROR, status
		end
	end

	def test_lint_setup_blocks_when_required_policy_files_are_still_missing
		source_root = build_source_tree( include_javascript: false )
		runtime = build_runtime_for_setup( include_javascript: true )
		with_env( "HOME" => @tmp_dir ) do
			status = runtime.lint_setup!( source: source_root, ref: "main", force: false )
			assert_equal Carson::Runtime::EXIT_BLOCK, status
		end
	end

private

	def build_runtime_for_setup( include_javascript: )
		config_path = File.join( @tmp_dir, "config.json" )
		languages = {
			"ruby" => {
				"enabled" => true,
				"globs" => [ "**/*.rb" ],
				"command" => [ "ruby", "~/AI/CODING/ruby/lint.rb", "{files}" ],
				"config_files" => [ "~/AI/CODING/ruby/lint.rb" ]
			},
			"javascript" => {
				"enabled" => false,
				"globs" => [ "**/*.js" ],
				"command" => [ "node", "/tmp/unused.js", "{files}" ],
				"config_files" => [ "/tmp/unused.js" ]
			},
			"css" => {
				"enabled" => false,
				"globs" => [ "**/*.css" ],
				"command" => [ "node", "/tmp/unused.js", "{files}" ],
				"config_files" => [ "/tmp/unused.js" ]
			},
			"html" => {
				"enabled" => false,
				"globs" => [ "**/*.html" ],
				"command" => [ "node", "/tmp/unused.js", "{files}" ],
				"config_files" => [ "/tmp/unused.js" ]
			},
			"erb" => {
				"enabled" => false,
				"globs" => [ "**/*.erb" ],
				"command" => [ "ruby", "/tmp/unused.rb", "{files}" ],
				"config_files" => [ "/tmp/unused.rb" ]
			}
		}
		if include_javascript
			languages[ "javascript" ] = {
				"enabled" => true,
				"globs" => [ "**/*.js" ],
				"command" => [ "node", "~/AI/CODING/javascript/lint.js", "{files}" ],
				"config_files" => [ "~/AI/CODING/javascript/lint.js" ]
			}
		end
		File.write( config_path, JSON.generate( { "lint" => { "languages" => languages } } ) )
		with_env( "CARSON_CONFIG_FILE" => config_path, "HOME" => @tmp_dir ) do
			Carson::Runtime.new(
				repo_root: @repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				out: StringIO.new,
				err: StringIO.new
			)
		end
	end

	def build_source_tree( include_javascript: )
		source_root = File.join( @tmp_dir, "source" )
		FileUtils.mkdir_p( File.join( source_root, "CODING", "ruby" ) )
		File.write( File.join( source_root, "CODING", "ruby", "lint.rb" ), "#!/usr/bin/env ruby\nexit 0\n" )
		if include_javascript
			FileUtils.mkdir_p( File.join( source_root, "CODING", "javascript" ) )
			File.write( File.join( source_root, "CODING", "javascript", "lint.js" ), "process.exit( 0 )\n" )
		end
		source_root
	end

	def build_git_source_repository
		source_root = build_source_tree( include_javascript: false )
		system( "git", "init", source_root, out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "config", "user.name", "Carson Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "config", "user.email", "carson-test@example.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "commit", "-m", "seed", out: File::NULL, err: File::NULL )
		system( "git", "-C", source_root, "branch", "-M", "main", out: File::NULL, err: File::NULL )
		source_root
	end

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
