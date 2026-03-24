# Tests for carson housekeep — sync + prune per repo.
require_relative "test_helper"

class RuntimeHousekeepTest < Minitest::Test
	include CarsonTestSupport

	def build_housekeep_worktree( path:, branch:, holds_cwd: false, held_by_other_process: false, dirty: false )
		Struct.new( :path, :branch, :holds_cwd_flag, :held_flag, :dirty_flag ) do
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
				dirty_flag
			end
		end.new( path, branch, holds_cwd, held_by_other_process, dirty )
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

	def test_housekeep_one_entry_continues_cleanup_when_sync_blocks
		runtime, repo_root = build_runtime( verbose: false )
		scoped_calls = []
		original_new = Carson::Runtime.method( :new )
		Carson::Runtime.define_singleton_method( :new ) do |**kwargs|
			instance = original_new.call( **kwargs )
			instance.define_singleton_method( :sync! ) do
				scoped_calls << :sync
				Carson::Runtime::EXIT_BLOCK
			end
			instance.define_singleton_method( :reap_dead_worktrees! ) do
				scoped_calls << :reap
			end
			instance.define_singleton_method( :prune! ) do
				scoped_calls << :prune
				Carson::Runtime::EXIT_OK
			end
			instance
		end

		entry = runtime.send( :housekeep_one_entry, repo_path: repo_root, silent: true )

		assert_equal [ :sync, :reap, :prune ], scoped_calls
		assert_equal "error", entry.fetch( :status )
		assert_equal "block", entry.fetch( :sync_status )
		assert_equal "ok", entry.fetch( :reap_status )
		assert_equal "ok", entry.fetch( :prune_status )
		assert_includes entry.fetch( :error ), "sync block"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Runtime.define_singleton_method( :new, original_new ) if original_new
	end

	def test_housekeep_one_entry_reports_all_step_statuses_when_everything_passes
		runtime, repo_root = build_runtime( verbose: false )
		original_new = Carson::Runtime.method( :new )
		Carson::Runtime.define_singleton_method( :new ) do |**kwargs|
			instance = original_new.call( **kwargs )
			instance.define_singleton_method( :sync! ) { |_json_output = false| Carson::Runtime::EXIT_OK }
			instance.define_singleton_method( :reap_dead_worktrees! ) {}
			instance.define_singleton_method( :prune! ) { |_json_output = false| Carson::Runtime::EXIT_OK }
			instance
		end

		entry = runtime.send( :housekeep_one_entry, repo_path: repo_root, silent: true )

		assert_equal "ok", entry.fetch( :status )
		assert_equal "ok", entry.fetch( :sync_status )
		assert_equal "ok", entry.fetch( :reap_status )
		assert_equal "ok", entry.fetch( :prune_status )
		refute entry.key?( :error )
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

	def test_reap_dead_worktrees_keeps_dirty_absorbed_worktree
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "absorbed" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/absorbed", dirty: true )
		git_calls = []

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| true }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			case args
			when [ "worktree", "remove", worktree_path ]
				[ "", "contains modified or untracked files", false, 1 ]
			when [ "worktree", "remove", "--force", worktree_path ]
				[ "", "", true, 0 ]
			else
				[ "", "", true, 0 ]
			end
		end

		runtime.reap_dead_worktrees!

		refute_includes git_calls, [ "worktree", "remove", worktree_path ]
		refute_includes git_calls, [ "worktree", "remove", "--force", worktree_path ]
		refute_includes git_calls, [ "branch", "-D", "feature/absorbed" ]
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Kept worktree: absorbed (feature/absorbed) — dirty worktree"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_dead_worktrees_keeps_dirty_worktree_with_merged_pr_evidence
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "merged" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/merged", dirty: true )
		git_calls = []
		merged_calls = 0

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| false }
		runtime.define_singleton_method( :merged_pr_for_branch ) do |branch:, branch_tip_sha:|
			merged_calls += 1
			[ { number: 42, url: "https://github.com/acme/widgets/pull/42", merged_at: "2026-03-11T12:00:00Z", head_sha: branch_tip_sha }, nil ]
		end
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			case args
			when [ "worktree", "remove", worktree_path ]
				[ "", "contains modified or untracked files", false, 1 ]
			when [ "worktree", "remove", "--force", worktree_path ]
				[ "", "", true, 0 ]
			else
				[ "", "", true, 0 ]
			end
		end

		runtime.reap_dead_worktrees!

		assert_equal 0, merged_calls
		refute_includes git_calls, [ "worktree", "remove", worktree_path ]
		refute_includes git_calls, [ "worktree", "remove", "--force", worktree_path ]
		refute_includes git_calls, [ "branch", "-D", "feature/merged" ]
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Kept worktree: merged (feature/merged) — dirty worktree"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_dead_worktrees_reaps_clean_worktree_with_merged_pr_evidence
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "merged-clean" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/merged-clean", dirty: false )
		git_calls = []

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| true }
		runtime.define_singleton_method( :git_capture! ) { |*| "abc123\n" }
		runtime.define_singleton_method( :merged_pr_for_branch ) do |branch:, branch_tip_sha:|
			[ { number: 42, url: "https://github.com/acme/widgets/pull/42", merged_at: "2026-03-11T12:00:00Z", head_sha: branch_tip_sha }, nil ]
		end
		runtime.define_singleton_method( :branch_has_open_pr? ) { |branch:| false }
		runtime.define_singleton_method( :abandoned_pr_for_branch ) { |branch:, branch_tip_sha:| [ nil, nil ] }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.reap_dead_worktrees!

		assert_includes git_calls, [ "worktree", "remove", worktree_path ]
		assert_includes git_calls, [ "branch", "-D", "feature/merged-clean" ]
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Reaped worktree: merged-clean (feature/merged-clean) — merged PR #42"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_dead_worktrees_keeps_dirty_worktree_without_merge_evidence
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "dirty" )
		FileUtils.mkdir_p( worktree_path )
		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/dirty", dirty: true )
		git_calls = []

		runtime.define_singleton_method( :sweep_stale_worktrees! ) {}
		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :main_worktree_root ) { repo_root }
		runtime.define_singleton_method( :worktree_list ) { [ worktree ] }
		runtime.define_singleton_method( :branch_absorbed_into_main? ) { |branch:| false }
		runtime.define_singleton_method( :git_capture! ) { |*| "abc123\n" }
		runtime.define_singleton_method( :merged_pr_for_branch ) { |branch:, branch_tip_sha:| [ nil, nil ] }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.reap_dead_worktrees!

		refute_includes git_calls, [ "worktree", "remove", worktree_path ]
		refute_includes git_calls, [ "worktree", "remove", "--force", worktree_path ]
		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Kept worktree: dirty (feature/dirty) — dirty worktree"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_reap_integrated_delivery_worktrees_reaps_matching_integrated_worktree
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "delivered" )
		FileUtils.mkdir_p( worktree_path )
		git_calls = []

		repository = Carson::Repository.new( path: repo_root, runtime: nil )
		runtime.ledger.upsert_delivery(
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

		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/delivered" )
		original_find = Carson::Worktree.method( :find )
		Carson::Worktree.define_singleton_method( :find ) { |path:, runtime:| worktree }
		runtime.define_singleton_method( :integrated_delivery_worktree_head ) { |worktree_path:| "abc123" }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.send( :reap_integrated_delivery_worktrees! )

		assert_includes git_calls, [ "worktree", "remove", worktree_path ]
		assert_includes git_calls, [ "branch", "-D", "feature/delivered" ]
		assert_empty runtime.ledger.integrated_deliveries( repo_path: repo_root )

		output = runtime.instance_variable_get( :@output ).string
		assert_includes output, "Reaped worktree: delivered (feature/delivered) — merged — delivery recorded"
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Worktree.define_singleton_method( :find, original_find ) if original_find
	end

	def test_reap_integrated_delivery_worktrees_clears_stale_path_when_worktree_head_has_moved
		runtime, repo_root = build_runtime( verbose: false )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "reused" )
		FileUtils.mkdir_p( worktree_path )
		git_calls = []

		repository = Carson::Repository.new( path: repo_root, runtime: nil )
		runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/reused",
			head: "old-head",
			worktree_path: worktree_path,
			pr_number: 51,
			pr_url: "https://github.com/test/repo/pull/51",
			status: "integrated",
			summary: "integrated into main",
			cause: nil
		)

		worktree = build_housekeep_worktree( path: worktree_path, branch: "feature/reused" )
		original_find = Carson::Worktree.method( :find )
		Carson::Worktree.define_singleton_method( :find ) { |path:, runtime:| worktree }
		runtime.define_singleton_method( :integrated_delivery_worktree_head ) { |worktree_path:| "new-head" }
		runtime.define_singleton_method( :git_run ) do |*args|
			git_calls << args
			[ "", "", true, 0 ]
		end

		runtime.send( :reap_integrated_delivery_worktrees! )

		refute_includes git_calls, [ "worktree", "remove", worktree_path ]
		refute_includes git_calls, [ "branch", "-D", "feature/reused" ]
		assert_empty runtime.ledger.integrated_deliveries( repo_path: repo_root )
		destroy_runtime_repo( repo_root: repo_root )
	ensure
		Carson::Worktree.define_singleton_method( :find, original_find ) if original_find
	end

end
