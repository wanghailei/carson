require_relative "test_helper"
require "rbconfig"

class RuntimeAuditLintTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmp_dir = Dir.mktmpdir( "carson-audit-lint-test", carson_tmp_root )
		@repo_root = File.join( @tmp_dir, "repo" )
		FileUtils.mkdir_p( @repo_root )
		system( "git", "init", @repo_root, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "config", "user.name", "Carson Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "config", "user.email", "carson-test@example.com", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_root, "README.md" ), "lint test\n" )
		system( "git", "-C", @repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "commit", "-m", "initial", out: File::NULL, err: File::NULL )
	end

	def teardown
		FileUtils.remove_entry( @tmp_dir ) if @tmp_dir && File.directory?( @tmp_dir )
	end

	def test_local_lint_quality_blocks_when_required_global_rubocop_config_is_missing
		with_env( "HOME" => @tmp_dir ) do
			runtime = build_runtime_with_carson_ruby_runner
			stage_ruby_file( relative_path: "lib/missing_config.rb", content: "puts :ok\n" )

			report = runtime.send( :local_lint_quality_report )
			assert_equal "block", report.fetch( :status )
			ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
			assert_equal "block", ruby_entry.fetch( :status )
			assert_match( /missing config files/, ruby_entry.fetch( :reason ) )
			assert_match( /\.carson\/lint\/rubocop\.yml/, ruby_entry.fetch( :reason ) )
		end
	end

	def test_local_lint_quality_blocks_when_command_is_unavailable
		config_path = File.join( @tmp_dir, "policy.rb" )
		File.write( config_path, "# policy\n" )
		runtime = build_runtime_with_lint_config(
			command: [ "missing-carson-lint-command", "{files}" ],
			config_files: [ config_path ]
		)
		stage_ruby_file( relative_path: "lib/missing_command.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
		assert_equal "block", ruby_entry.fetch( :status )
		assert_match( /command not available/, ruby_entry.fetch( :reason ) )
	end

	def test_local_lint_quality_blocks_when_rubocop_executable_is_unavailable
		path_dir = build_path_dir_with_git( name: "without-rubocop" )
		with_env( "HOME" => @tmp_dir, "PATH" => "#{path_dir}:#{system_runtime_path}" ) do
			write_global_rubocop_config
			runtime = build_runtime_with_carson_ruby_runner
			stage_ruby_file( relative_path: "lib/rubocop_unavailable.rb", content: "puts :ok\n" )

			report = runtime.send( :local_lint_quality_report )
			assert_equal "block", report.fetch( :status )
			ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
			assert_equal "block", ruby_entry.fetch( :status )
			assert_match( /RuboCop executable/, ruby_entry.fetch( :reason ) )
		end
	end

	def test_local_lint_quality_blocks_when_rubocop_reports_offences
		path_dir = build_path_dir_with_git( name: "mock-bin-offence" )
		write_mock_rubocop(
			path: File.join( path_dir, "rubocop" ),
			body: "#!#{RbConfig.ruby}\nputs \"offence: Layout/LineLength\"\nexit 1\n"
		)
		with_env( "HOME" => @tmp_dir, "PATH" => "#{path_dir}:#{system_runtime_path}" ) do
			write_global_rubocop_config
			runtime = build_runtime_with_carson_ruby_runner
			stage_ruby_file( relative_path: "lib/rubocop_offence.rb", content: "puts :ok\n" )

			report = runtime.send( :local_lint_quality_report )
			assert_equal "block", report.fetch( :status )
			ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
			assert_equal "block", ruby_entry.fetch( :status )
			assert_match( /offence:/, ruby_entry.fetch( :reason ) )
		end
	end

	def test_local_lint_quality_passes_when_rubocop_reports_clean
		path_dir = build_path_dir_with_git( name: "mock-bin-clean" )
		write_mock_rubocop(
			path: File.join( path_dir, "rubocop" ),
			body: "#!#{RbConfig.ruby}\nputs \"clean\"\nexit 0\n"
		)
		with_env( "HOME" => @tmp_dir, "PATH" => "#{path_dir}:#{system_runtime_path}" ) do
			write_global_rubocop_config
			runtime = build_runtime_with_carson_ruby_runner
			stage_ruby_file( relative_path: "lib/rubocop_clean.rb", content: "puts :ok\n" )

			report = runtime.send( :local_lint_quality_report )
			assert_equal "ok", report.fetch( :status )
			ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
			assert_equal "ok", ruby_entry.fetch( :status )
		end
	end

	def test_local_lint_quality_blocks_when_command_reports_failure
		policy_script = executable_script( name: "lint_fail", body: "#!/usr/bin/env ruby\nwarn \"lint fail\"\nexit 1\n" )
		runtime = build_runtime_with_lint_config(
			command: [ policy_script, "{files}" ],
			config_files: [ policy_script ]
		)
		stage_ruby_file( relative_path: "lib/lint_failure.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
		assert_equal "block", ruby_entry.fetch( :status )
		assert_match( /lint fail/, ruby_entry.fetch( :reason ) )
	end

	def test_local_lint_quality_passes_when_command_succeeds
		policy_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_config(
			command: [ policy_script, "{files}" ],
			config_files: [ policy_script ]
		)
		stage_ruby_file( relative_path: "lib/lint_ok.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "ok", report.fetch( :status )
		ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
		assert_equal "ok", ruby_entry.fetch( :status )
		assert_equal "staged", report.fetch( :target_source )
	end

	def test_local_lint_quality_blocks_when_repo_local_rubocop_config_exists
		policy_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_config(
			command: [ policy_script, "{files}" ],
			config_files: [ policy_script ]
		)
		File.write( File.join( @repo_root, ".rubocop.yml" ), "AllCops:\n  DisabledByDefault: true\n" )
		stage_ruby_file( relative_path: "lib/local_rubocop.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
		assert_equal "block", ruby_entry.fetch( :status )
		assert_match( /repo-local RuboCop config is forbidden/, ruby_entry.fetch( :reason ) )
	end

	def test_lint_target_files_uses_full_repository_for_github_non_pr_events
		policy_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_config(
			command: [ policy_script, "{files}" ],
			config_files: [ policy_script ]
		)
		FileUtils.mkdir_p( File.join( @repo_root, "lib" ) )
		File.write( File.join( @repo_root, "lib", "tracked.rb" ), "puts :tracked\n" )
		system( "git", "-C", @repo_root, "add", "lib/tracked.rb", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "commit", "-m", "tracked", out: File::NULL, err: File::NULL )

		with_env(
			"GITHUB_ACTIONS" => "true",
			"GITHUB_EVENT_NAME" => "workflow_dispatch",
			"GITHUB_BASE_REF" => ""
		) do
			files, source = runtime.send( :lint_target_files )
			assert_equal "github_full_repository", source
			assert_includes files, "lib/tracked.rb"
		end
	end

	def test_lint_target_files_for_pull_request_uses_configured_remote_name
		policy_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_config(
			command: [ policy_script, "{files}" ],
			config_files: [ policy_script ]
		)

		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "branch", "-M", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "github", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "github", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "switch", "-c", "feature/lint-target", out: File::NULL, err: File::NULL )

		FileUtils.mkdir_p( File.join( @repo_root, "lib" ) )
		File.write( File.join( @repo_root, "lib", "feature_change.rb" ), "puts :feature\n" )
		system( "git", "-C", @repo_root, "add", "lib/feature_change.rb", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "commit", "-m", "feature", out: File::NULL, err: File::NULL )

		with_env(
			"GITHUB_ACTIONS" => "true",
			"GITHUB_EVENT_NAME" => "pull_request",
			"GITHUB_BASE_REF" => "main"
		) do
			files, source = runtime.send( :lint_target_files )
			assert_equal "github_pull_request", source
			assert_includes files, "lib/feature_change.rb"
		end
	end

private

	def stage_ruby_file( relative_path:, content: )
		absolute_path = File.join( @repo_root, relative_path )
		FileUtils.mkdir_p( File.dirname( absolute_path ) )
		File.write( absolute_path, content )
		system( "git", "-C", @repo_root, "add", relative_path, out: File::NULL, err: File::NULL )
	end

	def executable_script( name:, body: )
		path = File.join( @tmp_dir, "#{name}.rb" )
		File.write( path, body )
		FileUtils.chmod( 0o755, path )
		path
	end

	def write_mock_rubocop( path:, body: )
		File.write( path, body )
		FileUtils.chmod( 0o755, path )
	end

	def write_global_rubocop_config
		path = File.join( ENV.fetch( "HOME" ), ".carson", "lint", "rubocop.yml" )
		FileUtils.mkdir_p( File.dirname( path ) )
		File.write( path, "AllCops:\n  DisabledByDefault: true\n" )
	end

	def build_path_dir_with_git( name: )
		path_dir = File.join( @tmp_dir, name )
		FileUtils.mkdir_p( path_dir )
		git_executable = ENV.fetch( "PATH" ).split( File::PATH_SEPARATOR ).map { |entry| File.join( entry, "git" ) }.find do |candidate|
			File.file?( candidate ) && File.executable?( candidate )
		end
		raise "git executable not found in PATH for test harness" if git_executable.nil?
		FileUtils.ln_sf( git_executable, File.join( path_dir, "git" ) )
		path_dir
	end

	def system_runtime_path
		"/usr/bin:/bin:/usr/sbin:/sbin"
	end

	def build_runtime_with_carson_ruby_runner
		build_runtime_with_lint_config(
			command: [ RbConfig.ruby, File.expand_path( "../lib/carson/policy/ruby/lint.rb", __dir__ ), "{files}" ],
			config_files: [ "~/.carson/lint/rubocop.yml" ]
		)
	end

	def build_runtime_with_lint_config( command:, config_files: )
		config_path = File.join( @tmp_dir, "config.json" )
		File.write(
			config_path,
			JSON.generate(
				{
					"lint" => {
						"languages" => {
							"ruby" => {
								"enabled" => true,
								"globs" => [ "**/*.rb" ],
								"command" => command,
								"config_files" => config_files
							},
							"javascript" => { "enabled" => false, "globs" => [ "**/*.js" ], "command" => [ "node", "lint.js", "{files}" ], "config_files" => [ "/tmp/ignore.js" ] },
							"css" => { "enabled" => false, "globs" => [ "**/*.css" ], "command" => [ "node", "lint.js", "{files}" ], "config_files" => [ "/tmp/ignore.css" ] },
							"html" => { "enabled" => false, "globs" => [ "**/*.html" ], "command" => [ "node", "lint.js", "{files}" ], "config_files" => [ "/tmp/ignore.html" ] },
							"erb" => { "enabled" => false, "globs" => [ "**/*.erb" ], "command" => [ "ruby", "lint.rb", "{files}" ], "config_files" => [ "/tmp/ignore.erb" ] }
						}
					}
				}
			)
		)
		runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: @repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				out: out,
				err: err
			)
		end
		runtime
	end

end
