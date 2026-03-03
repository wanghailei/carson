require_relative "test_helper"

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

	def test_lint_command_blocks_when_command_fails
		fail_script = executable_script( name: "lint_cmd_fail", body: "#!/usr/bin/env ruby\nwarn \"lint command failed\"\nexit 1\n" )
		runtime = build_runtime_with_lint_command( command: fail_script )
		stage_ruby_file( relative_path: "lib/lint_cmd_fail.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		assert_equal 1, report.fetch( :blocking_languages )
		entry = report.fetch( :languages ).first
		assert_equal "lint.command", entry.fetch( :language )
		assert_equal "block", entry.fetch( :status )
	end

	def test_lint_command_passes_when_command_succeeds
		ok_script = executable_script( name: "lint_cmd_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_command( command: ok_script )
		stage_ruby_file( relative_path: "lib/lint_cmd_ok.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "ok", report.fetch( :status )
		entry = report.fetch( :languages ).first
		assert_equal "lint.command", entry.fetch( :language )
		assert_equal "ok", entry.fetch( :status )
	end

	def test_lint_command_advisory_mode_warns_but_does_not_block
		fail_script = executable_script( name: "lint_cmd_advisory", body: "#!/usr/bin/env ruby\nwarn \"lint problem\"\nexit 1\n" )
		runtime = build_runtime_with_lint_command( command: fail_script, enforcement: "advisory" )
		stage_ruby_file( relative_path: "lib/lint_advisory.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "ok", report.fetch( :status ), "advisory mode should not block"
		assert_equal 0, report.fetch( :blocking_languages )
		entry = report.fetch( :languages ).first
		assert_equal "block", entry.fetch( :status ), "the language entry itself still reports block"
	end

	def test_lint_command_blocks_when_command_unavailable
		runtime = build_runtime_with_lint_command( command: "nonexistent-carson-lint-tool" )
		stage_ruby_file( relative_path: "lib/missing_cmd.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		entry = report.fetch( :languages ).first
		assert_match( /command not available/, entry.fetch( :reason ) )
	end

	def test_lint_skips_when_command_not_configured
		runtime = build_runtime_without_lint_command
		stage_ruby_file( relative_path: "lib/no_cmd.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "ok", report.fetch( :status )
		assert_match( /not configured/, report.fetch( :skip_reason ) )
	end

	def test_lint_target_files_uses_full_repository_for_github_non_pr_events
		ok_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_command( command: ok_script )
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
		ok_script = executable_script( name: "lint_ok", body: "#!/usr/bin/env ruby\nexit 0\n" )
		runtime = build_runtime_with_lint_command( command: ok_script )

		remote_dir = File.join( @tmp_dir, "remote.git" )
		system( "git", "init", "--bare", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "branch", "-M", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "remote", "add", "origin", remote_dir, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
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

	def build_runtime_with_lint_command( command:, enforcement: "strict" )
		config_path = File.join( @tmp_dir, "config.json" )
		File.write(
			config_path,
			JSON.generate(
				{
					"lint" => {
						"command" => command,
						"enforcement" => enforcement
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
				err: err,
				verbose: true
			)
		end
		runtime
	end

	def build_runtime_without_lint_command
		config_path = File.join( @tmp_dir, "config.json" )
		File.write(
			config_path,
			JSON.generate( { "lint" => {} } )
		)
		runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: @repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				out: out,
				err: err,
				verbose: true
			)
		end
		runtime
	end

end
