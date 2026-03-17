# Tests for the synchronous branch-delivery contract.
require_relative "test_helper"

class RuntimeDeliverTest < Minitest::Test
	include CarsonTestSupport

	def test_deliver_blocks_on_main_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output_string( runtime ), "cannot deliver from main"
		assert_includes output_string( runtime ), "carson worktree create <name>"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_blocks_when_worktree_is_dirty_without_commit_flag
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/dirty-block" )
		File.write( File.join( repo_root, "README.md" ), "# Dirty\n" )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "working tree is dirty"
		assert_includes output, "carson deliver --commit"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_blocks_before_push_when_branch_is_behind_remote_main
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/behind-prepush" )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Main advanced\n" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "feature/behind-prepush", out: File::NULL, err: File::NULL )

		result = runtime.deliver!
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "branch is behind origin/main"
		assert_includes output, "git rebase origin/main && carson deliver"
		refute system(
			"git", "-C", "#{repo_root}-remote.git",
			"show-ref", "--verify", "refs/heads/feature/behind-prepush",
			out: File::NULL, err: File::NULL
		)
		assert_empty delivery_rows_for( runtime: runtime, branch_name: "feature/behind-prepush" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_blocks_when_freshness_cannot_be_verified_before_push
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/freshness-unknown" )
		original_git_run = runtime.method( :git_run )
		runtime.define_singleton_method( :git_run ) do |*args|
			return [ "", "network timeout", false, 1 ] if args[ 0 ] == "fetch"

			original_git_run.call( *args )
		end

		result = runtime.deliver!( json_output: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "unknown", data.dig( "freshness", "status" )
		assert_equal runtime.send( :config ).govern_check_wait, data.fetch( "watch_window_seconds" )
		assert_equal 0, data.fetch( "waited_seconds" )
		assert_equal false, data.fetch( "merge_attempted" )
		assert_includes data.fetch( "error" ), "could not verify freshness"
		assert_includes data.fetch( "recovery" ), "git fetch origin main"
		assert_empty delivery_rows_for( runtime: runtime, branch_name: "feature/freshness-unknown" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_with_commit_json_reports_created_commit_for_all_dirty_changes
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/commit-all" )
		stub_ready_assessment( runtime )

		File.write( File.join( repo_root, "README.md" ), "# Updated\n" )
		File.write( File.join( repo_root, "notes.txt" ), "fresh\n" )
		system( "git", "-C", repo_root, "rm", "feature.txt", out: File::NULL, err: File::NULL )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( commit_message: "fix: commit dirty tree", json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result

		data = JSON.parse( output_string( runtime ) )
		assert_equal "created", data.dig( "commit", "status" )
		assert_equal "fix: commit dirty tree", data.dig( "commit", "message" )
		assert_equal "fix: commit dirty tree", git_capture( repo_root, "log", "-1", "--pretty=%s", "feature/commit-all" )
		changed_files = git_capture( repo_root, "show", "--pretty=", "--name-only", "feature/commit-all" ).split( "\n" )
		assert_includes changed_files, "README.md"
		assert_includes changed_files, "notes.txt"
		assert_includes changed_files, "feature.txt"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_with_commit_blocks_when_tree_is_clean_even_with_unpushed_commits
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/clean-commit-block" )

		result = runtime.deliver!( commit_message: "fix: should block" )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		output = output_string( runtime )
		assert_includes output, "working tree is already clean"
		assert_includes output, "carson deliver"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_with_commit_creates_agent_commit_after_template_sync_commit
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/template-then-agent" )
		stub_ready_assessment( runtime )

		File.write( File.join( repo_root, "README.md" ), "# User change\n" )
		FileUtils.mkdir_p( File.join( repo_root, ".github" ) )
		File.write( File.join( repo_root, ".github", "carson.md" ), "managed\n" )
		runtime.define_singleton_method( :deliver_template_sync ) do
			system( "git", "-C", repo_root, "add", ".github/carson.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "chore: sync Carson managed files", out: File::NULL, err: File::NULL )
			[ Carson::Runtime::EXIT_BLOCK, "Carson committed managed file updates. Push again to include them." ]
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( commit_message: "fix: user delivery", json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "created", data.dig( "commit", "status" )
		assert_equal [ "fix: user delivery", "chore: sync Carson managed files" ], git_log_subjects( repo_root, count: 2, ref: "feature/template-then-agent" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_with_commit_skips_agent_commit_when_template_sync_consumes_all_pending_changes
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/template-only" )
		stub_ready_assessment( runtime )

		FileUtils.mkdir_p( File.join( repo_root, ".github" ) )
		File.write( File.join( repo_root, ".github", "carson.md" ), "managed\n" )
		runtime.define_singleton_method( :deliver_template_sync ) do
			system( "git", "-C", repo_root, "add", ".github/carson.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "chore: sync Carson managed files", out: File::NULL, err: File::NULL )
			[ Carson::Runtime::EXIT_BLOCK, "Carson committed managed file updates. Push again to include them." ]
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( commit_message: "fix: should skip", json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "skipped", data.dig( "commit", "status" )
		assert_includes data.dig( "commit", "summary" ), "template sync"
		assert_equal "chore: sync Carson managed files", git_capture( repo_root, "log", "-1", "--pretty=%s", "feature/template-only" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_integrates_delivery_when_branch_is_ready
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/queued" )
		stub_ready_assessment( runtime )
		runtime.define_singleton_method( :merge_proof_for_branch ) do |branch:, main_ref:|
			{
				applicable: true,
				proven: true,
				basis: "ancestor",
				summary: "proven on main — branch tip is already on #{main_ref}.",
				main_branch: main_ref,
				changed_files_count: 1
			}
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR #99"
		assert_includes output, "Delivery:"
		assert_includes output, "feature/queued → origin/main"
		assert_includes output, "Merged into origin/main with squash."
		assert_includes output, "Synced local main."
		assert_includes output, "Merge proof: proven on main"

		delivery = runtime.ledger.active_delivery( repo_path: runtime.main_worktree_root, branch_name: "feature/queued" )
		assert_nil delivery
		delivery = delivery_row_for( runtime: runtime, branch_name: "feature/queued" )
		refute_nil delivery
		assert_equal "integrated", delivery.fetch( "status" )
		assert_equal "integrated into main", delivery.fetch( "summary" )
		assert_equal 99, delivery.fetch( "pr_number" )
		assert_equal true, delivery.dig( "merge_proof", "proven" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_defers_delivery_when_ci_is_pending
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/gated" )
		stub_assessment( runtime, ci: :pending, review: { status: :pass, review: :approved, detail: "" } )
		configure_settle_window( runtime, watch_window_seconds: 0, poll_seconds: 1 )
		stub_settle_clock( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Merge deferred — waiting for CI checks."
		assert_includes output, "Carson did not attempt merge in this run."
		assert_includes output, "carson status"
		assert_includes output, "carson deliver"
		assert_includes output, "carson govern --loop 300"
		delivery = runtime.ledger.active_delivery( repo_path: runtime.main_worktree_root, branch_name: "feature/gated" )
		assert_equal "gated", delivery.status
		assert_equal "ci", delivery.cause
		assert_includes delivery.summary, "waiting for CI"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_merges_after_mergeability_settles_within_watch_window
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/settles" )
		stub_ready_assessment( runtime )
		configure_settle_window( runtime, watch_window_seconds: 2, poll_seconds: 1 )
		stub_settle_clock( runtime )
		stub_pull_request_states(
			runtime,
			[
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
			]
		)

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Merged into origin/main with squash."
		delivery = delivery_row_for( runtime: runtime, branch_name: "feature/settles" )
		assert_equal "integrated", delivery.fetch( "status" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_caps_transient_merge_attempts_before_deferred_handoff
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/retry-cap" )
		stub_ready_assessment( runtime )
		configure_settle_window( runtime, watch_window_seconds: 5, poll_seconds: 1 )
		stub_settle_clock( runtime )
		stub_pull_request_states(
			runtime,
			Array.new( 8 ) do
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" }
			end
		)
		merge_attempts = 0
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			merge_attempts += 1
			result[ :merge_method ] = "squash"
			result[ :error ] = "merge failed"
			result[ :recovery ] = "gh pr merge #{number} --squash"
			Carson::Runtime::EXIT_ERROR
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "deferred", data.fetch( "outcome" )
		assert_equal true, data.fetch( "merge_attempted" )
		assert_equal 5, data.fetch( "waited_seconds" )
		assert_equal "mergeability_pending", data.dig( "handoff", "reason" )
		assert_equal [ "carson status", "carson deliver", "carson govern --loop 300" ], data.dig( "handoff", "next_steps" )
		assert_equal 3, merge_attempts
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_probes_once_after_one_successful_reassessment
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/probe-after-reassessment" )
		stub_ready_assessment( runtime )
		configure_settle_window( runtime, watch_window_seconds: 1, poll_seconds: 1 )
		stub_settle_clock( runtime )
		stub_pull_request_states(
			runtime,
			Array.new( 3 ) do
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" }
			end
		)
		freshness = freshness_assessment( status: :fresh, remote_ref: "origin/main" )
		runtime.define_singleton_method( :assess_branch_freshness ) do |branch_name: nil, head_ref: nil, remote:, main:|
			freshness
		end
		merge_attempts = 0
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			merge_attempts += 1
			result[ :error ] = "mergeability still pending"
			Carson::Runtime::EXIT_ERROR
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "deferred", data.fetch( "outcome" )
		assert_equal true, data.fetch( "merge_attempted" )
		assert_equal 1, merge_attempts
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_blocks_when_branch_becomes_behind_during_settle
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/freshness-drifts" )
		stub_ready_assessment( runtime )
		configure_settle_window( runtime, watch_window_seconds: 2, poll_seconds: 1 )
		stub_settle_clock( runtime )
		stub_pull_request_states(
			runtime,
			Array.new( 4 ) do
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" }
			end
		)
		freshness = [
			freshness_assessment( status: :fresh, remote_ref: "origin/main" ),
			freshness_assessment( status: :behind, remote_ref: "origin/main" )
		]
		runtime.define_singleton_method( :assess_branch_freshness ) do |branch_name: nil, head_ref: nil, remote:, main:|
			freshness.shift || freshness.last
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			raise "merge should not run after freshness blocks the delivery"
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "blocked", data.fetch( "outcome" )
		assert_equal "behind", data.dig( "freshness", "status" )
		assert_equal "freshness_behind", data.dig( "handoff", "reason" )
		assert_equal false, data.fetch( "merge_attempted" )
		assert_includes data.fetch( "summary" ), "behind origin/main"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_prints_handoff_steps_when_branch_becomes_behind_during_settle
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/freshness-drifts-human" )
		stub_ready_assessment( runtime )
		configure_settle_window( runtime, watch_window_seconds: 2, poll_seconds: 1 )
		stub_settle_clock( runtime )
		stub_pull_request_states(
			runtime,
			Array.new( 4 ) do
				{ "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" }
			end
		)
		freshness = [
			freshness_assessment( status: :fresh, remote_ref: "origin/main" ),
			freshness_assessment( status: :behind, remote_ref: "origin/main" )
		]
		runtime.define_singleton_method( :assess_branch_freshness ) do |branch_name: nil, head_ref: nil, remote:, main:|
			freshness.shift || freshness.last
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Merge blocked — branch is behind origin/main."
		assert_includes output, "carson status"
		assert_includes output, "carson deliver"
		assert_includes output, "carson govern --loop 300"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_assess_delivery_marks_conflicting_pr_as_merge_blocked
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/conflicting" )
		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/conflicting",
			head: git_capture( repo_root, "rev-parse", "feature/conflicting" ),
			worktree_path: repo_root,
			pr_number: 99,
			pr_url: "https://github.com/test/repo/pull/99",
			status: "preparing",
			summary: "delivery accepted",
			cause: nil
		)
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" }
		end

		updated = runtime.send( :assess_delivery!, delivery: delivery, branch_name: "feature/conflicting" )
		assert_equal "gated", updated.status
		assert_equal "merge", updated.cause
		assert_equal "pull request has merge conflicts", updated.summary
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_assess_delivery_marks_behind_pr_as_freshness_blocked
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/behind" )
		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/behind",
			head: git_capture( repo_root, "rev-parse", "feature/behind" ),
			worktree_path: repo_root,
			pr_number: 99,
			pr_url: "https://github.com/test/repo/pull/99",
			status: "preparing",
			summary: "delivery accepted",
			cause: nil
		)
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" }
		end

		updated = runtime.send( :assess_delivery!, delivery: delivery, branch_name: "feature/behind" )
		assert_equal "gated", updated.status
		assert_equal "freshness", updated.cause
		assert_includes updated.summary, "behind origin/main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_assess_delivery_marks_draft_pr_as_policy_blocked
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/draft" )
		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/draft",
			head: git_capture( repo_root, "rev-parse", "feature/draft" ),
			worktree_path: repo_root,
			pr_number: 99,
			pr_url: "https://github.com/test/repo/pull/99",
			status: "preparing",
			summary: "delivery accepted",
			cause: nil
		)
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "isDraft" => true, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" }
		end

		updated = runtime.send( :assess_delivery!, delivery: delivery, branch_name: "feature/draft" )
		assert_equal "gated", updated.status
		assert_equal "policy", updated.cause
		assert_equal "pull request is still a draft", updated.summary
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_deliver_defers_when_assessment_is_unavailable
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/assessment-unavailable" )
		stub_assessment( runtime, ci: :pass, review: { status: :pass, review: :approved, detail: "" } )
		configure_settle_window( runtime, watch_window_seconds: 0, poll_seconds: 1 )
		stub_settle_clock( runtime )
		runtime.define_singleton_method( :pull_request_state ) { |number:| nil }

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal "deferred", data.fetch( "outcome" )
		assert_equal false, data.fetch( "merge_attempted" )
		assert_equal "assessment_unavailable", data.dig( "handoff", "reason" )
		refute_nil data.fetch( "watch_window_seconds" )
		refute_nil data.fetch( "waited_seconds" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_json_reports_delivery_payload
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/json" )
		stub_ready_assessment( runtime )
		runtime.define_singleton_method( :merge_proof_for_branch ) do |branch:, main_ref:|
			{
				applicable: true,
				proven: true,
				basis: "ancestor",
				summary: "proven on main — branch tip is already on #{main_ref}.",
				main_branch: main_ref,
				changed_files_count: 1
			}
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal 42, data.fetch( "pr_number" )
		assert_equal "integrated", data.dig( "delivery", "status" )
		assert_equal "carson housekeep", data.fetch( "next_step" )
		assert_equal true, data.fetch( "merge_attempted" )
		assert_equal "integrated", data.fetch( "outcome" )
		assert_equal true, data.dig( "merge_proof", "proven" )
		assert_equal "ancestor", data.dig( "merge_proof", "basis" )
		assert data.key?( "watch_window_seconds" )
		assert data.key?( "waited_seconds" )
		refute data.key?( "handoff" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_reports_unavailable_merge_proof_when_local_sync_fails
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/sync-fail-proof" )
		stub_ready_assessment( runtime )
		runtime.define_singleton_method( :sync_after_merge! ) do |remote:, main:, result:|
			result[ :synced ] = false
			result[ :sync_error ] = "simulated sync failure"
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal false, data.dig( "merge_proof", "proven" )
		assert_equal "unavailable", data.dig( "merge_proof", "basis" )
		assert_equal "carson sync", data.fetch( "next_step" )
		assert_includes data.dig( "merge_proof", "summary" ), "sync failed"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_is_idempotent_for_same_branch_head
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/idempotent" )
		stub_ready_assessment( runtime )

		first = with_env( "PATH" => mock_path ) { runtime.deliver! }
		system( "git", "-C", repo_root, "switch", "feature/idempotent", out: File::NULL, err: File::NULL )
		second = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, first
		assert_equal Carson::Runtime::EXIT_OK, second

		deliveries = delivery_rows_for( runtime: runtime, branch_name: "feature/idempotent" )
		assert_equal 1, deliveries.size
		assert_equal "integrated", deliveries.first.fetch( "status" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_supersedes_older_delivery_on_new_head
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/supersede" )
		stub_assessment( runtime, ci: :pending, review: { status: :pass, review: :approved, detail: "" } )
		configure_settle_window( runtime, watch_window_seconds: 0, poll_seconds: 1 )
		stub_settle_clock( runtime )

		assert_equal Carson::Runtime::EXIT_OK, with_env( "PATH" => mock_path ) { runtime.deliver! }
		first_delivery = delivery_row_for( runtime: runtime, branch_name: "feature/supersede" )

		File.write( File.join( repo_root, "feature.txt" ), "updated" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "update head", out: File::NULL, err: File::NULL )

		assert_equal Carson::Runtime::EXIT_OK, with_env( "PATH" => mock_path ) { runtime.deliver! }

		active = runtime.ledger.active_delivery( repo_path: runtime.main_worktree_root, branch_name: "feature/supersede" )
		refute_equal first_delivery.fetch( "head" ), active.head
		state = JSON.parse( File.read( runtime.ledger.path ) )
		statuses = state[ "deliveries" ]
			.select { |_k, d| d[ "branch_name" ] == "feature/supersede" }
			.sort_by { |_k, d| d[ "created_at" ] }
			.map { |_k, d| d[ "status" ] }
		assert_equal [ "superseded", "gated" ], statuses
		FileUtils.remove_entry( tmp_dir )
	end

	def test_sync_after_merge_detects_pull_failure
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )

		result = {}
		# Call sync_after_merge! against the repo whose remote has no new
		# commits — git pull --ff-only will succeed, so we need to break it.
		# Remove the remote to force a failure.
		system( "git", "-C", repo_root, "remote", "remove", "origin", out: File::NULL, err: File::NULL )

		runtime.send( :sync_after_merge!, remote: "origin", main: "main", result: result )

		assert_equal false, result[ :synced ]
		refute_nil result[ :sync_error ]
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_reports_push_failure
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/push-fail" )
		stub_ready_assessment( runtime )

		# Stub git_run at the adapter boundary to simulate push rejection
		original_git_run = runtime.method( :git_run )
		runtime.define_singleton_method( :git_run ) do |*args|
			if args.include?( "push" )
				[ "", "fatal: could not push\n", false, 1 ]
			else
				original_git_run.call( *args )
			end
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = output_string( runtime )
		assert_includes output, "could not push"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_reports_pr_creation_failure
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh_failing_create
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/no-pr" )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = output_string( runtime )
		assert_includes output, "authentication required"
		assert_includes output, "gh pr create"
		FileUtils.remove_entry( tmp_dir )
	end

private

	def stub_ready_assessment( runtime )
		stub_assessment( runtime, ci: :pass, review: { status: :pass, review: :approved, detail: "" } )
	end

	def stub_assessment( runtime, ci:, review: )
		runtime.define_singleton_method( :check_pr_ci ) { |number:| ci }
		runtime.define_singleton_method( :settle_check_pr_ci ) { |number:| ci }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| review }
	end

	def stub_pull_request_states( runtime, states )
		queue = states.dup
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			queue.shift || states.last
		end
	end

	def configure_settle_window( runtime, watch_window_seconds:, poll_seconds: )
		config = runtime.send( :config )
		config.instance_variable_set( :@govern_check_wait, watch_window_seconds )
		config.instance_variable_set( :@review_poll_seconds, poll_seconds )
	end

	def stub_settle_clock( runtime, start: 0.0 )
		clock = start
		runtime.define_singleton_method( :deliver_monotonic_now ) { clock }
		runtime.define_singleton_method( :deliver_sleep ) { |seconds| clock += seconds }
	end

	def build_runtime_with_mock_gh( existing_pr: )
		tmp_dir = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
		repo_root = File.join( tmp_dir, "repo" )
		FileUtils.mkdir_p( repo_root )

		mock_bin = File.join( tmp_dir, "mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		File.write( File.join( mock_bin, "gh" ), mock_gh_script( existing_pr: existing_pr ) )
		FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

		output = StringIO.new
		error = StringIO.new
		config_path = write_runtime_config( tmp_dir: tmp_dir )
		runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime = Carson::Runtime.new(
				repo_root: repo_root,
				tool_root: File.expand_path( "..", __dir__ ),
				output: output,
				error: error,
				verbose: false
			)
		end
		[ runtime, repo_root, "#{mock_bin}:#{ENV.fetch( 'PATH' )}", tmp_dir ]
	end

	def mock_gh_script( existing_pr: )
		<<~BASH
			#!/usr/bin/env bash
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				if [[ "$3" =~ ^[0-9]+$ ]]; then
					number="$3"
					cat <<JSON
			{"number":${number},"url":"https://github.com/test/repo/pull/${number}","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}
			JSON
					exit 0
				fi
				if #{existing_pr ? "true" : "false"}; then
					cat <<'JSON'
			{"number":42,"url":"https://github.com/test/repo/pull/42","state":"OPEN"}
			JSON
					exit 0
				fi
				echo "not found" >&2
				exit 1
			fi

			if [[ "$1" == "pr" && "$2" == "create" ]]; then
				echo "https://github.com/test/repo/pull/99"
				exit 0
			fi

			if [[ "$1" == "pr" && "$2" == "merge" ]]; then
				exit 0
			fi

			if [[ "$1" == "pr" && "$2" == "checks" ]]; then
				echo "[]"
				exit 0
			fi

			if [[ "$1" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi

			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def init_git_repo_with_remote( repo_root )
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
	end

	def build_runtime_with_mock_gh_failing_create
		tmp_dir = Dir.mktmpdir( "carson-deliver-test", carson_tmp_root )
		repo_root = File.join( tmp_dir, "repo" )
		FileUtils.mkdir_p( repo_root )

		mock_bin = File.join( tmp_dir, "mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		File.write( File.join( mock_bin, "gh" ), <<~BASH )
			#!/usr/bin/env bash
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				echo "not found" >&2
				exit 1
			fi
			if [[ "$1" == "pr" && "$2" == "create" ]]; then
				echo "authentication required" >&2
				exit 1
			fi
			if [[ "$1" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi
			echo "unsupported: $*" >&2
			exit 1
		BASH
		FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

		output = StringIO.new
		error = StringIO.new
		config_path = write_runtime_config( tmp_dir: tmp_dir )
		runtime = nil
		with_env( "CARSON_CONFIG_FILE" => config_path ) do
			runtime = Carson::Runtime.new(
				repo_root: repo_root, tool_root: File.expand_path( "..", __dir__ ),
				output: output, error: error, verbose: false
			)
		end
		[ runtime, repo_root, "#{mock_bin}:#{ENV.fetch( 'PATH' )}", tmp_dir ]
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def delivery_row_for( runtime:, branch_name: )
		delivery_rows_for( runtime: runtime, branch_name: branch_name ).last
	end

	def delivery_rows_for( runtime:, branch_name: )
		return [] unless File.exist?( runtime.ledger.path )

		state = JSON.parse( File.read( runtime.ledger.path ) )
		state.fetch( "deliveries" )
			.values
			.select { |row| row.fetch( "repo_path" ) == runtime.main_worktree_root && row.fetch( "branch_name" ) == branch_name }
			.sort_by { |row| row.fetch( "created_at" ).to_s }
	end

	def git_capture( repo_root, *args )
		stdout, _stderr, status = Open3.capture3( "git", "-C", repo_root, *args )
		raise "git #{args.join( ' ' )} failed" unless status.success?
		stdout.strip
	end

	def build_delivery( status:, cause:, summary: )
		Carson::Delivery.new(
			repo_path: "/tmp/repo",
			branch: "feature/review",
			head: "abc123",
			worktree_path: "/tmp/repo/.claude/worktrees/review",
			status: status,
			pull_request_number: 1,
			pull_request_url: "https://github.com/test/repo/pull/1",
			cause: cause,
			summary: summary,
			created_at: Time.now.utc.iso8601,
			updated_at: Time.now.utc.iso8601,
			integrated_at: nil,
			superseded_at: nil
		)
	end

	def git_log_subjects( repo_root, count:, ref: nil )
		args = [ "log", "-n", count.to_s, "--pretty=%s" ]
		args << ref if ref
		git_capture( repo_root, *args ).split( "\n" )
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

	def write_runtime_config( tmp_dir: )
		config_path = File.join( tmp_dir, "carson-config.json" )
		File.write(
			config_path,
			JSON.generate(
				{
					"govern" => {
						"state_path" => File.join( tmp_dir, "carson-state.json" )
					}
				}
			)
		)
		config_path
	end
end
