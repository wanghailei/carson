# Tests for the delivery-centred status command.
require_relative "test_helper"

class RuntimeStatusTest < Minitest::Test
	include CarsonTestSupport

	def test_status_returns_exit_ok
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		result = runtime.status!
		assert_equal Carson::Runtime::EXIT_OK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_human_output_reports_repository_and_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!
		output = output_string( runtime )
		assert_includes output, Carson::VERSION
		assert_includes output, "On main"
		assert_includes output, "No active deliveries."
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_human_output_points_to_worktree_list_when_non_main_worktrees_exist
		with_feature_worktree_runtimes(
			branch_name: "codex/status-pointer",
			worktree_name: "status-pointer"
		) do |root_runtime, _worktree_runtime, _repo_root, _worktree_path|
			root_runtime.status!
			output = output_string( root_runtime )
			assert_includes output, "Worktrees: 1 tracked outside main — run carson worktree list."
		end
	end

	def test_status_json_reports_repository_and_branches
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert_equal Carson::VERSION, data.fetch( "version" )
		assert_equal "main", data.dig( "branch", "name" )
		assert_equal [], data.fetch( "branches" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_lists_active_deliveries_from_ledger
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/status" )

		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/status",
			head: runtime.send( :current_head ),
			worktree_path: repo_root,
			pr_number: 12,
			pr_url: "https://github.com/test/repo/pull/12",
			status: "queued",
			summary: "ready to integrate into main",
			cause: nil
		)

		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		entry = data.fetch( "branches" ).find { |row| row.fetch( "branch" ) == delivery.branch }
		refute_nil entry
		assert_equal "queued", entry.fetch( "delivery_state" )
		assert_equal 12, entry.fetch( "pr_number" )
		assert_equal "ready to integrate into main", entry.fetch( "summary" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_from_worktree_uses_canonical_repository_path_and_lists_active_delivery
		with_feature_worktree_runtimes(
			branch_name: "codex/status-worktree",
			worktree_name: "status-worktree"
		) do |root_runtime, worktree_runtime, repo_root, worktree_path|
			root_runtime.ledger.upsert_delivery(
				repository: root_runtime.send( :repository_record ),
				branch_name: "codex/status-worktree",
				head: worktree_runtime.send( :current_head ),
				worktree_path: worktree_path,
				pr_number: 21,
				pr_url: "https://github.com/test/repo/pull/21",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)

			worktree_runtime.status!( json_output: true )
			data = JSON.parse( output_string( worktree_runtime ) )
			assert_equal root_runtime.send( :repository_record ).path, data.dig( "repository", "path" )
			assert_equal "repo", data.dig( "repository", "name" )
			entry = data.fetch( "branches" ).find { |row| row.fetch( "branch" ) == "codex/status-worktree" }
			refute_nil entry
			assert_equal worktree_path, entry.fetch( "worktree_path" )
			assert_equal "queued", entry.fetch( "delivery_state" )
		end
	end

	def test_status_human_output_identifies_next_delivery_and_merge_block_reason
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/conflicting" )
		create_feature_branch( repo_root, "feature/ready" )
		repository = runtime.send( :repository_record )
		runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/conflicting",
			head: `git -C #{repo_root} rev-parse feature/conflicting`.strip,
			worktree_path: repo_root,
			pr_number: 12,
			pr_url: "https://github.com/test/repo/pull/12",
			status: "gated",
			summary: "pull request has merge conflicts",
			cause: "merge"
		)
		runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: "feature/ready",
			head: `git -C #{repo_root} rev-parse feature/ready`.strip,
			worktree_path: repo_root,
			pr_number: 13,
			pr_url: "https://github.com/test/repo/pull/13",
			status: "queued",
			summary: "ready to integrate into main",
			cause: nil
		)

		runtime.status!
		output = output_string( runtime )
		assert_includes output, "Next delivery: feature/ready (PR #13)."
		assert_includes output, "feature/conflicting (PR #12) — gated"
		assert_includes output, "pull request has merge conflicts."
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

	def init_git_repo_with_remote( repo_root )
		init_git_repo( repo_root )
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

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
