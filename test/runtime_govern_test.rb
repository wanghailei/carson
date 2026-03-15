# Tests for Carson's delivery-centred govern loop.
require_relative "test_helper"
require "shellwords"

class RuntimeGovernTest < Minitest::Test
	include CarsonTestSupport

	def test_govern_dry_run_reports_no_active_deliveries
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "no active deliveries"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_dry_run_marks_ready_delivery_for_integration
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/ready" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/ready", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		text = output_string( runtime )
		assert_includes text, "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_dry_run_marks_gated_delivery_for_revision
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/gated" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/gated", status: "gated", summary: "CI checks are failing", cause: "ci" )
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "would revise (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_summary_reports_held_at_gate_when_integration_fails
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/merge-blocked" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/merge-blocked",
			status: "queued",
			summary: "ready to integrate into main"
		)
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :error ] = "merge conflict"
			Carson::Runtime::EXIT_ERROR
		end
		runtime.define_singleton_method( :housekeep_repo! ) { |repo_path:| flunk "housekeep should not run when merge fails" }

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "held at gate"
		refute_includes output, "integrated"
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "merge conflict", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_summary_reports_integrated_when_merge_succeeds
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/merge-clean" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/merge-clean",
			status: "queued",
			summary: "ready to integrate into main"
		)
		stub_reconciliation( runtime, delivery: delivery )
		stub_integration( runtime )

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "integrated"
		refute_includes output, "held at gate"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_dry_run_reconciles_with_private_method_path
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/private-path" )
		create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/private-path", status: "queued", summary: "ready to integrate into main" )
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "OPEN" } }
		runtime.define_singleton_method( :assess_delivery! ) { |delivery:, branch_name:| delivery }

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		refute_includes output_string( runtime ), "private method `reconcile_delivery!`"
		assert_includes output_string( runtime ), "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_dry_run_does_not_depend_on_report_cache_path
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/no-cache" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/no-cache", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :report_dir_path ) { raise "govern should not write report cache" }

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_dry_run_from_root_sees_delivery_created_in_worktree
		with_feature_worktree_runtimes(
			branch_name: "codex/govern-worktree",
			worktree_name: "govern-worktree"
		) do |root_runtime, worktree_runtime, _repo_root, worktree_path|
			worktree_runtime.ledger.upsert_delivery(
				repository: worktree_runtime.send( :repository_record ),
				branch_name: "codex/govern-worktree",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 84,
				pr_url: "https://github.com/test/repo/pull/84",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)
			stub_reconciliation( root_runtime, delivery: nil )

			result = root_runtime.govern!( dry_run: true )
			assert_equal Carson::Runtime::EXIT_OK, result
			assert_includes output_string( root_runtime ), "ready to integrate (dry run)"
		end
	end

	def test_govern_integrates_first_ready_delivery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/integrate" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/integrate", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		stub_integration( runtime )

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		assert_equal "integrated into main", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_escalates_delivery_after_three_revisions
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/escalate" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/escalate",
			status: "gated",
			summary: "review changes requested",
			cause: "review",
			revision_count: 3
		)
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "escalated", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "revision limit"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_reconciles_merged_pr_as_integrated
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/merged" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/merged", status: "queued",
			summary: "awaiting integration"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		refute_nil row.fetch( "integrated_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_reconciles_closed_pr_as_failed
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/closed" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/closed", status: "queued",
			summary: "awaiting integration"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "failed", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "closed without integration"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_reconciles_advanced_head_as_superseded
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/advanced" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/advanced", status: "queued",
			summary: "original head"
		)

		# Advance the branch head after creating the delivery
		system( "git", "-C", repo_root, "checkout", "feature/advanced", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), "updated content" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "advance head", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "superseded", row.fetch( "status" )
		refute_nil row.fetch( "superseded_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_escalates_when_no_agent_provider
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/no-agent" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/no-agent", status: "gated",
			summary: "CI failing", cause: "ci"
		)
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :select_agent_provider ) { nil }

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "escalated", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "no agent provider"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def stub_reconciliation( runtime, delivery: )
		expected_delivery = delivery
		runtime.define_singleton_method( :reconcile_delivery! ) { |delivery:| expected_delivery || delivery }
	end

	def stub_integration( runtime )
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :merge_method ] = "squash"
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :housekeep_repo! ) { |repo_path:| Carson::Runtime::EXIT_OK }
	end

	def create_delivery( runtime:, repo_root:, branch_name:, status:, summary:, cause: nil, revision_count: 0 )
		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: branch_name,
			head: branch_head( repo_root: repo_root, branch_name: branch_name ),
			worktree_path: repo_root,
			pr_number: 42,
			pr_url: "https://github.com/test/repo/pull/42",
			status: status,
			summary: summary,
			cause: cause
		)
		# Simulate prior revisions to reach the desired count
		revision_count.times do |i|
			runtime.ledger.record_revision(
				delivery: delivery,
				cause: cause || "ci",
				provider: "codex",
				status: "failed",
				summary: "simulated revision #{i + 1}"
			)
		end
		# Re-fetch to get the delivery with embedded revisions
		runtime.ledger.active_delivery( repo_path: repository.path, branch_name: branch_name ) || delivery
	end

	def delivery_data( runtime:, key: )
		state = JSON.parse( File.read( runtime.ledger.path ) )
		state.dig( "deliveries", key )
	end

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), branch_name )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "feature", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
	end

	def branch_head( repo_root:, branch_name: )
		`git -C #{Shellwords.escape( repo_root )} rev-parse #{Shellwords.escape( branch_name )}`.strip
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
