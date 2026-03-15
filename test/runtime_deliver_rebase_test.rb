# Tests for pre-push sync-and-rebase in delivery.
require_relative "test_helper"

class RuntimeDeliverRebaseTest < Minitest::Test
	include CarsonTestSupport

	def test_deliver_rebases_stale_branch_before_push
		runtime, repo_root, mock_path, tmp_dir, remote_path = build_runtime_with_bare_and_mock_gh
		create_feature_branch( repo_root, "feature/stale-deliver" )
		advance_remote_main( remote_path )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result

		data = JSON.parse( output_string( runtime ) )
		assert_equal true, data[ "rebased" ]
		assert data[ "rebased_behind" ] > 0

		# Verify the feature commit is now on top of the remote main advance.
		log = git_capture( repo_root, "log", "--oneline", "--all" )
		assert_includes log, "feature work"
		assert_includes log, "advance main"

		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_skips_rebase_when_branch_is_fresh
		runtime, repo_root, mock_path, tmp_dir, _remote_path = build_runtime_with_bare_and_mock_gh
		create_feature_branch( repo_root, "feature/fresh-deliver" )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result

		data = JSON.parse( output_string( runtime ) )
		assert_nil data[ "rebased" ]
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_reports_rebase_in_human_output
		runtime, repo_root, mock_path, tmp_dir, remote_path = build_runtime_with_bare_and_mock_gh
		create_feature_branch( repo_root, "feature/rebase-human" )
		advance_remote_main( remote_path )
		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: false ) }
		assert_equal Carson::Runtime::EXIT_OK, result
		output = output_string( runtime )
		assert_includes output, "Rebased onto main"
		assert_includes output, "behind"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_deliver_reports_rebase_conflict
		runtime, repo_root, mock_path, tmp_dir, remote_path = build_runtime_with_bare_and_mock_gh
		create_feature_branch( repo_root, "feature/conflict" )

		# Create a conflicting change on remote main (same file, same line).
		advance_remote_main_with_conflict( remote_path )

		# Create a conflicting change on the feature branch.
		File.write( File.join( repo_root, "README.md" ), "# Feature conflict\n" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "conflict on feature", out: File::NULL, err: File::NULL )

		stub_ready_assessment( runtime )

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: false ) }
		assert_equal Carson::Runtime::EXIT_ERROR, result
		output = output_string( runtime )
		assert_includes output, "git rebase"
		assert_includes output, "resolve conflicts"

		# Verify rebase was aborted — no lingering rebase state.
		refute File.exist?( File.join( repo_root, ".git", "rebase-merge" ) ),
			"rebase should have been aborted"
		refute File.exist?( File.join( repo_root, ".git", "rebase-apply" ) ),
			"rebase should have been aborted"
		FileUtils.remove_entry( tmp_dir )
	end

	def test_sync_and_rebase_continues_when_fetch_fails
		runtime, repo_root, mock_path, tmp_dir, _remote_path = build_runtime_with_bare_and_mock_gh
		create_feature_branch( repo_root, "feature/no-fetch" )
		stub_ready_assessment( runtime )

		# Stub git_run to make fetch fail while allowing other git commands through.
		original_git_run = runtime.method( :git_run )
		runtime.define_singleton_method( :git_run ) do |*args|
			if args.first == "fetch"
				[ "", "fatal: could not fetch\n", false, 1 ]
			else
				original_git_run.call( *args )
			end
		end

		result = with_env( "PATH" => mock_path ) { runtime.deliver!( json_output: true ) }
		assert_equal Carson::Runtime::EXIT_OK, result

		data = JSON.parse( output_string( runtime ) )
		assert_nil data[ "rebased" ]
		FileUtils.remove_entry( tmp_dir )
	end

private

	def stub_ready_assessment( runtime )
		runtime.define_singleton_method( :check_pr_ci ) { |number:| :pass }
		runtime.define_singleton_method( :check_pr_review ) { |number:, branch:, pr_url: nil| { status: :pass, review: :approved, detail: "" } }
	end

	def build_runtime_with_bare_and_mock_gh
		tmp_dir = Dir.mktmpdir( "carson-deliver-rebase-test", carson_tmp_root )
		repo_root = File.join( tmp_dir, "repo" )
		FileUtils.mkdir_p( repo_root )

		# Create repo with a bare remote.
		bare_remote = File.join( tmp_dir, "remote.git" )
		system( "git", "init", "--bare", "-b", "main", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test\n" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		# Create mock gh.
		mock_bin = File.join( tmp_dir, "mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		File.write( File.join( mock_bin, "gh" ), mock_gh_script )
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
		[ runtime, repo_root, "#{mock_bin}:#{ENV.fetch( 'PATH' )}", tmp_dir, bare_remote ]
	end

	def mock_gh_script
		<<~BASH
			#!/usr/bin/env bash
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				if [[ "$3" =~ ^[0-9]+$ ]]; then
					number="$3"
					cat <<JSON
			{"number":${number},"url":"https://github.com/test/repo/pull/${number}","state":"OPEN","isDraft":false}
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

	def create_feature_branch( repo_root, branch_name )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "feature.txt" ), branch_name )
		system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "feature work", out: File::NULL, err: File::NULL )
	end

	def advance_remote_main( remote_path )
		tmp_clone = Dir.mktmpdir( "carson-rebase-advance", carson_tmp_root )
		system( "git", "clone", remote_path, tmp_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( tmp_clone, "remote-change.txt" ), "new work on main" )
		system( "git", "-C", tmp_clone, "add", "remote-change.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )
		FileUtils.remove_entry( tmp_clone )
	end

	def advance_remote_main_with_conflict( remote_path )
		tmp_clone = Dir.mktmpdir( "carson-rebase-conflict", carson_tmp_root )
		system( "git", "clone", remote_path, tmp_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "checkout", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( tmp_clone, "README.md" ), "# Remote conflict\n" )
		system( "git", "-C", tmp_clone, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "commit", "-m", "conflict on main", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )
		FileUtils.remove_entry( tmp_clone )
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

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end

	def git_capture( repo_root, *args )
		stdout, _stderr, status = Open3.capture3( "git", "-C", repo_root, *args )
		raise "git #{args.join( ' ' )} failed" unless status.success?
		stdout.strip
	end
end
