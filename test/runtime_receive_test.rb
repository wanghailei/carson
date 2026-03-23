# Tests for Carson's delivery-centred receive loop.
require_relative "test_helper"
require "shellwords"

class RuntimeReceiveTest < Minitest::Test
	include CarsonTestSupport

	def test_receive_dry_run_reports_no_active_deliveries
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "no active deliveries"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_marks_ready_delivery_for_integration
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/ready" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/ready", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		text = output_string( runtime )
		assert_includes text, "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_marks_gated_delivery_for_revision
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/gated" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/gated", status: "gated", summary: "CI checks are failing", cause: "ci" )
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "would revise (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_requires_refresh_for_freshness_blocked_delivery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/refresh-required" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/refresh-required",
			status: "queued",
			summary: "ready to integrate into main"
		)
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" }
		end
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "would require refresh (dry run)"
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "freshness", row.fetch( "cause" )
		assert_includes row.fetch( "summary" ), "behind origin/main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_summary_reports_held_at_gate_when_integration_fails
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
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :error ] = "merge conflict"
			Carson::Runtime::EXIT_ERROR
		end
		runtime.define_singleton_method( :housekeep_repo! ) { |repo_path:| flunk "housekeep should not run when merge fails" }

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "held at gate"
		refute_includes output, "integrated"
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "merge conflict", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_summary_reports_integrated_when_merge_succeeds
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

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "integrated"
		assert_includes output, "Merge proof: proven on main"
		refute_includes output, "held at gate"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_json_reports_merge_proof_after_integration
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/merge-proof-json" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/merge-proof-json",
			status: "queued",
			summary: "ready to integrate into main"
		)
		stub_reconciliation( runtime, delivery: delivery )
		stub_integration( runtime )

		result = runtime.receive!( dry_run: false, json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		row = data.fetch( "repository" ).fetch( "deliveries" ).first
		assert_equal "integrate", row.fetch( "action" )
		assert_equal "integrated", row.fetch( "status" )
		assert_equal true, row.dig( "merge_proof", "proven" )
		assert_equal "content_identical", row.dig( "merge_proof", "basis" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_reconciles_with_private_method_path
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/private-path" )
		create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/private-path", status: "queued", summary: "ready to integrate into main" )
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "OPEN" } }
		runtime.define_singleton_method( :assess_delivery! ) { |delivery:, branch_name:| delivery }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		refute_includes output_string( runtime ), "private method `reconcile_delivery!`"
		assert_includes output_string( runtime ), "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_does_not_depend_on_report_cache_path
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/no-cache" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/no-cache", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :report_dir_path ) { raise "receive should not write report cache" }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_includes output_string( runtime ), "ready to integrate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_from_root_sees_delivery_created_in_worktree
		with_feature_worktree_runtimes(
			branch_name: "codex/receive-worktree",
			worktree_name: "receive-worktree"
		) do |root_runtime, worktree_runtime, _repo_root, worktree_path|
			worktree_runtime.ledger.upsert_delivery(
				repository: worktree_runtime.send( :repository_record ),
				branch_name: "codex/receive-worktree",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 84,
				pr_url: "https://github.com/test/repo/pull/84",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)
			stub_reconciliation( root_runtime, delivery: nil )

			result = root_runtime.receive!( dry_run: true )
			assert_equal Carson::Runtime::EXIT_OK, result
			assert_includes output_string( root_runtime ), "ready to integrate (dry run)"
		end
	end

	def test_receive_integrates_first_ready_delivery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/integrate" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/integrate", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		stub_integration( runtime )

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		assert_equal "integrated into main", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_rechecks_github_state_before_merge
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/freshness-recheck" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/freshness-recheck",
			status: "queued",
			summary: "ready to integrate into main"
		)
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" }
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			raise "merge should not run when GitHub reports BEHIND"
		end

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "refresh required"
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "freshness", row.fetch( "cause" )
		assert_includes row.fetch( "summary" ), "behind origin/main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_does_not_run_housekeep_after_successful_merge
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/housekeep" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/housekeep", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :merge_method ] = "squash"
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :housekeep_one_entry ) do |repo_path:, silent:|
			raise "housekeep should not run after merge — receive uses fetch-only"
		end

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_escalates_delivery_after_three_revisions
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

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "escalated", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "revision limit"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_merged_pr_as_integrated
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/merged" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/merged", status: "queued",
			summary: "awaiting integration"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		refute_nil row.fetch( "integrated_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_stale_integrating_open_pr_back_to_queued
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/stale-open" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/stale-open",
			status: "integrating",
			summary: "integrating into main"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" } }
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "queued", row.fetch( "status" )
		assert_equal "ready to integrate into main", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_stale_integrating_merged_pr_as_integrated
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/stale-merged" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/stale-merged",
			status: "integrating",
			summary: "integrating into main"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		refute_nil row.fetch( "integrated_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_stale_integrating_closed_pr_as_failed
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/stale-closed" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/stale-closed",
			status: "integrating",
			summary: "integrating into main"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "failed", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "closed without integration"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_closed_pr_as_failed
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/closed" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/closed", status: "queued",
			summary: "awaiting integration"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "failed", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "closed without integration"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_advanced_head_as_superseded
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

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "superseded", row.fetch( "status" )
		refute_nil row.fetch( "superseded_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_does_not_mark_conflicting_pr_as_ready
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/conflicting" )
		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/conflicting",
			status: "queued",
			summary: "ready to integrate into main"
		)
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" }
		end
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		refute_includes output, "ready to integrate (dry run)"
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "merge", row.fetch( "cause" )
		assert_includes row.fetch( "summary" ), "merge conflicts"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_escalates_when_no_agent_provider
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

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "escalated", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "no agent provider"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_loop_prints_sleep_announcement
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		cycle_count = 0
		runtime.define_singleton_method( :loop_runner_sleep ) do |seconds|
			cycle_count += 1
			raise Interrupt if cycle_count >= 1
		end

		result = runtime.receive!( dry_run: true, loop_seconds: 300 )
		assert_equal Carson::Runtime::EXIT_OK, result
		text = output_string( runtime )
		assert_match( /sleeping 300s — next cycle at \d{4}-\d{2}-\d{2}/, text )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_loop_stops_after_term_requested_during_sleep
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		handlers = {}
		restored = []
		cycle_count = 0
		now = 0.0

		runtime.define_singleton_method( :loop_runner_trap ) do |signal_name, handler = nil, &block|
			if handler || block.nil?
				restored << [ signal_name, handler ]
				handler
			else
				handlers[ signal_name ] = block
				"DEFAULT-#{signal_name}"
			end
		end
		runtime.define_singleton_method( :loop_runner_monotonic_now ) { now }
		runtime.define_singleton_method( :loop_runner_sleep ) do |seconds|
			now += seconds
			handlers.fetch( "TERM" ).call
		end
		runtime.define_singleton_method( :receive_cycle! ) do |dry_run:, json_output:|
			cycle_count += 1
			Carson::Runtime::EXIT_OK
		end

		result = runtime.receive!( dry_run: true, loop_seconds: 300 )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal 1, cycle_count
		assert_includes restored, [ "INT", "DEFAULT-INT" ]
		assert_includes restored, [ "TERM", "DEFAULT-TERM" ]
		text = output_string( runtime )
		assert_match( /sleeping 300s — next cycle at \d{4}-\d{2}-\d{2}/, text )
		assert_includes text, "receive loop stopped after 1 cycle"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_prints_progress_hint_before_integration
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/hint" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/hint", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )
		stub_integration( runtime )

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		text = output_string( runtime )
		assert_includes text, "feature/hint — integrating"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_omits_progress_hints
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/dry" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/dry", status: "queued", summary: "ready to integrate into main" )
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		text = output_string( runtime )
		refute_match( /integrating…/, text )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_integrates_delivery_behind_locally_but_clean_on_github
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/behind-local-clean-gh" )

		# Advance main so the feature branch is locally behind
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Main advanced\n" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )

		delivery = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/behind-local-clean-gh",
			status: "queued",
			summary: "ready to integrate into main"
		)
		# GitHub says CLEAN even though local branch is behind main
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
		end
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		stub_integration( runtime )

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		assert_equal "integrated into main", row.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_integrates_later_ready_delivery_when_first_item_is_merge_blocked
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/conflicting" )
		create_feature_branch( repo_root, "feature/ready" )
		conflicting = create_delivery(
			runtime: runtime,
			repo_root: repo_root,
			branch_name: "feature/conflicting",
			status: "queued",
			summary: "ready to integrate into main"
		)
		ready = runtime.ledger.upsert_delivery(
			repository: runtime.send( :repository_record ),
			branch_name: "feature/ready",
			head: branch_head( repo_root: repo_root, branch_name: "feature/ready" ),
			worktree_path: repo_root,
			pr_number: 43,
			pr_url: "https://github.com/test/repo/pull/43",
			status: "queued",
			summary: "ready to integrate into main",
			cause: nil
		)
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			case number
			when 42 then { "state" => "OPEN", "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" }
			when 43 then { "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
			else { "state" => "OPEN" }
			end
		end
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		merged_numbers = []
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			merged_numbers << number
			result[ :merge_method ] = "squash"
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :fetch_for_merge_proof! ) { |repo_path:| nil }

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		assert_equal [ 43 ], merged_numbers
		conflicting_row = delivery_data( runtime: runtime, key: conflicting.key )
		assert_equal "gated", conflicting_row.fetch( "status" )
		assert_equal "merge", conflicting_row.fetch( "cause" )
		assert_includes conflicting_row.fetch( "summary" ), "merge conflicts"
		ready_row = delivery_data( runtime: runtime, key: ready.key )
		assert_equal "integrated", ready_row.fetch( "status" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- Filed delivery reconciliation ---

	def test_receive_reconciles_filed_delivery_as_integrated_when_pr_merged
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-merged" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-merged", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		refute_nil row.fetch( "integrated_at" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_filed_delivery_to_gated_when_ci_pending
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-pending" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-pending", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" } }
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pending }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "ci", row.fetch( "cause" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_reconciles_filed_delivery_as_failed_when_pr_closed
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-closed" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-closed", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "CLOSED" } }

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "failed", row.fetch( "status" )
		assert_includes row.fetch( "summary" ), "closed without integration"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_integrates_filed_delivery_when_all_clear
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-ready" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-ready", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		stub_integration( runtime )

		result = runtime.receive!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_unseals_worktree_for_filed_delivery
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-unseal" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-unseal", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		# Seal the worktree as the courier would have.
		warehouse = Carson::Warehouse.new( path: repo_root )
		warehouse.seal_shelf!( tracking_number: 42 )
		assert warehouse.sealed?, "precondition: worktree should be sealed"

		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		runtime.receive!( dry_run: false )
		refute warehouse.sealed?, "worktree should be unsealed after receive reconciles filed delivery"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_fails_filed_delivery_with_nil_pr_number
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-no-pr" )

		# Manually upsert with pr_number: nil to simulate the courier bug.
		repository = runtime.send( :repository_record )
		head = `git -C #{Shellwords.escape( repo_root )} rev-parse feature/filed-no-pr`.strip
		runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/filed-no-pr",
			head: head,
			worktree_path: repo_root,
			pr_number: nil,
			pr_url: nil,
			status: "filed",
			summary: "bureau undecided",
			cause: nil
		)

		result = runtime.receive!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result

		state = JSON.parse( File.read( runtime.ledger.path ) )
		entry = state[ "deliveries" ].values.find { |d| d[ "branch_name" ] == "feature/filed-no-pr" }
		assert_equal "failed", entry.fetch( "status" )
		assert_includes entry.fetch( "summary" ), "PR number missing"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_receive_dry_run_does_not_unseal_filed_worktree
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/filed-dry" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/filed-dry", status: "filed",
			summary: "bureau hasn't responded yet"
		)
		warehouse = Carson::Warehouse.new( path: repo_root )
		warehouse.seal_shelf!( tracking_number: 42 )

		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "MERGED" } }

		runtime.receive!( dry_run: true )
		assert warehouse.sealed?, "dry run should not unseal the worktree"
		warehouse.unseal_shelf!
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def stub_reconciliation( runtime, delivery: )
		expected_delivery = delivery
		runtime.define_singleton_method( :reconcile_delivery! ) { |delivery:| expected_delivery || delivery }
	end

	def stub_integration( runtime )
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :merge_method ] = "squash"
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :fetch_for_merge_proof! ) { |repo_path:| nil }
		runtime.define_singleton_method( :merge_proof_for_remote_ref ) do |branch:, remote: nil, main_ref: nil|
			{
				applicable: true,
				proven: true,
				basis: "content_identical",
				summary: "proven on main — 1 changed file already matches main.",
				main_branch: "main",
				changed_files_count: 1
			}
		end
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

		bare_remote = "#{repo_root}-remote.git"
		system( "git", "init", "--bare", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
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

	def freshness_assessment( status:, remote_ref:, detail: nil )
		assessment = {
			ready: status == :fresh,
			status: status,
			reason: status == :fresh ? "freshness_fresh" : "freshness_#{status}",
			summary: status == :fresh ? "verified freshness against #{remote_ref}" : "branch is behind #{remote_ref}",
			remote_ref: remote_ref
		}
		assessment[ :detail ] = detail if detail
		assessment
	end
end
