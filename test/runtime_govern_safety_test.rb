# Tests for govern safety improvements: fetch-only post-merge, remote-ref merge proof,
# busy-worktree guard in revise_delivery!, and fetch-only worktree create.
require_relative "test_helper"
require "shellwords"

class RuntimeGovernSafetyTest < Minitest::Test
	include CarsonTestSupport

	# --- Change 1: fetch-only post-merge (no housekeep) ---

	def test_integrate_does_not_call_housekeep_after_merge
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/no-housekeep" )
		delivery = create_delivery( runtime: runtime, repo_root: repo_root, branch_name: "feature/no-housekeep", status: "queued", summary: "ready" )
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :pull_request_state ) do |number:|
			{ "state" => "OPEN", "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" }
		end
		runtime.define_singleton_method( :merge_pr! ) do |number:, result:|
			result[ :merge_method ] = "squash"
			Carson::Runtime::EXIT_OK
		end
		runtime.define_singleton_method( :housekeep_one_entry ) do |repo_path:, silent:|
			raise "housekeep must not run from govern post-merge"
		end

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "integrated", row.fetch( "status" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- Change 2: merge_proof_for_remote_ref ---

	def test_merge_proof_for_remote_ref_proves_ancestor_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/remote-ancestor", content: "ancestor proof" )

		git!( repo_root, "checkout", "main" )
		git!( repo_root, "merge", "--ff-only", "feature/remote-ancestor" )
		git!( repo_root, "push", "origin", "main" )
		git!( repo_root, "fetch", "origin" )

		proof = runtime.merge_proof_for_remote_ref( branch: "feature/remote-ancestor" )
		assert_equal true, proof.fetch( :applicable )
		assert_equal true, proof.fetch( :proven )
		assert_equal "main", proof.fetch( :main_branch ), "should display local branch name, not origin/main"
		refute_includes proof.fetch( :summary ), "origin/main", "summary should use local branch name"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_for_remote_ref_works_when_local_main_is_behind
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/behind-proof", content: "proof content" )

		# Advance remote main to include the feature content.
		git!( repo_root, "checkout", "main" )
		git!( repo_root, "merge", "--ff-only", "feature/behind-proof" )
		git!( repo_root, "push", "origin", "main" )

		# Reset local main behind remote — simulates govern fetch-only (no pull).
		git!( repo_root, "reset", "--hard", "HEAD~1" )
		git!( repo_root, "fetch", "origin" )

		# Old merge_proof_for_branch would fail (local main not in sync).
		old_proof = runtime.merge_proof_for_branch( branch: "feature/behind-proof" )
		assert_equal false, old_proof.fetch( :proven ), "old method should fail when local main is behind"

		# New merge_proof_for_remote_ref should succeed (uses origin/main).
		new_proof = runtime.merge_proof_for_remote_ref( branch: "feature/behind-proof" )
		assert_equal true, new_proof.fetch( :proven ), "remote ref proof should succeed even when local main is behind"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_for_remote_ref_not_applicable_for_main
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		proof = runtime.merge_proof_for_remote_ref( branch: "main" )
		assert_equal false, proof.fetch( :applicable )
		assert_equal "not_applicable", proof.fetch( :basis )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# --- Change 4: busy-worktree guard in revise_delivery! ---

	def test_govern_defers_revision_when_worktree_dirty
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		worktree_path = File.join( repo_root, ".claude", "worktrees", "dirty-wt" )
		runtime.worktree_create!( name: "dirty-wt" )

		# Make the worktree dirty.
		File.write( File.join( worktree_path, "dirty.txt" ), "uncommitted" )

		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "dirty-wt", status: "gated",
			summary: "CI failing", cause: "ci",
			worktree_path: worktree_path
		)
		stub_reconciliation( runtime, delivery: delivery )
		runtime.define_singleton_method( :select_agent_provider ) { "codex" }

		result = runtime.govern!( dry_run: false )
		assert_equal Carson::Runtime::EXIT_OK, result
		row = delivery_data( runtime: runtime, key: delivery.key )
		assert_equal "gated", row.fetch( "status" )
		assert_equal "busy", row.fetch( "cause" )
		assert_includes row.fetch( "summary" ), "uncommitted changes"

		cleanup_worktree( repo_root, worktree_path, force: true )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_govern_holds_busy_delivery_instead_of_revising
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		create_feature_branch( repo_root, "feature/busy" )
		delivery = create_delivery(
			runtime: runtime, repo_root: repo_root,
			branch_name: "feature/busy", status: "gated",
			summary: "worktree held by another process — deferring revision", cause: "busy"
		)
		stub_reconciliation( runtime, delivery: delivery )

		result = runtime.govern!( dry_run: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "would hold at gate (dry run)"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def stub_reconciliation( runtime, delivery: )
		expected_delivery = delivery
		runtime.define_singleton_method( :reconcile_delivery! ) { |delivery:| expected_delivery || delivery }
	end

	def create_delivery( runtime:, repo_root:, branch_name:, status:, summary:, cause: nil, revision_count: 0, worktree_path: nil )
		repository = runtime.send( :repository_record )
		delivery = runtime.ledger.upsert_delivery(
			repository: repository,
			branch_name: branch_name,
			head: branch_head( repo_root: repo_root, branch_name: branch_name ),
			worktree_path: worktree_path || repo_root,
			pr_number: 42,
			pr_url: "https://github.com/test/repo/pull/42",
			status: status,
			summary: summary,
			cause: cause
		)
		revision_count.times do |i|
			runtime.ledger.record_revision(
				delivery: delivery,
				cause: cause || "ci",
				provider: "codex",
				status: "failed",
				summary: "simulated revision #{i + 1}"
			)
		end
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

	def init_git_repo_with_remote( repo_root )
		init_git_repo( repo_root )
	end

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), branch_name )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "feature", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
	end

	def create_feature_branch_commit( repo_root, branch_name, content: )
		git!( repo_root, "checkout", "-b", branch_name )
		File.write( File.join( repo_root, "feature.txt" ), "#{content}\n" )
		git!( repo_root, "add", "feature.txt" )
		git!( repo_root, "commit", "-m", branch_name )
	end

	def branch_head( repo_root:, branch_name: )
		`git -C #{Shellwords.escape( repo_root )} rev-parse #{Shellwords.escape( branch_name )}`.strip
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def cleanup_worktree( repo_root, wt_path, force: false )
		args = [ "git", "-C", repo_root, "worktree", "remove" ]
		args << "--force" if force
		args << wt_path
		system( *args, out: File::NULL, err: File::NULL )
	end

	def git!( repo_root, *args )
		command = [ "git" ]
		command += [ "-C", repo_root ] if repo_root
		command.concat( args )
		system( *command, out: File::NULL, err: File::NULL ) || raise( "git #{args.join( ' ' )} failed" )
	end
end
