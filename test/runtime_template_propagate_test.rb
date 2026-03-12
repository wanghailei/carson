# Tests for template apply and push-prep workflow.
require_relative "test_helper"

class RuntimeTemplatePropagateTest < Minitest::Test
	include CarsonTestSupport

	def test_skip_when_no_drift
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )
			tool_root = File.expand_path( "..", __dir__ )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" )
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 0 )
				assert_equal :skip, result.fetch( :status )
				assert_equal "no drift", result.fetch( :reason )
			end
		end
	end

	def test_skip_when_no_remote
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )
			tool_root = File.expand_path( "..", __dir__ )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" )
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 3 )
				assert_equal :skip, result.fetch( :status )
				assert_equal "no remote", result.fetch( :reason )
			end
		end
	end

	def test_branch_workflow_creates_pr
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			bare_remote = create_bare_remote( parent: tmp_dir, name: "remote.git" )
			repo_root = create_repo_with_remote( parent: tmp_dir, name: "repo", bare_remote: bare_remote )

			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "rubocop.yml" ), "AllCops:\n" )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" ),
				"CARSON_WORKFLOW_STYLE" => "branch"
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 2 )

				# Without a real GitHub remote, gh pr create will fail.
				# The push should succeed to the bare remote though.
				# We expect either :pr (if gh works) or :error (if gh fails on pr create).
				if result.fetch( :status ) == :pr
					assert result.fetch( :pr_url ).is_a?( String )
					assert_includes result, :branch
				elsif result.fetch( :status ) == :error
					# Expected when no GitHub remote is configured — push succeeds but PR fails.
					assert result.fetch( :reason ).is_a?( String )
				else
					# Push itself succeeded; verify branch was pushed.
					clone_dir = File.join( tmp_dir, "verify" )
					system( "git", "clone", bare_remote, clone_dir, out: File::NULL, err: File::NULL )
					branches, = Open3.capture3( "git", "-C", clone_dir, "branch", "-a" )
					assert_includes branches, "carson/template-sync"
				end

				# Verify worktree was cleaned up.
				worktrees, = Open3.capture3( "git", "-C", repo_root, "worktree", "list", "--porcelain" )
				refute_includes worktrees, "carson-template-sync"
			end
		end
	end

	def test_trunk_workflow_pushes_to_main
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			bare_remote = create_bare_remote( parent: tmp_dir, name: "remote.git" )
			repo_root = create_repo_with_remote( parent: tmp_dir, name: "repo", bare_remote: bare_remote )

			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "rubocop.yml" ), "AllCops:\n" )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" ),
				"CARSON_WORKFLOW_STYLE" => "trunk"
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 1 )
				assert_equal :pushed, result.fetch( :status )
				assert_equal "main", result.fetch( :ref )

				# Verify canonical file landed on remote main.
				clone_dir = File.join( tmp_dir, "verify" )
				system( "git", "clone", bare_remote, clone_dir, out: File::NULL, err: File::NULL )
				assert File.file?( File.join( clone_dir, ".github", "linters", "rubocop.yml" ) ), "Expected canonical file on remote main"
			end
		end
	end

	def test_worktree_cleanup_on_error
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			bare_remote = create_bare_remote( parent: tmp_dir, name: "remote.git" )
			repo_root = create_repo_with_remote( parent: tmp_dir, name: "repo", bare_remote: bare_remote )

			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "rubocop.yml" ), "AllCops:\n" )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			# Remove the bare remote's objects dir so push fails with a git error,
			# without making the filesystem unreadable (avoids chmod cleanup issues).
			objects_dir = File.join( bare_remote, "objects" )
			FileUtils.rm_rf( objects_dir )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" ),
				"CARSON_WORKFLOW_STYLE" => "trunk"
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 1 )
				assert_equal :error, result.fetch( :status )

				# Verify worktree was cleaned up despite the error.
				worktrees, = Open3.capture3( "git", "-C", repo_root, "worktree", "list", "--porcelain" )
				refute_includes worktrees, "carson-template-sync"
			end
		end
	end

	def test_no_op_when_content_matches_remote
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			bare_remote = create_bare_remote( parent: tmp_dir, name: "remote.git" )
			repo_root = create_repo_with_remote( parent: tmp_dir, name: "repo", bare_remote: bare_remote )

			canonical_dir = File.join( tmp_dir, "canonical" )
			FileUtils.mkdir_p( canonical_dir )
			File.write( File.join( canonical_dir, "rubocop.yml" ), "AllCops:\n" )

			config_path = File.join( tmp_dir, "config.json" )
			File.write( config_path, JSON.generate( { "lint" => { "canonical" => canonical_dir } } ) )

			# Pre-populate remote main with the same templates Carson would write.
			pre_populate_templates!( repo_root: repo_root, tool_root: tool_root, config_path: config_path )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => config_path,
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" ),
				"CARSON_WORKFLOW_STYLE" => "trunk"
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error,
					verbose: true
				)
				result = runtime.send( :template_propagate!, drift_count: 1 )
				assert_equal :skip, result.fetch( :status )
				assert_equal "no changes", result.fetch( :reason )
			end
		end
	end

	def test_refresh_stores_template_sync_result
		Dir.mktmpdir( "carson-propagate-test", carson_tmp_root ) do |tmp_dir|
			tool_root = File.expand_path( "..", __dir__ )
			repo_root = create_git_repo( parent: tmp_dir, name: "repo" )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"CARSON_HOOKS_PATH" => File.join( tmp_dir, "hooks" )
			) do
				output = StringIO.new
				error = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: tool_root,
					output: output,
					error: error
				)
				runtime.refresh!
				result = runtime.template_sync_result
				refute_nil result, "Expected template_sync_result to be set after refresh!"
				assert result.is_a?( Hash )
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

	# Pre-populates the repo (and remote) with the exact managed files Carson would write,
	# so template_propagate! finds no diff.
	def pre_populate_templates!( repo_root:, tool_root:, config_path: nil )
		env = config_path ? { "CARSON_CONFIG_FILE" => config_path } : {}
		cfg = with_env( env ) { Carson::Config.load( repo_root: repo_root ) }
		cfg.template_managed_files.each do |managed_file|
			source = template_source_for( managed_file: managed_file, tool_root: tool_root, config: cfg )
			next unless source

			target_path = File.join( repo_root, managed_file )
			FileUtils.mkdir_p( File.dirname( target_path ) )
			content = File.read( source ).gsub( "\r\n", "\n" ).rstrip + "\n"
			File.write( target_path, content )
		end
		system( "git", "-C", repo_root, "add", "--all", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "add templates", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )
	end

	# Finds the source file for a managed file — canonical directory first, then built-in templates.
	def template_source_for( managed_file:, tool_root:, config: )
		relative = managed_file.delete_prefix( ".github/" )
		canonical = config.lint_canonical
		if canonical && !canonical.empty?
			[ File.join( canonical, relative ),
				File.join( canonical, relative.delete_prefix( "linters/" ) ) ].each do |path|
				return path if File.file?( path )
			end
		end
		templates_dir = File.join( tool_root, "templates", ".github" )
		path = File.join( templates_dir, relative )
		return path if File.file?( path )
		path = File.join( templates_dir, File.basename( managed_file ) )
		return path if File.file?( path )
		nil
	end
end
