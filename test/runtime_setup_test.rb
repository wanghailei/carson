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

		# 5 prompts: remote, branch, workflow, merge, canonical template
		tty_input = build_tty_input( "\n\n\n\n\n" )

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

		tty_input = build_tty_input( "2\n\n\n\n\n" )

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

	def test_normalise_remote_url_treats_ssh_and_https_as_equal
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )

			ssh_url = "git@github.com:user/repo.git"
			https_url = "https://github.com/user/repo"
			https_with_git = "https://github.com/user/repo.git"

			normalised_ssh = runtime.send( :normalise_remote_url, url: ssh_url )
			normalised_https = runtime.send( :normalise_remote_url, url: https_url )
			normalised_https_git = runtime.send( :normalise_remote_url, url: https_with_git )

			assert_equal normalised_ssh, normalised_https, "SSH and HTTPS URLs should normalise to the same value"
			assert_equal normalised_ssh, normalised_https_git, "SSH and HTTPS+.git URLs should normalise to the same value"

			# Trailing slash stripped
			assert_equal(
				runtime.send( :normalise_remote_url, url: "https://github.com/user/repo/" ),
				normalised_https
			)

			# Empty and blank
			assert_equal "", runtime.send( :normalise_remote_url, url: "" )
			assert_equal "", runtime.send( :normalise_remote_url, url: "  " )
		end
	end

	def test_setup_warns_about_duplicate_remote_urls
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "github", remote_dir, out: File::NULL, err: File::NULL )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: StringIO.new, out_stream: out )
			runtime.setup!

			output = out.string
			assert_match( /duplicate_remotes:.*share the same URL/, output )
		end
	end

	# --- Governance registration tests ---

	def test_onboard_auto_registers_repo
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# 5 setup prompts (enter defaults); governance registration is automatic
		tty_input = build_tty_input( "\n\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_onboard_runtime( input: tty_input, out_stream: out )
			status = runtime.onboard!

			assert_equal Carson::Runtime::EXIT_OK, status
			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			repos = saved.dig( "govern", "repos" ) || []
			assert_includes repos, File.expand_path( @repo_root )
			assert_includes out.string, "Registered for portfolio governance."
		end
	end

	def test_onboard_skips_registration_when_already_registered
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# Pre-populate config with the repo already registered
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ File.expand_path( @repo_root ) ] } } ) )

		# No setup prompts needed (config exists), no registration message expected
		tty_input = build_tty_input( "" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_onboard_runtime( input: tty_input, out_stream: out )
			runtime.onboard!

			refute_includes out.string, "Registered for portfolio governance."
		end
	end

	def test_onboard_non_interactive_auto_registers
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )

		# Non-TTY input — registration should still happen automatically
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_onboard_runtime( input: StringIO.new, out_stream: out )
			runtime.onboard!

			assert_includes out.string, "Registered for portfolio governance."
			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			repos = saved.dig( "govern", "repos" ) || []
			assert_includes repos, File.expand_path( @repo_root )
		end
	end

	def test_onboard_reruns_setup_when_configured_remote_missing
		# Config exists with remote "upstream", but repo only has "origin"
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "git" => { "remote" => "upstream" } } ) )

		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# Setup will prompt (5 prompts: remote, branch, workflow, merge, canonical); governance auto-registers
		tty_input = build_tty_input( "\n\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_onboard_runtime( input: tty_input, out_stream: out )
			status = runtime.onboard!

			assert_equal Carson::Runtime::EXIT_OK, status
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "origin", saved.dig( "git", "remote" ), "setup should fix the remote to one that exists"
		end
	end

	def test_append_govern_repo_deduplicates
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( {} ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.send( :append_govern_repo!, repo_path: "/tmp/test-repo" )
			runtime.send( :append_govern_repo!, repo_path: "/tmp/test-repo" )

			saved = JSON.parse( File.read( config_path ) )
			repos = saved.dig( "govern", "repos" )
			assert_equal 1, repos.length
			assert_equal "/tmp/test-repo", repos.first
		end
	end

	def test_append_govern_repo_preserves_existing_config
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "workflow" => { "style" => "trunk" }, "git" => { "remote" => "github" } } ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.send( :append_govern_repo!, repo_path: "/tmp/my-repo" )

			saved = JSON.parse( File.read( config_path ) )
			assert_equal "trunk", saved.dig( "workflow", "style" ), "existing workflow.style should be preserved"
			assert_equal "github", saved.dig( "git", "remote" ), "existing git.remote should be preserved"
			assert_includes saved.dig( "govern", "repos" ), "/tmp/my-repo"
		end
	end

	# --- Governance deregistration tests ---

	def test_remove_govern_repo_removes_registered_path
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/test-repo" ] } } ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.send( :remove_govern_repo!, repo_path: "/tmp/test-repo" )

			saved = JSON.parse( File.read( config_path ) )
			repos = saved.dig( "govern", "repos" ) || []
			assert_empty repos
		end
	end

	def test_remove_govern_repo_preserves_other_repos
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/repo-a", "/tmp/repo-b", "/tmp/repo-c" ] } } ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.send( :remove_govern_repo!, repo_path: "/tmp/repo-b" )

			saved = JSON.parse( File.read( config_path ) )
			repos = saved.dig( "govern", "repos" )
			assert_equal [ "/tmp/repo-a", "/tmp/repo-c" ], repos
		end
	end

	def test_remove_govern_repo_noop_when_not_registered
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		original = { "govern" => { "repos" => [ "/tmp/repo-a" ] }, "workflow" => { "style" => "trunk" } }
		File.write( config_path, JSON.generate( original ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.send( :remove_govern_repo!, repo_path: "/tmp/not-registered" )

			saved = JSON.parse( File.read( config_path ) )
			assert_equal [ "/tmp/repo-a" ], saved.dig( "govern", "repos" )
			assert_equal "trunk", saved.dig( "workflow", "style" ), "existing config should be untouched"
		end
	end

	def test_offboard_deregisters_govern_repo
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		expanded_repo = File.expand_path( @repo_root )

		# Onboard first (non-interactive) to install hooks + register govern
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ expanded_repo ] } } ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			# Verify repo is registered
			pre_config = JSON.parse( File.read( config_path ) )
			assert_includes pre_config.dig( "govern", "repos" ), expanded_repo

			# Offboard
			out = StringIO.new
			runtime = build_onboard_runtime( input: StringIO.new, out_stream: out )
			status = runtime.offboard!
			assert_equal Carson::Runtime::EXIT_OK, status

			# Verify repo is deregistered
			post_config = JSON.parse( File.read( config_path ) )
			repos = post_config.dig( "govern", "repos" ) || []
			refute_includes repos, expanded_repo
		end
	end

	# --- Canonical template prompt tests ---

	def test_setup_interactive_canonical_path_accepted
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# 4 default prompts + canonical path
		tty_input = build_tty_input( "\n\n\n\n/tmp/my-templates\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: tty_input, out_stream: out )
			runtime.setup!

			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "/tmp/my-templates", saved.dig( "template", "canonical" )
		end
	end

	def test_setup_interactive_canonical_blank_skipped
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# 4 default prompts + blank canonical
		tty_input = build_tty_input( "\n\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: tty_input )
			runtime.setup!

			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_nil saved.dig( "template", "canonical" ), "blank input should not write template.canonical"
		end
	end

	def test_setup_interactive_canonical_shows_existing_value
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "template" => { "canonical" => "/existing/path" } } ) )

		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# 4 default prompts + blank canonical (keep existing)
		tty_input = build_tty_input( "\n\n\n\n\n" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: tty_input, out_stream: out )
			runtime.setup!

			assert_match( /Currently set to: \/existing\/path/, out.string )
		end
	end

	# --- CLI choices (non-interactive flags) tests ---

	def test_setup_cli_choices_writes_remote
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			status = runtime.setup!( cli_choices: { "git.remote" => "github" } )

			assert_equal Carson::Runtime::EXIT_OK, status
			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "github", saved.dig( "git", "remote" )
		end
	end

	def test_setup_cli_choices_writes_multiple_values
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			status = runtime.setup!( cli_choices: {
				"git.remote" => "upstream",
				"git.main_branch" => "main",
				"workflow.style" => "trunk",
				"govern.merge.method" => "rebase",
				"template.canonical" => "/tmp/canonical"
			} )

			assert_equal Carson::Runtime::EXIT_OK, status
			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "upstream", saved.dig( "git", "remote" )
			assert_equal "main", saved.dig( "git", "main_branch" )
			assert_equal "trunk", saved.dig( "workflow", "style" )
			assert_equal "rebase", saved.dig( "govern", "merge", "method" )
			assert_equal "/tmp/canonical", saved.dig( "template", "canonical" )
		end
	end

	def test_setup_cli_choices_merges_with_existing_config
		config_dir = File.join( @tmp_dir, ".carson" )
		FileUtils.mkdir_p( config_dir )
		config_path = File.join( config_dir, "config.json" )
		File.write( config_path, JSON.generate( { "workflow" => { "style" => "branch" } } ) )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			runtime = build_setup_runtime( input: StringIO.new )
			runtime.setup!( cli_choices: { "git.remote" => "github" } )

			saved = JSON.parse( File.read( config_path ) )
			assert_equal "github", saved.dig( "git", "remote" ), "cli_choices remote should be saved"
			assert_equal "branch", saved.dig( "workflow", "style" ), "existing workflow style should be preserved"
		end
	end

	def test_setup_cli_choices_skips_interactive_prompts
		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )

		# TTY input that would fail if prompts were actually shown (no input lines)
		tty_input = build_tty_input( "" )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: tty_input, out_stream: out )
			status = runtime.setup!( cli_choices: { "git.remote" => "origin" } )

			assert_equal Carson::Runtime::EXIT_OK, status
			# Should not contain interactive prompt text
			refute_includes out.string, "Git remote"
			refute_includes out.string, "Main branch"
			refute_includes out.string, "Workflow style"
		end
	end

	def test_setup_empty_cli_choices_falls_through_to_normal_behaviour
		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			runtime = build_setup_runtime( input: StringIO.new, out_stream: out )
			status = runtime.setup!( cli_choices: {} )

			assert_equal Carson::Runtime::EXIT_OK, status
			# Non-TTY input with empty cli_choices should run silent_setup
			assert_match( /detected_remote:/, out.string )
		end
	end

	def test_setup_cli_choices_outside_git_repo_writes_config
		non_git_dir = File.join( @tmp_dir, "not-a-repo" )
		FileUtils.mkdir_p( non_git_dir )

		with_env( "HOME" => @tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: non_git_dir,
				tool_root: File.expand_path( "..", __dir__ ),
				out: out,
				err: err,
				in_stream: StringIO.new,
				verbose: true
			)
			status = runtime.setup!( cli_choices: { "workflow.style" => "trunk" } )

			assert_equal Carson::Runtime::EXIT_OK, status
			config_path = File.join( @tmp_dir, ".carson", "config.json" )
			saved = JSON.parse( File.read( config_path ) )
			assert_equal "trunk", saved.dig( "workflow", "style" )
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

	def build_onboard_runtime( input:, out_stream: nil )
		out = out_stream || StringIO.new
		err = StringIO.new
		Carson::Runtime.new(
			repo_root: @repo_root,
			tool_root: File.expand_path( "..", __dir__ ),
			out: out,
			err: err,
			in_stream: input,
			verbose: false
		)
	end
end
