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

	def test_status_human_output_reports_repository_authority_and_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!
		output = output_string( runtime )
		assert_includes output, Carson::VERSION
		assert_includes output, "remote"
		assert_includes output, "On main"
		assert_includes output, "No active deliveries."
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_reports_repository_and_branches
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert_equal Carson::VERSION, data.fetch( "version" )
		assert_equal "remote", data.dig( "repository", "authority" )
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
			authority: "remote",
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
				authority: "remote",
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
