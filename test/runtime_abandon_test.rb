# Tests for abandoning delivery work and cleaning up safely.
require_relative "test_helper"

class RuntimeAbandonTest < Minitest::Test
	include CarsonTestSupport

	def with_abandon_repo( mock_gh_script: )
		Dir.mktmpdir( "carson-abandon-test", carson_tmp_root ) do |tmp_dir|
			bare_root = File.join( tmp_dir, "bare" )
			repo_root = File.join( tmp_dir, "repo" )
			system( "git", "init", "--bare", "-b", "main", bare_root, out: File::NULL, err: File::NULL )
			system( "git", "clone", bare_root, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "README.md" ), "init\n" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), mock_gh_script )
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			output = StringIO.new
			error = StringIO.new
			config_path = write_test_config( repo_root: repo_root )
			runtime = nil
			with_env( "CARSON_CONFIG_FILE" => config_path, "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					output: output,
					error: error,
					verbose: false
				)
				yield runtime, repo_root, bare_root, output
			end
		end
	end

	def create_worktree( repo_root:, worktree_name:, branch_name: )
		worktree_path = File.join( repo_root, ".claude", "worktrees", worktree_name )
		system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, out: File::NULL, err: File::NULL )
		File.write( File.join( worktree_path, "#{worktree_name}.txt" ), "work\n" )
		system( "git", "-C", worktree_path, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "commit", "-m", "work on #{worktree_name}", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_path, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
		{ path: worktree_path, branch: branch_name }
	end

	def test_abandon_closes_pull_request_and_removes_worktree
		branch_name = "feature/abandon-pr"

		with_abandon_repo( mock_gh_script: mock_gh_for_open_pr( number: 12, branch_name: branch_name ) ) do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "abandon-pr", branch_name: branch_name )
			repository = runtime.send( :repository_record )
			head = `git -C #{worktree.fetch( :path )} rev-parse HEAD`.strip
			runtime.ledger.upsert_delivery(
				repository: repository,
				branch_name: branch_name,
				head: head,
				worktree_path: worktree.fetch( :path ),
				pr_number: 12,
				pr_url: "https://github.com/test/repo/pull/12",
				status: "queued",
				summary: "ready to integrate into main",
				cause: nil
			)

			result = runtime.abandon!( target: "12", json_output: true )
			assert_equal Carson::Runtime::EXIT_OK, result

			data = JSON.parse( output.string )
			assert_equal true, data.fetch( "pull_request_closed" )
			assert_equal true, data.fetch( "worktree_removed" )
			assert_equal true, data.fetch( "branch_deleted" )
			assert_equal true, data.fetch( "remote_deleted" )
			refute Dir.exist?( worktree.fetch( :path ) ), "worktree should be removed"
			refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "local branch should be deleted"
			refute remote_branch_exists?( repo_root: repo_root, branch_name: branch_name ), "remote branch should be deleted"

			delivery = delivery_row_for( runtime: runtime, branch_name: branch_name )
			assert_equal "failed", delivery.fetch( "status" )
			assert_equal "abandoned by carson abandon", delivery.fetch( "summary" )
		end
	end

	def test_abandon_blocks_current_branch_without_worktree
		branch_name = "feature/current-only"

		with_abandon_repo( mock_gh_script: mock_gh_without_pull_requests ) do |runtime, repo_root, _bare_root, output|
			system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "#{branch_name.tr( '/', '-' )}.txt" ), "work\n" )
			system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "work on current branch", out: File::NULL, err: File::NULL )

			result = runtime.abandon!( target: branch_name, json_output: true )
			assert_equal Carson::Runtime::EXIT_BLOCK, result

			data = JSON.parse( output.string )
			assert_includes data.fetch( "error" ), "current branch is #{branch_name}"
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "current branch must be preserved"
		end
	end

private

	def mock_gh_for_open_pr( number:, branch_name: )
		<<~BASH
			#!/usr/bin/env bash
			if [[ "$1" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi

			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				cat <<'JSON'
		{"number":#{number},"url":"https://github.com/test/repo/pull/#{number}","state":"OPEN","headRefName":"#{branch_name}"}
		JSON
				exit 0
			fi

			if [[ "$1" == "pr" && "$2" == "close" ]]; then
				exit 0
			fi

			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def mock_gh_without_pull_requests
		<<~BASH
			#!/usr/bin/env bash
			if [[ "$1" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi

			if [[ "$1" == "api" ]]; then
				echo "[]"
				exit 0
			fi

			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def branch_exists?( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "rev-parse", "--verify", branch_name, out: File::NULL, err: File::NULL )
	end

	def remote_branch_exists?( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "ls-remote", "--exit-code", "--heads", "origin", branch_name, out: File::NULL, err: File::NULL )
	end

	def delivery_row_for( runtime:, branch_name: )
		runtime.ledger.send( :with_database ) do |database|
			database.get_first_row(
				"SELECT * FROM deliveries WHERE repo_path = ? AND branch_name = ? ORDER BY id DESC LIMIT 1",
				[ runtime.main_worktree_root, branch_name ]
			)
		end
	end
end
