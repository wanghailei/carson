# Tests for worktree create and remove lifecycle.
require_relative "test_helper"
require "open3"

class RuntimeWorktreeLifecycleTest < Minitest::Test
	include CarsonTestSupport

	# --- worktree create ---

	def test_worktree_create_creates_worktree_and_branch
		runtime, repo_root = build_runtime
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "test-feature" )
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "test-feature" )
		assert Dir.exist?( wt_path ), "Worktree directory should exist"

		# Branch should exist.
		_, _, success, = Open3.capture3( "git", "branch", "--list", "test-feature", chdir: repo_root )
		branch_output, = Open3.capture3( "git", "branch", "--list", "test-feature", chdir: repo_root )
		assert_includes branch_output, "test-feature"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_prints_path_and_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "my-work" )
		output = output_string( runtime )
		assert_includes output, "Worktree created: my-work"
		assert_includes output, "Branch: my-work"

		wt_path = File.join( repo_root, ".claude", "worktrees", "my-work" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_refuses_duplicate_name
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "dupe" )
		result = runtime.worktree_create!( name: "dupe" )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_includes output_string( runtime ), "already exists"

		wt_path = File.join( repo_root, ".claude", "worktrees", "dupe" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_succeeds_without_remote
		# Sync is best-effort — creation must succeed even without a remote.
		runtime, repo_root = build_runtime( verbose: true )
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "no-remote" )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "fetch skipped"

		wt_path = File.join( repo_root, ".claude", "worktrees", "no-remote" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_supports_slash_scoped_name
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "codex/slash-test" )
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "codex", "slash-test" )
		assert Dir.exist?( wt_path ), "Slash-scoped worktree directory should exist"

		branch_output, = Open3.capture3( "git", "branch", "--list", "codex/slash-test", chdir: repo_root )
		assert_includes branch_output, "codex/slash-test"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_json_output_stays_machine_parseable_in_verbose_mode
		runtime, repo_root = build_runtime( verbose: true )
		init_git_repo( repo_root )

		result = runtime.worktree_create!( name: "json-quiet", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )

		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal "ok", json[ "status" ]
		assert_equal "json-quiet", json[ "name" ]

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-quiet" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_errors_when_success_cannot_be_verified
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_name = "codex/ghost-worktree"
		worktree_path = File.join( repo_root, ".claude", "worktrees", "codex", "ghost-worktree" )
		original_git_run = runtime.method( :git_run )

		runtime.define_singleton_method( :git_run ) do |*args|
			if args[ 0, 2 ] == [ "worktree", "add" ]
				[ "", "", true, 0 ]
			else
				original_git_run.call( *args )
			end
		end

		result = runtime.worktree_create!( name: worktree_name, json_output: true )
		json = JSON.parse( output_string( runtime ).strip )

		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_equal "error", json[ "status" ]
		assert_includes json[ "error" ], "could not verify"
		assert_includes json[ "recovery" ], "git worktree list"
		assert_includes json[ "recovery" ], worktree_name, "Recovery should include the actual branch name, not a literal"
		refute Dir.exist?( worktree_path ), "Verification failure must not report a real worktree path as created"

		branch_output, = Open3.capture3( "git", "branch", "--list", worktree_name, chdir: repo_root )
		assert_equal "", branch_output.strip
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_cleans_up_partial_state_on_verification_failure
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_name = "partial-cleanup"
		worktree_path = File.join( repo_root, ".claude", "worktrees", worktree_name )
		original_git_run = runtime.method( :git_run )

		# Simulate: git worktree add succeeds but creates only the branch,
		# not the actual worktree registration. This leaves a partial branch behind.
		runtime.define_singleton_method( :git_run ) do |*args|
			if args[ 0, 2 ] == [ "worktree", "add" ]
				original_git_run.call( "branch", args[ 4 ], args[ 5 ] )
				[ "", "", true, 0 ]
			else
				original_git_run.call( *args )
			end
		end

		result = runtime.worktree_create!( name: worktree_name, json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result

		# The partial branch must be cleaned up.
		branch_output, = Open3.capture3( "git", "branch", "--list", worktree_name, chdir: repo_root )
		assert_equal "", branch_output.strip, "Partial branch should be deleted on verification failure"

		# No stray directory should remain.
		refute Dir.exist?( worktree_path ), "No stray directory should remain"

		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_rejects_prunable_registered_entry
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_name = "codex/prunable-worktree"
		original_git_run = runtime.method( :git_run )

		runtime.define_singleton_method( :git_run ) do |*args|
			stdout, stderr, success, status = original_git_run.call( *args )
			if args[ 0, 2 ] == [ "worktree", "add" ] && success
				FileUtils.rm_rf( args.fetch( 2 ) )
			end
			[ stdout, stderr, success, status ]
		end

		result = runtime.worktree_create!( name: worktree_name, json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		diag = json.fetch( "diagnostics" )

		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_equal "error", json[ "status" ]
		assert_equal false, diag.fetch( "worktree_directory_exists" )
		assert_equal true, diag.fetch( "registered_worktree" )
		assert_includes diag.fetch( "worktree_list" ), "prunable"
		assert_includes diag.fetch( "prunable_reason" ), "non-existent"

		branch_output, = Open3.capture3( "git", "branch", "--list", worktree_name, chdir: repo_root )
		assert_equal "", branch_output.strip, "Prunable verification failure should clean up the branch"

		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_verification_failure_includes_diagnostics
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_name = "diag-test"
		original_git_run = runtime.method( :git_run )

		runtime.define_singleton_method( :git_run ) do |*args|
			if args[ 0, 2 ] == [ "worktree", "add" ]
				[ "mock stdout", "mock stderr", true, 0 ]
			else
				original_git_run.call( *args )
			end
		end

		result = runtime.worktree_create!( name: worktree_name, json_output: true )
		json = JSON.parse( output_string( runtime ).strip )

		assert_equal "error", json[ "status" ]
		assert json.key?( "diagnostics" ), "Error should include diagnostics hash"
		diag = json[ "diagnostics" ]
		assert diag.key?( "git_stdout" ), "Should include git stdout"
		assert diag.key?( "git_stderr" ), "Should include git stderr"
		assert diag.key?( "repo_root" ), "Should include repo_root"
		assert diag.key?( "main_worktree_root" ), "Should include main_worktree_root"
		assert diag.key?( "worktree_list" ), "Should include worktree list"
		assert diag.key?( "branch_list" ), "Should include branch list"
		assert diag.key?( "git_version" ), "Should include git version"
		assert_equal repo_root, diag[ "repo_root" ], "repo_root should be the actual runtime root"

		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_from_inside_existing_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.worktree_create!( name: "outer-wt" )
		outer_path = File.join( repo_root, ".claude", "worktrees", "outer-wt" )
		assert Dir.exist?( outer_path ), "First worktree should exist"

		config_path = ENV.fetch( "CARSON_CONFIG_FILE", "" ).to_s.strip
		config_path = write_test_config( repo_root: repo_root ) if config_path.empty?
		inner_runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			inner_runtime = Carson::Runtime.new(
				repo_root: outer_path,
				tool_root: repo_root,
				output: StringIO.new,
				error: StringIO.new,
				verbose: false
			)
		end

		result = inner_runtime.worktree_create!( name: "inner-wt", json_output: true )
		json = JSON.parse( inner_runtime.instance_variable_get( :@output ).string.strip )

		assert_equal Carson::Runtime::EXIT_OK, result, "Creating worktree from inside another should succeed"
		assert_equal "ok", json[ "status" ]
		assert_equal "inner-wt", json[ "name" ]

		inner_path = File.join( repo_root, ".claude", "worktrees", "inner-wt" )
		assert Dir.exist?( inner_path ), "Inner worktree directory should exist under main repo root"

		branch_output, = Open3.capture3( "git", "branch", "--list", "inner-wt", chdir: repo_root )
		assert_includes branch_output, "inner-wt"

		cleanup_worktree( repo_root, inner_path )
		cleanup_worktree( repo_root, outer_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_cli_worktree_create_with_slash_scoped_name
		repo_root = Dir.mktmpdir( "carson-cli-e2e", carson_tmp_root )
		init_git_repo( repo_root )

		carson_bin = File.expand_path( File.join( __dir__, "..", "exe", "carson" ) )
		config_path = write_test_config( repo_root: repo_root )

		stdout, stderr, status = Open3.capture3(
			{ "CARSON_CONFIG_FILE" => config_path },
			carson_bin, "worktree", "create", "claude/e2e-slash", "--json",
			chdir: repo_root
		)

		assert status.success?, "CLI should exit 0. stderr: #{stderr}"
		json = JSON.parse( stdout.strip )
		assert_equal "ok", json[ "status" ]
		assert_equal "claude/e2e-slash", json[ "name" ]
		assert_equal "claude/e2e-slash", json[ "branch" ]

		wt_path = File.join( repo_root, ".claude", "worktrees", "claude", "e2e-slash" )
		assert Dir.exist?( wt_path ), "Worktree directory should exist at nested path"

		system( "git", "-C", repo_root, "worktree", "remove", "--force", wt_path, out: File::NULL, err: File::NULL )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_creation_verified_fails_when_directory_missing_but_registered
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_name = "ghost/dir-missing"
		worktree_path = File.join( repo_root, ".claude", "worktrees", "ghost", "dir-missing" )
		original_git_run = runtime.method( :git_run )

		# Let worktree add actually run (creates branch + registration + directory),
		# then immediately delete the directory. The Dir.exist? guard in
		# creation_verified? must catch this gap.
		runtime.define_singleton_method( :git_run ) do |*args|
			result = original_git_run.call( *args )
			if args[ 0, 2 ] == [ "worktree", "add" ]
				FileUtils.rm_rf( worktree_path )
			end
			result
		end

		result = runtime.worktree_create!( name: worktree_name, json_output: true )
		json = JSON.parse( output_string( runtime ).strip )

		assert_equal Carson::Runtime::EXIT_ERROR, result
		assert_equal "error", json[ "status" ]
		assert_includes json[ "error" ], "could not verify"

		# Clean up: branch and registration may still exist from the real git run.
		system( "git", "-C", repo_root, "worktree", "prune", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "branch", "-D", worktree_name, out: File::NULL, err: File::NULL )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_json_with_verbose_produces_valid_json
		runtime, repo_root = build_runtime( verbose: true )
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "verbose-json", json_output: true )
		raw = output_string( runtime ).strip

		# The key assertion: JSON.parse must succeed — no verbose prefix lines.
		json = JSON.parse( raw )

		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal "ok", json[ "status" ]
		assert_equal "verbose-json", json[ "name" ]

		wt_path = File.join( repo_root, ".claude", "worktrees", "verbose-json" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- JSON output tests ---

	def test_worktree_create_json_success
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.worktree_create!( name: "json-feat", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "worktree create", json[ "command" ]
		assert_equal "ok", json[ "status" ]
		assert_equal "json-feat", json[ "name" ]
		assert_equal "json-feat", json[ "branch" ]
		assert json[ "path" ], "should include path"
		assert_equal 0, json[ "exit_code" ]
		assert_equal Carson::Runtime::EXIT_OK, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-feat" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_json_duplicate_error_with_recovery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "json-dupe" )

		# Reset output buffer for second call.
		runtime.instance_variable_get( :@output ).truncate( 0 )
		runtime.instance_variable_get( :@output ).rewind

		result = runtime.worktree_create!( name: "json-dupe", json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "error", json[ "status" ]
		assert_includes json[ "error" ], "already exists"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_ERROR, result

		wt_path = File.join( repo_root, ".claude", "worktrees", "json-dupe" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- worktree create excludes .claude/ from git status ---

	def test_worktree_create_adds_claude_dir_to_git_exclude
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "exclude-test" )

		exclude_path = File.join( repo_root, ".git", "info", "exclude" )
		assert File.exist?( exclude_path ), ".git/info/exclude should exist"
		exclude_content = File.read( exclude_path )
		assert_includes exclude_content, ".claude/", ".claude/ should be in git exclude"

		# Verify git status does not show .claude/ as untracked.
		status_output, = Open3.capture3( "git", "status", "--porcelain", chdir: repo_root )
		refute_includes status_output, ".claude/", "git status should not show .claude/"

		wt_path = File.join( repo_root, ".claude", "worktrees", "exclude-test" )
		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_create_does_not_duplicate_exclude_entry
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		# Create two worktrees — .claude/ should appear in exclude only once.
		runtime.worktree_create!( name: "first-worktree" )
		runtime.worktree_create!( name: "second-worktree" )

		exclude_path = File.join( repo_root, ".git", "info", "exclude" )
		exclude_content = File.read( exclude_path )
		matches = exclude_content.lines.count { |line| line.strip == ".claude/" }
		assert_equal 1, matches, ".claude/ should appear exactly once in exclude"

		wt1 = File.join( repo_root, ".claude", "worktrees", "first-worktree" )
		wt2 = File.join( repo_root, ".claude", "worktrees", "second-worktree" )
		cleanup_worktree( repo_root, wt1 )
		cleanup_worktree( repo_root, wt2 )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- CWD safety ---

	def test_worktree_remove_blocks_when_cwd_inside_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "cwd-trap" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "cwd-trap" )

		# Simulate the caller's shell being inside the worktree.
		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( wt_path )
		result = runtime.worktree_remove!( worktree_path: "cwd-trap", json_output: true )
		Dir.chdir( original_dir )

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "error" ], "current working directory"
		assert json[ "recovery" ], "should include recovery command"
		assert_equal Carson::Runtime::EXIT_BLOCK, result

		# Worktree should still exist — removal was blocked.
		assert Dir.exist?( wt_path ), "Worktree should NOT be removed"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_remove_succeeds_when_cwd_outside
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "safe-remove" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "safe-remove" )

		# CWD is the repo root (outside the worktree) — should succeed.
		reset_output( runtime )
		original_dir = Dir.pwd
		Dir.chdir( repo_root )
		result = runtime.worktree_remove!( worktree_path: "safe-remove" )
		Dir.chdir( original_dir )

		assert_equal Carson::Runtime::EXIT_OK, result
		refute Dir.exist?( wt_path ), "Worktree should be removed"

		destroy_runtime_repo( repo_root: repo_root )
	end


	# --- cross-process CWD safety ---

	def test_worktree_remove_blocks_when_other_process_holds_cwd
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "held-by-other" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "held-by-other" )

		# Fork a child that holds its CWD inside the worktree.
		# Pipe synchronisation: child signals ready, parent signals done.
		child_ready_r, child_ready_w = IO.pipe
		parent_done_r, parent_done_w = IO.pipe

		pid = fork do
			child_ready_r.close
			parent_done_w.close
			Dir.chdir( wt_path )
			child_ready_w.write( "ready" )
			child_ready_w.close
			parent_done_r.read
			parent_done_r.close
		end

		child_ready_w.close
		parent_done_r.close
		child_ready_r.read
		child_ready_r.close

		reset_output( runtime )
		result = runtime.worktree_remove!( worktree_path: "held-by-other", json_output: true )

		parent_done_w.close
		Process.wait( pid )

		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "block", json[ "status" ]
		assert_includes json[ "error" ], "another process"
		assert json[ "recovery" ], "should include recovery advice"
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert Dir.exist?( wt_path ), "Worktree should NOT be removed"

		cleanup_worktree( repo_root, wt_path )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_remove_succeeds_when_no_other_process_holds_cwd
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "not-held" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "not-held" )

		reset_output( runtime )
		result = runtime.worktree_remove!( worktree_path: "not-held" )
		assert_equal Carson::Runtime::EXIT_OK, result
		refute Dir.exist?( wt_path ), "Worktree should be removed"

		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- content-aware squash merge detection ---

	def test_worktree_remove_allows_squash_merged_branch
		runtime, repo_root = build_runtime( verbose: true )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "squash-test" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "squash-test" )

		# Make a change on the feature branch.
		File.write( File.join( wt_path, "feature.txt" ), "new feature" )
		system( "git", "-C", wt_path, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", wt_path, "commit", "-m", "add feature", out: File::NULL, err: File::NULL )

		# Simulate squash merge: apply the same content to main as a new commit.
		File.write( File.join( repo_root, "feature.txt" ), "new feature" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "squash: add feature", out: File::NULL, err: File::NULL )

		# Remove should succeed without --force — content matches main.
		reset_output( runtime )
		result = runtime.worktree_remove!( worktree_path: "squash-test" )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "content matches main"

		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_worktree_remove_blocks_unmerged_unique_commits
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.worktree_create!( name: "unmerged" )

		wt_path = File.join( repo_root, ".claude", "worktrees", "unmerged" )

		# Make a change on the feature branch that is NOT on main.
		File.write( File.join( wt_path, "unique.txt" ), "unique work" )
		system( "git", "-C", wt_path, "add", "unique.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", wt_path, "commit", "-m", "unique work", out: File::NULL, err: File::NULL )

		# Remove should block — content differs from main.
		reset_output( runtime )
		result = runtime.worktree_remove!( worktree_path: "unmerged" )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "has not been pushed"

		cleanup_worktree( repo_root, wt_path, force: true )
		destroy_runtime_repo( repo_root: repo_root )
	end
private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def reset_output( runtime )
		runtime.instance_variable_get( :@output ).truncate( 0 )
		runtime.instance_variable_get( :@output ).rewind
	end

	def cleanup_worktree( repo_root, wt_path, force: false )
		args = [ "git", "-C", repo_root, "worktree", "remove" ]
		args << "--force" if force
		args << wt_path
		system( *args, out: File::NULL, err: File::NULL )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
