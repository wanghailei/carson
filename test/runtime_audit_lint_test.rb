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

	def test_local_lint_quality_blocks_when_required_config_files_are_missing
		runtime = build_runtime_with_lint_config(
			command: [ "ruby", "-e", "exit 0", "{files}" ],
			config_files: [ File.join( @tmp_dir, "missing", "policy.rb" ) ]
		)
		stage_ruby_file( relative_path: "lib/missing_config.rb", content: "puts :ok\n" )

		report = runtime.send( :local_lint_quality_report )
		assert_equal "block", report.fetch( :status )
		ruby_entry = report.fetch( :languages ).find { |entry| entry.fetch( :language ) == "ruby" }
		assert_equal "block", ruby_entry.fetch( :status )
		assert_match( /missing config files/, ruby_entry.fetch( :reason ) )
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
