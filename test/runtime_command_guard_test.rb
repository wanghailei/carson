# Tests for the command guard feature — pre-push hook and with_env_var helper.
require_relative "test_helper"

class RuntimeCommandGuardTest < Minitest::Test
	include CarsonTestSupport

	# --- with_env_var ---

	def test_with_env_var_sets_and_restores
		runtime, repo_root = build_runtime( verbose: false )
		ENV.delete( "CARSON_TEST_GUARD" )

		runtime.send( :with_env_var, "CARSON_TEST_GUARD", "active" ) do
			assert_equal "active", ENV[ "CARSON_TEST_GUARD" ]
		end

		refute ENV.key?( "CARSON_TEST_GUARD" ), "env var should be removed after block"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_with_env_var_restores_previous_value
		runtime, repo_root = build_runtime( verbose: false )
		ENV[ "CARSON_TEST_GUARD" ] = "original"

		runtime.send( :with_env_var, "CARSON_TEST_GUARD", "temporary" ) do
			assert_equal "temporary", ENV[ "CARSON_TEST_GUARD" ]
		end

		assert_equal "original", ENV[ "CARSON_TEST_GUARD" ]
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		ENV.delete( "CARSON_TEST_GUARD" )
	end

	def test_with_env_var_restores_on_exception
		runtime, repo_root = build_runtime( verbose: false )
		ENV.delete( "CARSON_TEST_GUARD" )

		assert_raises( RuntimeError ) do
			runtime.send( :with_env_var, "CARSON_TEST_GUARD", "active" ) do
				raise "boom"
			end
		end

		refute ENV.key?( "CARSON_TEST_GUARD" ), "env var should be removed even on exception"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- install_command_guard! ---

	def test_install_command_guard_copies_script
		runtime, repo_root = build_runtime( tool_root: tool_root_path, verbose: true )
		init_git_repo( repo_root )

		runtime.send( :install_command_guard! )

		target = runtime.send( :command_guard_path )
		assert File.file?( target ), "command-guard should be installed"
		assert File.executable?( target ), "command-guard should be executable"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		FileUtils.rm_f( target ) if target
	end

	def test_install_command_guard_skips_when_template_missing
		runtime, repo_root = build_runtime( verbose: true )
		init_git_repo( repo_root )

		# tool_root == repo_root which has no config/hooks/command-guard — should silently skip.
		runtime.send( :install_command_guard! )
		output = output_string( runtime )
		refute_includes output, "command_guard:"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- pre-push hook governed repo detection ---

	def test_pre_push_hook_blocks_in_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/guard-test" )

		# Set up config directly — matching the pattern of other passing tests.
		normalised = File.realpath( repo_root )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ normalised ] } } )
		)

		hook_path = File.join( tool_root_path, "config", "hooks", "pre-push" )
		ref_input = "refs/heads/feature/guard-test abc123 refs/heads/feature/guard-test 000000\n"

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", hook_path, "origin", "git@github.com:mock/repo.git",
			stdin_data: ref_input,
			chdir: repo_root
		)

		refute status.success?, "pre-push should block raw push in governed repo"
		assert_includes stderr, "Carson-governed"
		assert_includes stderr, "carson deliver"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_pre_push_hook_blocks_even_with_carson_push_env
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/carson-push" )

		normalised = File.realpath( repo_root )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ normalised ] } } )
		)

		hook_path = File.join( tool_root_path, "config", "hooks", "pre-push" )
		ref_input = "refs/heads/feature/carson-push abc123 refs/heads/feature/carson-push 000000\n"

		# CARSON_PUSH=1 should no longer bypass the hook — the hook blocks unconditionally.
		# Carson uses --no-verify to skip the hook entirely, not an env var.
		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root, "CARSON_PUSH" => "1" },
			"bash", hook_path, "origin", "git@github.com:mock/repo.git",
			stdin_data: ref_input,
			chdir: repo_root
		)

		refute status.success?, "pre-push should block even with CARSON_PUSH=1 — no env-var bypass"
		assert_includes stderr, "Carson-governed"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_pre_push_hook_allows_non_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/non-governed" )

		# Config exists but does not list this repo.
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ "/some/other/repo" ] } } )
		)

		hook_path = File.join( tool_root_path, "config", "hooks", "pre-push" )
		ref_input = "refs/heads/feature/non-governed abc123 refs/heads/feature/non-governed 000000\n"

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", hook_path, "origin", "git@github.com:mock/repo.git",
			stdin_data: ref_input,
			chdir: repo_root
		)

		# Should not be blocked — repo is not governed.
		refute_includes stderr, "BLOCKED: raw"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_pre_push_hook_blocks_push_to_main
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )

		hook_path = File.join( tool_root_path, "config", "hooks", "pre-push" )
		ref_input = "refs/heads/main abc123 refs/heads/main 000000\n"

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", hook_path, "origin", "git@github.com:mock/repo.git",
			stdin_data: ref_input,
			chdir: repo_root
		)

		refute status.success?, "pre-push should block push to main"
		assert_includes stderr, "Pushes to"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	# --- command-guard script ---

	def test_command_guard_blocks_gh_pr_create_in_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )

		normalised = File.realpath( repo_root )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ normalised ] } } )
		)

		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		input = JSON.generate( {
			tool_name: "Bash",
			tool_input: { command: "gh pr create --title 'test' --body ''" }
		} )

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", guard_path,
			stdin_data: input,
			chdir: repo_root
		)

		refute status.success?, "command-guard should block gh pr create in governed repo"
		assert_includes stderr, "Carson-governed"
		assert_includes stderr, "carson deliver"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_allows_gh_pr_create_in_non_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )

		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ "/other/repo" ] } } )
		)

		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		input = JSON.generate( {
			tool_name: "Bash",
			tool_input: { command: "gh pr create --title 'test'" }
		} )

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", guard_path,
			stdin_data: input,
			chdir: repo_root
		)

		assert status.success?, "command-guard should allow gh pr create in non-governed repo"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_allows_non_bash_tools
		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		input = JSON.generate( {
			tool_name: "Read",
			tool_input: { file_path: "/some/file" }
		} )

		stdout, stderr, status = Open3.capture3(
			"bash", guard_path,
			stdin_data: input
		)

		assert status.success?, "command-guard should allow non-Bash tools"
	end

	def test_command_guard_allows_non_pr_gh_commands
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )

		normalised = File.realpath( repo_root )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ normalised ] } } )
		)

		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		input = JSON.generate( {
			tool_name: "Bash",
			tool_input: { command: "gh pr view 42 --json state" }
		} )

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", guard_path,
			stdin_data: input,
			chdir: repo_root
		)

		assert status.success?, "command-guard should allow gh pr view (not create/merge)"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_allows_gh_pr_mention_in_commit_message_inside_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )
		worktree_path = create_worktree( repo_root, "feature/commit-message-mention" )

		_stdout, _stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git commit -m 'Document gh pr create hook'",
			chdir: worktree_path
		)

		assert status.success?, "command-guard should not block gh pr mentions inside commit messages when the commit itself is allowed"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_gh_pr_create_after_chain_operator
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )

		normalised = File.realpath( repo_root )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate( { "govern" => { "repos" => [ normalised ] } } )
		)

		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		# gh pr create after && is an actual command invocation.
		input = JSON.generate( {
			tool_name: "Bash",
			tool_input: { command: "git push github feature && gh pr create --title 'test'" }
		} )

		stdout, stderr, status = Open3.capture3(
			{ "HOME" => repo_root },
			"bash", guard_path,
			stdin_data: input,
			chdir: repo_root
		)

		refute status.success?, "command-guard should block gh pr create after &&"
		assert_includes stderr, "Carson-governed"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_gh_pr_create_in_governed_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )
		worktree_path = create_worktree( repo_root, "feature/guard-worktree" )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "gh pr create --title 'test'",
			chdir: worktree_path
		)

		refute status.success?, "command-guard should block raw gh pr create inside governed worktree"
		assert_includes stderr, "carson deliver"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_git_worktree_add_in_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git worktree add ../wt -b feature main"
		)

		refute status.success?, "command-guard should block raw git worktree add in governed repo"
		assert_includes stderr, "carson worktree"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_git_worktree_remove_in_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git worktree remove ../wt"
		)

		refute status.success?, "command-guard should block raw git worktree remove in governed repo"
		assert_includes stderr, "carson worktree"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_git_pull_rebase_in_governed_repo
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git pull --rebase github main"
		)

		refute status.success?, "command-guard should block raw git pull --rebase in governed repo"
		assert_includes stderr, "carson sync"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_git_add_on_main_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git add README.md"
		)

		refute status.success?, "command-guard should block git add on governed main worktree"
		assert_includes stderr, "Main working tree is read-only"
		assert_includes stderr, "carson worktree create"
		assert_includes stderr, "carson deliver --commit"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_blocks_git_commit_on_main_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )

		_stdout, stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git commit -m 'test'"
		)

		refute status.success?, "command-guard should block git commit on governed main worktree"
		assert_includes stderr, "Main working tree is read-only"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_allows_git_add_and_commit_in_feature_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )
		worktree_path = create_worktree( repo_root, "feature/allowed-worktree" )

		_stdout, _stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "git add README.md && git commit -m 'test'",
			chdir: worktree_path
		)

		assert status.success?, "command-guard should allow git add and git commit inside non-main worktree"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

	def test_command_guard_allows_git_add_and_commit_after_cd_into_feature_worktree
		repo_root = Dir.mktmpdir( "carson-guard-test", carson_tmp_root )
		init_git_repo( repo_root )
		write_governed_config( repo_root )
		worktree_path = create_worktree( repo_root, "feature/cd-allowed-worktree" )

		_stdout, _stderr, status = run_command_guard(
			repo_root: repo_root,
			command: "cd #{worktree_path} && git add README.md && git commit -m 'test'"
		)

		assert status.success?, "command-guard should respect a leading cd into a non-main worktree"
	ensure
		FileUtils.remove_entry( repo_root ) if repo_root && File.directory?( repo_root )
	end

private

	def tool_root_path
		File.expand_path( "../..", __FILE__ )
	end

	def write_governed_config( repo_root, main_branch: "main", governed_paths: [ File.realpath( repo_root ) ] )
		carson_dir = File.join( repo_root, ".carson" )
		FileUtils.mkdir_p( carson_dir )
		File.write(
			File.join( carson_dir, "config.json" ),
			JSON.generate(
				{
					"git" => { "main_branch" => main_branch },
					"govern" => { "repos" => governed_paths }
				}
			)
		)
	end

	def run_command_guard( repo_root:, command:, chdir: repo_root )
		guard_path = File.join( tool_root_path, "config", "hooks", "command-guard" )
		input = JSON.generate( {
			tool_name: "Bash",
			tool_input: { command: command }
		} )

		Open3.capture3(
			{ "HOME" => repo_root },
			"bash", guard_path,
			stdin_data: input,
			chdir: chdir
		)
	end

	def create_worktree( repo_root, branch_name )
		worktree_path = File.join( repo_root, ".claude", "worktrees", File.basename( branch_name ) )
		system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, out: File::NULL, err: File::NULL )
		worktree_path
	end

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "--no-verify", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
