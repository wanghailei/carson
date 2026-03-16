# Tests for shared merge-proof detection.
require_relative "test_helper"
require "fileutils"
require "open3"

class RuntimeMergeProofTest < Minitest::Test
	include CarsonTestSupport

	def test_merge_proof_for_main_branch_is_not_applicable
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		proof = runtime.send( :merge_proof_for_branch, branch: "main" )
		assert_equal false, proof.fetch( :applicable )
		assert_equal "not_applicable", proof.fetch( :basis )
		assert_equal false, proof.fetch( :proven )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_detects_ancestor_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/ancestor", content: "ancestor branch" )
		feature_head = git_capture( repo_root, "rev-parse", "feature/ancestor" )

		git!( repo_root, "checkout", "main" )
		git!( repo_root, "merge", "--ff-only", "feature/ancestor" )
		git!( repo_root, "push", "origin", "main" )

		proof = runtime.send( :merge_proof_for_branch, branch: "feature/ancestor" )
		assert_equal true, proof.fetch( :applicable )
		assert_equal true, proof.fetch( :proven )
		assert_equal "ancestor", proof.fetch( :basis )
		assert_equal feature_head, git_capture( repo_root, "rev-parse", "feature/ancestor" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_detects_no_unique_changes
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/no-changes", content: "temporary change" )
		FileUtils.rm_f( File.join( repo_root, "feature.txt" ) )
		git!( repo_root, "rm", "feature.txt" )
		git!( repo_root, "commit", "-m", "revert feature" )

		proof = runtime.send( :merge_proof_for_branch, branch: "feature/no-changes" )
		assert_equal true, proof.fetch( :proven )
		assert_equal "no_changes", proof.fetch( :basis )
		assert_equal 0, proof.fetch( :changed_files_count )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_detects_content_identical_after_rewritten_history
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/content-identical", content: "shared final content" )

		git!( repo_root, "checkout", "main" )
		File.write( File.join( repo_root, "feature.txt" ), "shared final content\n" )
		git!( repo_root, "add", "feature.txt" )
		git!( repo_root, "commit", "-m", "independent main change" )
		git!( repo_root, "push", "origin", "main" )

		proof = runtime.send( :merge_proof_for_branch, branch: "feature/content-identical" )
		assert_equal true, proof.fetch( :proven )
		assert_equal "content_identical", proof.fetch( :basis )
		assert_equal 1, proof.fetch( :changed_files_count )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_detects_content_differs
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/content-differs", content: "branch-only content" )

		proof = runtime.send( :merge_proof_for_branch, branch: "feature/content-differs" )
		assert_equal false, proof.fetch( :proven )
		assert_equal "content_differs", proof.fetch( :basis )
		assert_equal 1, proof.fetch( :changed_files_count )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_merge_proof_returns_unavailable_when_local_main_is_not_in_sync_with_remote
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch_commit( repo_root, "feature/unavailable", content: "branch proof" )

		advance_remote_main( repo_root )
		git!( repo_root, "fetch", "origin", "main" )

		proof = runtime.send( :merge_proof_for_branch, branch: "feature/unavailable" )
		assert_equal false, proof.fetch( :proven )
		assert_equal "unavailable", proof.fetch( :basis )
		assert_includes proof.fetch( :summary ), "origin/main"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		git!( repo_root, "init", "-b", "main" )
		git!( repo_root, "config", "user.email", "test@test.com" )
		git!( repo_root, "config", "user.name", "Test" )
		File.write( File.join( repo_root, "README.md" ), "# Test\n" )
		git!( repo_root, "add", "README.md" )
		git!( repo_root, "commit", "-m", "init" )
	end

	def init_git_repo_with_remote( repo_root )
		init_git_repo( repo_root )
		bare_remote = "#{repo_root}-remote.git"
		system( "git", "init", "--bare", bare_remote, out: File::NULL, err: File::NULL )
		git!( repo_root, "remote", "add", "origin", bare_remote )
		git!( repo_root, "push", "-u", "origin", "main" )
	end

	def create_feature_branch_commit( repo_root, branch_name, content: )
		git!( repo_root, "checkout", "-b", branch_name )
		File.write( File.join( repo_root, "feature.txt" ), "#{content}\n" )
		git!( repo_root, "add", "feature.txt" )
		git!( repo_root, "commit", "-m", branch_name )
	end

	def advance_remote_main( repo_root )
		remote_path = "#{repo_root}-remote.git"
		Dir.mktmpdir( "carson-merge-proof-remote", carson_tmp_root ) do |tmp_dir|
			clone_path = File.join( tmp_dir, "clone" )
			git!( nil, "clone", "--branch", "main", remote_path, clone_path )
			git!( clone_path, "config", "user.email", "test@test.com" )
			git!( clone_path, "config", "user.name", "Test" )
			File.write( File.join( clone_path, "remote.txt" ), "remote advance\n" )
			git!( clone_path, "add", "remote.txt" )
			git!( clone_path, "commit", "-m", "advance remote main" )
			git!( clone_path, "push", "origin", "HEAD:main" )
		end
	end

	def git!( repo_root, *args )
		command = [ "git" ]
		command += [ "-C", repo_root ] if repo_root
		command.concat( args )
		system( *command, out: File::NULL, err: File::NULL ) || raise( "git #{args.join( ' ' )} failed" )
	end

	def git_capture( repo_root, *args )
		command = [ "git", "-C", repo_root, *args ]
		stdout, status = Open3.capture2( *command )
		raise "git #{args.join( ' ' )} failed" unless status.success?

		stdout.strip
	end
end
