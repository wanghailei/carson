# Tests for canonical template file resolution in the template engine.
# Verifies that template_result_for_file resolves canonical files from the user's
# canonical directory, and that propagation writes them correctly.
require_relative "test_helper"

class RuntimeCanonicalTemplateTest < Minitest::Test
	include CarsonTestSupport

	def test_template_check_includes_canonical_files
		Dir.mktmpdir( "carson-canonical-runtime-test", carson_tmp_root ) do |tmp_dir|
			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( File.join( canonical_dir, "workflows" ) )
			File.write( File.join( canonical_dir, "workflows", "lint.yml" ), "name: Lint\n" )

			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )
			tool_root = File.expand_path( "..", __dir__ )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => File.join( tmp_dir, "hooks" )
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					out: out,
					err: err,
					verbose: true
				)
				runtime.template_check!
				output = out.string

				# The canonical file should appear as drifted (missing from repo).
				assert_includes output, ".github/workflows/lint.yml"
				assert_includes output, "drift"
			end
		end
	end

	def test_template_apply_writes_canonical_files
		Dir.mktmpdir( "carson-canonical-runtime-test", carson_tmp_root ) do |tmp_dir|
			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "dependabot.yml" ), "version: 2\n" )

			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )
			tool_root = File.expand_path( "..", __dir__ )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => File.join( tmp_dir, "hooks" )
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					out: out,
					err: err,
					verbose: true
				)
				runtime.template_apply!

				# Verify the canonical file was written to the repo.
				deployed_path = File.join( repo_root, ".github", "dependabot.yml" )
				assert File.file?( deployed_path ), "Expected canonical file to be deployed"
				assert_equal "version: 2\n", File.read( deployed_path )
			end
		end
	end

	def test_canonical_file_overrides_carson_built_in
		Dir.mktmpdir( "carson-canonical-runtime-test", carson_tmp_root ) do |tmp_dir|
			# Create a canonical directory with a file that has the same name as a Carson governance file.
			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "pull_request_template.md" ), "Custom PR template\n" )

			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )
			tool_root = File.expand_path( "..", __dir__ )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => File.join( tmp_dir, "hooks" )
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					out: out,
					err: err,
					verbose: true
				)
				runtime.template_apply!

				# The canonical version should win because template_source_path checks canonical first.
				deployed_path = File.join( repo_root, ".github", "pull_request_template.md" )
				assert File.file?( deployed_path )
				assert_equal "Custom PR template\n", File.read( deployed_path )
			end
		end
	end

	def test_propagation_includes_canonical_files
		Dir.mktmpdir( "carson-canonical-runtime-test", carson_tmp_root ) do |tmp_dir|
			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( File.join( canonical_dir, "workflows" ) )
			File.write( File.join( canonical_dir, "workflows", "lint.yml" ), "name: Lint\n" )

			tool_root = File.expand_path( "..", __dir__ )
			bare_remote = create_bare_remote( parent: tmp_dir, name: "remote.git" )
			repo_root = create_repo_with_remote( parent: tmp_dir, name: "repo", bare_remote: bare_remote )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "template" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_BASE_PATH" => File.join( tmp_dir, "hooks" ),
				"CARSON_WORKFLOW_STYLE" => "trunk"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					out: out,
					err: err,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 1 )
				assert_equal :pushed, result.fetch( :status )

				# Verify the canonical file landed on the remote.
				clone_dir = File.join( tmp_dir, "verify" )
				system( "git", "clone", bare_remote, clone_dir, out: File::NULL, err: File::NULL )
				assert File.file?( File.join( clone_dir, ".github", "workflows", "lint.yml" ) ), "Expected canonical file on remote"
			end
		end
	end

private

	def create_git_repo( parent:, name: )
		path = File.join( parent, name )
		FileUtils.mkdir_p( path )
		system( "git", "init", "--initial-branch=main", path, out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "config", "user.email", "test@test.local", out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", path, "commit", "--allow-empty", "-m", "initial", out: File::NULL, err: File::NULL )
		path
	end

	def create_bare_remote( parent:, name: )
		path = File.join( parent, name )
		system( "git", "init", "--bare", "--initial-branch=main", path, out: File::NULL, err: File::NULL )
		path
	end

	def create_repo_with_remote( parent:, name:, bare_remote: )
		repo_root = create_git_repo( parent: parent, name: name )
		system( "git", "-C", repo_root, "remote", "add", "origin", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
		repo_root
	end
end
