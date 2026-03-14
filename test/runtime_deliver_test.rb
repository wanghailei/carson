# Tests for the async branch-delivery contract.
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

	def test_deliver_registers_queued_delivery_when_branch_is_ready
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/queued" )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "PR: #99"
		assert_includes output, "Delivery: queued"

		delivery = runtime.ledger.active_delivery( repo_path: repo_root, branch_name: "feature/queued" )
		refute_nil delivery
		assert_equal "queued", delivery.status
		assert_equal "ready to integrate into main", delivery.summary
		assert_equal 99, delivery.pull_request_number
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_registers_gated_delivery_when_ci_is_pending
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/gated" )
		stub_assessment( runtime, ci: :pending, review: { status: :pass, review: :approved, detail: "" } )

		result = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, result
		delivery = runtime.ledger.active_delivery( repo_path: repo_root, branch_name: "feature/gated" )
		assert_equal "gated", delivery.status
		assert_equal "ci", delivery.cause
		assert_includes delivery.summary, "waiting for CI"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_json_reports_delivery_payload
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/json" )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		data = JSON.parse( output_string( runtime ) )
		assert_equal 42, data.fetch( "pr_number" )
		assert_equal "queued", data.dig( "delivery", "status" )
		assert_equal "carson status", data.fetch( "next_step" )
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_is_idempotent_for_same_branch_head
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/idempotent" )
		stub_ready_assessment( runtime )

		first = with_env( "PATH" => mock_path ) { runtime.deliver! }
		second = with_env( "PATH" => mock_path ) { runtime.deliver! }
		assert_equal Carson::Runtime::EXIT_OK, first
		assert_equal Carson::Runtime::EXIT_OK, second

		deliveries = runtime.ledger.active_deliveries( repo_path: repo_root )
		assert_equal 1, deliveries.size
		assert_equal "feature/idempotent", deliveries.first.branch
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_supersedes_older_delivery_on_new_head
		runtime, repo_root, mock_path, tmp_dir = build_runtime_with_mock_gh( existing_pr: true )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/supersede" )
		stub_ready_assessment( runtime )

		assert_equal Carson::Runtime::EXIT_OK, with_env( "PATH" => mock_path ) { runtime.deliver! }
		first_delivery = runtime.ledger.active_delivery( repo_path: repo_root, branch_name: "feature/supersede" )

		File.write( File.join( repo_root, "feature.txt" ), "updated" )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "update head", out: File::NULL, err: File::NULL )

		assert_equal Carson::Runtime::EXIT_OK, with_env( "PATH" => mock_path ) { runtime.deliver! }

		active = runtime.ledger.active_delivery( repo_path: repo_root, branch_name: "feature/supersede" )
		refute_equal first_delivery.head, active.head
		all = runtime.ledger.send( :with_database ) do |database|
			database.execute( "SELECT status FROM deliveries WHERE repo_path = ? AND branch_name = ? ORDER BY id ASC", [ repo_root, "feature/supersede" ] )
		end
		assert_equal [ "superseded", "queued" ], all.map { |row| row.fetch( "status" ) }
		FileUtils.remove_entry( tmp_dir )
	end

private

	def stub_ready_assessment( runtime )
		stub_assessment( runtime, ci: :pass, review: { status: :pass, review: :approved, detail: "" } )
	end

	def stub_assessment( runtime, ci:, review: )
		runtime.define_singleton_method( :check_pr_ci ) { |number:| ci }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| review }
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
		config_path = write_test_config( repo_root: repo_root )
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

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
