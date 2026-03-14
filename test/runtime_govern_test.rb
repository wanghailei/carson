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
		assert_includes text, "queued -> would_integrate"
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
		assert_includes output_string( runtime ), "gated -> would_revise"
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
		assert_includes output_string( runtime ), "queued -> would_integrate"
		destroy_runtime_repo( repo_root: repo_root )
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
		integrated = delivery_row( runtime: runtime, id: delivery.id )
		assert_equal "integrated", integrated.fetch( "status" )
		assert_equal "integrated into main", integrated.fetch( "summary" )
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
		escalated = delivery_row( runtime: runtime, id: delivery.id )
		assert_equal "escalated", escalated.fetch( "status" )
		assert_includes escalated.fetch( "summary" ), "revision limit"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def stub_reconciliation( runtime, delivery: )
		runtime.define_singleton_method( :reconcile_delivery! ) { |delivery:| delivery }
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
			authority: "remote",
			pr_number: 42,
			pr_url: "https://github.com/test/repo/pull/42",
			status: status,
			summary: summary,
			cause: cause
		)
		runtime.ledger.update_delivery( delivery: delivery, revision_count: revision_count )
	end

	def delivery_row( runtime:, id: )
		runtime.ledger.send( :with_database ) do |database|
			database.get_first_row( "SELECT * FROM deliveries WHERE id = ?", [ id ] )
		end
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
