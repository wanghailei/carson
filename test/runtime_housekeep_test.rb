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
		# Simulate running from a worktree: main_worktree_root differs from repo_root.
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
		runtime, repo_root = build_runtime
		worktree_path = File.join( repo_root, ".claude", "worktrees", "abandoned" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/abandoned" )
		git_calls = []

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
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
		assert_includes output, "reaped abandoned worktree: abandoned"
		assert_includes output, "https://github.com/acme/widgets/pull/42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_housekeep_one_entry_does_not_gate_reap_on_sync
		# Verify the code path: reap_dead_worktrees! runs regardless of sync result.
		# We stub at the Runtime class level to intercept the scoped runtime.
		runtime, repo_root = build_runtime
		reap_called = false
		original_new = Carson::Runtime.method( :new )
		Carson::Runtime.define_singleton_method( :new ) do |**kwargs|
			scoped = original_new.call( **kwargs )
			scoped.define_singleton_method( :sync! ) { |**| Carson::Runtime::EXIT_ERROR }
			scoped.define_singleton_method( :reap_dead_worktrees! ) { reap_called = true; { reaped: 0, skipped: 0 } }
			scoped.define_singleton_method( :prune! ) { |**| Carson::Runtime::EXIT_OK }
			scoped
		end

		entry = runtime.send( :housekeep_one_entry, repo_path: repo_root )
		assert reap_called, "reap_dead_worktrees! should run even when sync fails"
		assert_equal "ok", entry[ :status ], "status should be ok when prune succeeds"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Runtime.define_singleton_method( :new ) { |**kwargs| original_new.call( **kwargs ) } if original_new
	end

	def test_reap_dead_worktrees_returns_summary_hash
		runtime, repo_root = build_runtime
		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { false }

		summary = runtime.reap_dead_worktrees!
		assert_kind_of Hash, summary
		assert_equal 0, summary[ :reaped ]
		assert_equal 0, summary[ :skipped ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_dead_worktrees_skips_abandoned_worktree_when_open_pr_exists
		runtime, repo_root = build_runtime
		worktree_path = File.join( repo_root, ".claude", "worktrees", "abandoned" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/abandoned" )
		git_calls = []
		abandoned_calls = 0

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
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

		assert_empty git_calls
		assert_equal 0, abandoned_calls
		output = runtime.instance_variable_get( :@output ).string
		refute_includes output, "reaped abandoned worktree"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- reap_integrated_delivery_worktrees! ---

	def test_reap_integrated_delivery_worktrees_cleans_up_integrated
		runtime, repo_root = build_runtime
		worktree_path = File.join( repo_root, ".claude", "worktrees", "delivered" )
		FileUtils.mkdir_p( worktree_path )
		git_calls = []

		repository = Carson::Repository.new( path: repo_root, runtime: runtime )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/delivered",
			head: "abc123",
			worktree_path: worktree_path,
			pr_number: 50,
			pr_url: "https://github.com/test/repo/pull/50",
			status: "integrated",
			summary: "integrated into main",
			cause: nil
		)

		wt_entry = build_housekeep_worktree( path: worktree_path, branch: "feature/delivered" )
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		original_find = Carson::Worktree.method( :find )
		Carson::Worktree.define_singleton_method( :find ) { |path:, runtime:| wt_entry }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		summary = { reaped: 0, skipped: 0 }
		runtime.reap_integrated_delivery_worktrees!( summary: summary )

		assert_equal 1, summary[ :reaped ]
		assert_includes git_calls, [ "worktree", "remove", worktree_path ]
		assert_includes git_calls, [ "branch", "-D", "feature/delivered" ]

		# Verify worktree_path was nulled in the ledger.
		updated = runtime.ledger.integrated_deliveries( repo_path: repo_root )
		assert_empty updated, "integrated delivery should have worktree_path nulled"

		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "reaped integrated delivery worktree: delivered"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Worktree.define_singleton_method( :find, original_find ) if original_find
	end

	def test_reap_integrated_delivery_worktrees_skips_failed_and_superseded
		runtime, repo_root = build_runtime
		worktree_path_f = File.join( repo_root, ".claude", "worktrees", "failed-wt" )
		worktree_path_s = File.join( repo_root, ".claude", "worktrees", "superseded-wt" )
		FileUtils.mkdir_p( worktree_path_f )
		FileUtils.mkdir_p( worktree_path_s )

		repository = Carson::Repository.new( path: repo_root, runtime: runtime )
		d1 = runtime.ledger.upsert_delivery(
			repository: repository, branch_name: "feature/fail", head: "f1",
			worktree_path: worktree_path_f,
			pr_number: 51, pr_url: "https://github.com/test/repo/pull/51",
			status: "failed", summary: "failed", cause: nil
		)
		d2 = runtime.ledger.upsert_delivery(
			repository: repository, branch_name: "feature/sup", head: "s1",
			worktree_path: worktree_path_s,
			pr_number: 52, pr_url: "https://github.com/test/repo/pull/52",
			status: "superseded", summary: "superseded", cause: nil
		)

		runtime.define_singleton_method( :main_worktree_root ) { repo_root }

		summary = { reaped: 0, skipped: 0 }
		runtime.reap_integrated_delivery_worktrees!( summary: summary )

		assert_equal 0, summary[ :reaped ]
		assert Dir.exist?( worktree_path_f ), "failed delivery worktree should be preserved"
		assert Dir.exist?( worktree_path_s ), "superseded delivery worktree should be preserved"
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- housekeep_loop! ---

	def test_housekeep_loop_delegates_to_housekeep_all_and_handles_interrupt
		runtime, repo_root = build_runtime
		cycle_count = 0

		runtime.define_singleton_method( :housekeep_all! ) do |json_output: false, dry_run: false|
			cycle_count += 1
			raise Interrupt if cycle_count >= 2
			Carson::Runtime::EXIT_OK
		end

		result = runtime.housekeep_loop!( json_output: false, loop_seconds: 0 )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal 2, cycle_count
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "housekeep loop stopped after 2 cycles"
		destroy_runtime_repo( repo_root: repo_root )
	end
end
