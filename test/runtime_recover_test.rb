# Tests for governed recovery of a baseline-red governance check.
require_relative "test_helper"
require "json"
require "open3"

class RuntimeRecoverTest < Minitest::Test
	include CarsonTestSupport

	def test_recover_merges_when_named_baseline_check_is_red_and_branch_repairs_governance_surface
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/recover", governance_change: true )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/recover", status: "gated", summary: "CI checks are failing", cause: "ci" )

		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :recover_pull_request_details ) do |number:|
			{
				number: 42,
				url: "https://github.com/test/repo/pull/42",
				state: "OPEN",
				branch: "feature/recover",
				head_sha: current_head,
				base_branch: "main",
				base_sha: "base-sha",
				owner: "wanghailei",
				repo: "carson"
			}
		end
		runtime.define_singleton_method( :default_branch_ci_baseline_report ) do
			{
				status: "block",
				default_branch: "main",
				head_sha: "baseline-sha",
				failing: [ { name: "Carson governance", workflow: "workflow", state: "FAILURE", link: "" } ],
				pending: []
			}
		end
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "review gate passed" } }
		runtime.define_singleton_method( :recover_required_pr_checks_report ) do |number:|
			{
				status: "ok",
				required_total: 1,
				failing: [ { workflow: "workflow", name: "Carson governance", state: "FAILURE", link: "" } ],
				pending: []
			}
		end
		runtime.define_singleton_method( :pull_request_state ) { |number:| { "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "BLOCKED" } }
		runtime.define_singleton_method( :recover_merge_pr! ) do |number:, owner:, repo:, head_sha:, result:|
			result[ :merge_method ] = "squash"
			result[ :merge ] = { status: "recovered", summary: "merged via governed recovery", method: "squash" }
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :sync_after_merge! ) do |remote:, main:, result:|
			result[ :synced ] = true
		end

		result = runtime.recover!( check_name: "Carson governance", json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result

		data = JSON.parse( output_string( runtime ) )
		assert_equal "recover", data.fetch( "command" )
		assert_equal 42, data.fetch( "pr_number" )
		assert_equal "baseline-sha", data.dig( "baseline", "head_sha" )
		assert_equal "integrated", data.dig( "delivery", "status" )
		assert_equal "carson housekeep", data.fetch( "next_step" )

		row = delivery_row_for( runtime: runtime, branch_name: "feature/recover" )
		assert_equal "integrated", row.fetch( "status" )
		assert_equal "recovered Carson governance into main", row.fetch( "summary" )

		events = recovery_events_for( runtime: runtime )
		assert_equal 1, events.length
		event = events.first
		assert_equal runtime.main_worktree_root, event.fetch( "repository" )
		assert_equal "feature/recover", event.fetch( "branch_name" )
		assert_equal 42, event.fetch( "pr_number" )
		assert_equal "Carson governance", event.fetch( "check_name" )
		assert_equal "baseline-sha", event.fetch( "default_branch_sha" )
		assert_equal branch_head( repo_root: repo_root, branch_name: "feature/recover" ), event.fetch( "pr_sha" )
		refute_nil event.fetch( "actor" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_recover_blocks_when_named_check_is_not_red_on_default_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/no-baseline-red", governance_change: true )
		create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/no-baseline-red", status: "gated", summary: "CI checks are failing", cause: "ci" )

		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :recover_pull_request_details ) do |number:|
			{
				number: 42,
				url: "https://github.com/test/repo/pull/42",
				state: "OPEN",
				branch: "feature/no-baseline-red",
				head_sha: current_head,
				base_branch: "main",
				base_sha: "base-sha",
				owner: "wanghailei",
				repo: "carson"
			}
		end
		runtime.define_singleton_method( :default_branch_ci_baseline_report ) do
			{
				status: "ok",
				default_branch: "main",
				head_sha: "baseline-sha",
				failing: [],
				pending: []
			}
		end

		result = runtime.recover!( check_name: "Carson governance", json_output: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		data = JSON.parse( output_string( runtime ) )
		assert_includes data.fetch( "error" ), "is not red on main"

		assert_equal [], recovery_events_for( runtime: runtime )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_recover_blocks_when_other_required_checks_are_still_failing
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/other-checks", governance_change: true )
		create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/other-checks", status: "gated", summary: "CI checks are failing", cause: "ci" )

		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :recover_pull_request_details ) do |number:|
			{
				number: 42,
				url: "https://github.com/test/repo/pull/42",
				state: "OPEN",
				branch: "feature/other-checks",
				head_sha: current_head,
				base_branch: "main",
				base_sha: "base-sha",
				owner: "wanghailei",
				repo: "carson"
			}
		end
		runtime.define_singleton_method( :default_branch_ci_baseline_report ) do
			{
				status: "block",
				default_branch: "main",
				head_sha: "baseline-sha",
				failing: [ { name: "Carson governance", workflow: "workflow", state: "FAILURE", link: "" } ],
				pending: []
			}
		end
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "review gate passed" } }
		runtime.define_singleton_method( :recover_required_pr_checks_report ) do |number:|
			{
				status: "ok",
				required_total: 2,
				failing: [
					{ workflow: "workflow", name: "Carson governance", state: "FAILURE", link: "" },
					{ workflow: "workflow", name: "Unit tests", state: "FAILURE", link: "" }
				],
				pending: []
			}
		end
		runtime.define_singleton_method( :recover_merge_pr! ) { |**kwargs| flunk "recover must not merge while other checks are failing" }

		result = runtime.recover!( check_name: "Carson governance", json_output: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		data = JSON.parse( output_string( runtime ) )
		assert_includes data.fetch( "error" ), "Unit tests"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_recover_blocks_when_branch_does_not_touch_governance_surface
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/unrelated", governance_change: false )
		create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/unrelated", status: "gated", summary: "CI checks are failing", cause: "ci" )

		runtime.define_singleton_method( :gh_available? ) { true }
		runtime.define_singleton_method( :recover_pull_request_details ) do |number:|
			{
				number: 42,
				url: "https://github.com/test/repo/pull/42",
				state: "OPEN",
				branch: "feature/unrelated",
				head_sha: current_head,
				base_branch: "main",
				base_sha: "base-sha",
				owner: "wanghailei",
				repo: "carson"
			}
		end

		result = runtime.recover!( check_name: "Carson governance", json_output: true )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		data = JSON.parse( output_string( runtime ) )
		assert_includes data.fetch( "error" ), "does not touch the governance surface"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo_with_remote( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )

		bare_remote = "#{repo_root}-remote.git"
		system( "git", "init", "--bare", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
	end

	def create_feature_branch( repo_root, branch_name, governance_change: )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), branch_name )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "feature", out: File::NULL, err: File::NULL )

		return unless governance_change

		FileUtils.mkdir_p( File.join( repo_root, ".github", "workflows" ) )
		File.write( File.join( repo_root, ".github", "workflows", "governance.yml" ), "name: Governance\n" )
		system( "git", "-C", repo_root, "add", ".github/workflows/governance.yml", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "repair governance", out: File::NULL, err: File::NULL )
	end

	def create_delivery( runtime:, repo_root:, branch_name:, status:, summary:, cause: nil )
		runtime.ledger.upsert_delivery(
			repository: runtime.send( :repository_record ),
			branch_name: branch_name,
			head: branch_head( repo_root: repo_root, branch_name: branch_name ),
			worktree_path: repo_root,
			pr_number: 42,
			pr_url: "https://github.com/test/repo/pull/42",
			status: status,
			summary: summary,
			cause: cause
		)
	end

	def branch_head( repo_root:, branch_name: )
		stdout, _stderr, status = Open3.capture3( "git", "-C", repo_root, "rev-parse", branch_name )
		raise "git rev-parse #{branch_name} failed" unless status.success?
		stdout.strip
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def delivery_row_for( runtime:, branch_name: )
		state = JSON.parse( File.read( runtime.ledger.path ) )
		state.fetch( "deliveries" )
			.values
			.select { |row| row.fetch( "repo_path" ) == runtime.main_worktree_root && row.fetch( "branch_name" ) == branch_name }
			.max_by { |row| row.fetch( "updated_at" ).to_s }
	end

	def recovery_events_for( runtime: )
		state = JSON.parse( File.read( runtime.ledger.path ) )
		state.fetch( "recovery_events" ).select do |event|
			event.fetch( "repository" ) == runtime.main_worktree_root
		end
	end
end
