require_relative "test_helper"

class RuntimeSetupTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-setup-test", carson_tmp_root )
		@repo_root = File.join( @tmp_dir, "repo" )
		FileUtils.mkdir_p( @repo_root )
		system( "git", "init", @repo_root, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "config", "user.name", "Carson Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "config", "user.email", "carson-test@example.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "switch", "-c", "main", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_root, "README.md" ), "setup test\n" )
		system( "git", "-C", @repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "commit", "-m", "initial", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if @tmp_dir && File.directory?( @tmp_dir )
	end

	def test_setup_writes_config_file_with_non_tty_input
		config_path = File.join( @tmp_dir, ".carson", "config.json" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			status = runtime.setup!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert File.file?( config_path ), "config.json should be created"
		end
	end

	def test_setup_detects_single_remote_silently
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: StringIO.new, out_stream: out )
			runtime.setup!

			output = out.string
			assert_match( /detected_remote: origin/, output )
		end
	end

	def test_setup_detects_well_known_remote_over_custom
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "custom", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: StringIO.new, out_stream: out )
			runtime.setup!

			output = out.string
			assert_match( /detected_remote: origin/, output )
		end
	end

	def test_setup_handles_no_remotes
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: StringIO.new, out_stream: out )
			runtime.setup!

			output = out.string
			assert_match( /detected_remote: none/, output )
		end
	end

	def test_setup_merges_with_existing_config
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "workflow" => { "style" => "branch" } } ) )

		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "upstream", remote_dir, out: File::NULL, err: File::NULL )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.setup!

			saved = JSON.parse( File.read( config_path ) )
			assert_equal "branch", saved.dig( "workflow", "style" ), "existing workflow style should be preserved"
			assert_equal "upstream", saved.dig( "git", "remote" ), "detected remote should be saved"
		end
	end

	def test_setup_interactive_accepts_defaults
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		tty_input = build_tty_input( "\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: tty_input, out_stream: out )
			status = runtime.setup!

			assert_equal Carson::Runtime::EXIT_OK, status
			output = out.string
			assert_match( /Config saved/, output )
		end
	end

	def test_setup_interactive_selects_second_option
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "upstream", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		tty_input = build_tty_input( "2\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: tty_input )
			runtime.setup!

			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "upstream", saved.dig( "git", "remote" )
		end
	end

	def test_detect_git_remote_returns_config_remote_when_it_exists
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			detected = runtime.send( :detect_git_remote )
			assert_equal "origin", detected
		end
	end

	def test_detect_main_branch_returns_main_when_it_exists
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			detected = runtime.send( :detect_main_branch )
			assert_equal "main", detected
		end
	end

	def test_global_config_exists_returns_false_when_no_config
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			refute runtime.send( :global_config_exists? )
		end
	end

	def test_global_config_exists_returns_true_when_config_present
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		File.write( File.join( config_dir, "config.json" ), "{}" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			assert runtime.send( :global_config_exists? )
		end
	end

private

	def build_setup_runtime( input:, out_stream: nil )
		out = out_stream || StringIO.new
		err = StringIO.new
		Carson::Runtime.new(
			repo_root: @repo_root,
			tool_root: File.expand_path( "..", __dir__ ),
			out: out,
			err: err,
			in_stream: input,
			verbose: true
		)
	end

	# Simulates a TTY input stream for interactive prompts.
	def build_tty_input( text )
		io = StringIO.new( text )
		io.define_singleton_method( :tty? ) { true }
		io
	end
end
