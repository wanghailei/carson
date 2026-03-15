# Tests for carson housekeep — sync + prune per repo.
require_relative "test_helper"

class RuntimeHousekeepTest < Minitest::Test
	include CarsonTestSupport

	def build_housekeep_worktree( path:, branch:, holds_cwd: false, held_by_other_process: false )
		Struct.new( :path, :branch, :holds_cwd_flag, :held_flag ) do
			def holds_cwd?
				holds_cwd_flag
			end

			def held_by_other_process?
				held_flag
			end

			def exists?
				File.directory?( path )
			end

			def dirty?
				false
			end
		end.new( path, branch, holds_cwd, held_by_other_process )
	end

	# --- housekeep --all ---

	def test_housekeep_all_no_repos_returns_error
		runtime, repo_root = build_runtime
		result = runtime.housekeep_all!
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_all_no_repos_json
		runtime, repo_root = build_runtime
		result = runtime.housekeep_all!( json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@output ).string
		data = JSON.parse( output )
		assert_equal "housekeep", data[ "command" ]
		assert_equal "error", data[ "status" ]
		assert_includes data[ "error" ], "No governed repositories"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_all_with_missing_path
		config_path = File.join( Dir.tmpdir, "carson-housekeep-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/tmp/nonexistent-repo-#{$$}" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			result = runtime.housekeep_all!
			assert_equal Carson::Runtime::EXIT_ERROR, result
			output = runtime.instance_variable_get( :@output ).string
			assert_includes output, "SKIP (path not found)"
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end

	# --- housekeep <target> ---

	def test_housekeep_target_unknown_repo_returns_error
		runtime, repo_root = build_runtime
		result = runtime.housekeep_target!( target: "/nonexistent/repo" )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Not a governed repository"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_target_unknown_repo_json
		runtime, repo_root = build_runtime
		result = runtime.housekeep_target!( target: "/nonexistent/repo", json_output: true )
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = runtime.instance_variable_get( :@output ).string
		data = JSON.parse( output )
		assert_equal "housekeep", data[ "command" ]
		assert_equal "error", data[ "status" ]
		assert_includes data[ "error" ], "Not a governed repository"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- resolve_governed_repo ---

	def test_resolve_governed_repo_by_basename
		config_path = File.join( Dir.tmpdir, "carson-housekeep-resolve-test-config.json" )
		File.write( config_path, JSON.generate( { "govern" => { "repos" => [ "/Users/test/AI", "/Users/test/carson" ] } } ) )

		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime, repo_root = build_runtime
			resolved = runtime.send( :resolve_governed_repo, target: "AI" )
			assert_equal "/Users/test/AI", resolved

			resolved_lower = runtime.send( :resolve_governed_repo, target: "ai" )
			assert_equal "/Users/test/AI", resolved_lower

			resolved_nil = runtime.send( :resolve_governed_repo, target: "nonexistent" )
			assert_nil resolved_nil
			destroy_runtime_repo( repo_root: repo_root )
		end
	ensure
		FileUtils.rm_f( config_path )
	end

	# --- housekeep! resolves to main worktree root ---

	def test_housekeep_resolves_to_main_worktree_root
		runtime, repo_root = build_runtime
		main_root = File.join( repo_root, "main-root" )
		FileUtils.mkdir_p( main_root )

		runtime.define_singleton_method( :main_worktree_root ) { main_root }

		received_path = nil
		runtime.define_singleton_method( :housekeep_one ) do |repo_path:, json_output: false|
			received_path = repo_path
			Carson::Runtime::EXIT_OK
		end

		runtime.housekeep!
		assert_equal main_root, received_path, "housekeep! should pass main_worktree_root, not repo_root"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_dry_run_resolves_to_main_worktree_root
		runtime, repo_root = build_runtime
		main_root = File.join( repo_root, "main-root" )
		FileUtils.mkdir_p( main_root )

		runtime.define_singleton_method( :main_worktree_root ) { main_root }

		scoped_repo_root = nil
		original_new = Carson::Runtime.method( :new )
		Carson::Runtime.define_singleton_method( :new ) do |repo_root:, **kwargs|
			scoped_repo_root = repo_root
			inst = original_new.call( repo_root: repo_root, **kwargs )
			inst.define_singleton_method( :housekeep_one_dry_run ) { Carson::Runtime::EXIT_OK }
			inst
		end

		runtime.housekeep!( dry_run: true )
		assert_equal main_root, scoped_repo_root, "dry-run should scope to main_worktree_root, not repo_root"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Runtime.define_singleton_method( :new, original_new ) if original_new
	end

	# --- reap_dead_worktrees! ---

	def test_reap_dead_worktrees_reaps_abandoned_worktree_without_open_pr
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "abandoned" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/abandoned" )
		git_calls = []

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| false }
		runtime.define_singleton_method( :git_capture! ) { |*| "abc123\n" }
		runtime.define_singleton_method( :merged_pr_for_branch ) { |branch:, branch_tip_sha:| [ nil, nil ] }
		runtime.define_singleton_method( :branch_has_open_pr? ) { |branch:| false }
		runtime.define_singleton_method( :abandoned_pr_for_branch ) do |branch:, branch_tip_sha:|
			[ { number: 42, url: "https://github.com/acme/widgets/pull/42", closed_at: "2026-03-11T12:00:00Z", merged_at: nil, head_sha: branch_tip_sha }, nil ]
		end
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.reap_dead_worktrees!

		assert_includes git_calls, [ "worktree", "remove", worktree_path ]
		assert_includes git_calls, [ "branch", "-D", "feature/abandoned" ]
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Reaped worktree: abandoned (feature/abandoned) — closed abandoned PR #42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_dead_worktrees_skips_abandoned_worktree_when_open_pr_exists
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "abandoned" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/abandoned" )
		git_calls = []
		abandoned_calls = 0

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| false }
		runtime.define_singleton_method( :git_capture! ) { |*| "abc123\n" }
		runtime.define_singleton_method( :merged_pr_for_branch ) { |branch:, branch_tip_sha:| [ nil, nil ] }
		runtime.define_singleton_method( :branch_has_open_pr? ) { |branch:| true }
		runtime.define_singleton_method( :abandoned_pr_for_branch ) do |branch:, branch_tip_sha:|
			abandoned_calls += 1
			[ nil, nil ]
		end
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.reap_dead_worktrees!

		refute_includes git_calls, [ "worktree", "remove", worktree_path ]
		refute_includes git_calls, [ "branch", "-D", "feature/abandoned" ]
		assert_equal 0, abandoned_calls
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Kept worktree: abandoned (feature/abandoned) — open PR exists"
		destroy_runtime_repo( repo_root: repo_root )
	end
end
