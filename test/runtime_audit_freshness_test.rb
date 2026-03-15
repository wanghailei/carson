# Tests for branch freshness audit check.
require_relative "test_helper"

class RuntimeAuditFreshnessTest < Minitest::Test
	include CarsonTestSupport

	def test_audit_freshness_passes_when_branch_is_up_to_date
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )
		create_feature_branch( repo_root, "feature/fresh" )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "ok", json[ "branch_freshness" ][ "status" ]
		assert_equal 0, json[ "branch_freshness" ][ "behind" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_freshness_blocks_when_branch_is_behind_main
		runtime, repo_root, remote_path = build_runtime_with_bare_remote
		create_feature_branch( repo_root, "feature/stale" )

		# Advance main on the remote so the feature branch falls behind.
		advance_remote_main( remote_path )
		# Fetch to update tracking refs (simulates the freshness check having connectivity).
		system( "git", "-C", repo_root, "fetch", "origin", out: File::NULL, err: File::NULL )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_equal "block", json[ "branch_freshness" ][ "status" ]
		assert json[ "branch_freshness" ][ "behind" ] > 0
		assert_includes json[ "branch_freshness" ][ "error" ], "behind"
		assert_includes json[ "branch_freshness" ][ "recovery" ], "git rebase"
		assert json[ "problems" ].any? { |problem| problem.include?( "Branch freshness" ) }
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_freshness_human_output_reports_staleness
		runtime, repo_root, remote_path = build_runtime_with_bare_remote
		create_feature_branch( repo_root, "feature/stale-human" )
		advance_remote_main( remote_path )
		system( "git", "-C", repo_root, "fetch", "origin", out: File::NULL, err: File::NULL )

		result = runtime.audit!( json_output: false )
		output = output_string( runtime )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output, "Branch freshness"
		assert_includes output, "behind"
		assert_includes output, "git rebase"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_freshness_skipped_on_main_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo_with_remote( repo_root )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "ok", json[ "branch_freshness" ][ "status" ]
		assert_equal "on main", json[ "branch_freshness" ][ "context" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_freshness_graceful_when_no_remote
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "checkout", "-b", "feature/no-remote", out: File::NULL, err: File::NULL )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		# Without a remote, fetch fails — freshness check should pass gracefully.
		assert_equal "ok", json[ "branch_freshness" ][ "status" ]
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
		system( "git", "-C", repo_root, "commit", "-m", "feature work", out: File::NULL, err: File::NULL )
	end

	def build_runtime_with_bare_remote
		repo_root = Dir.mktmpdir( "carson-freshness-test", carson_tmp_root )
		init_git_repo( repo_root )
		bare_remote = "#{repo_root}-remote.git"
		system( "git", "init", "--bare", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", bare_remote, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

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
		[ runtime, repo_root, bare_remote ]
	end

	def advance_remote_main( remote_path )
		# Clone the bare remote, commit, push — then the remote main is ahead.
		tmp_clone = Dir.mktmpdir( "carson-freshness-advance", carson_tmp_root )
		system( "git", "clone", remote_path, tmp_clone, out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( tmp_clone, "remote-change.txt" ), "new work on main" )
		system( "git", "-C", tmp_clone, "add", "remote-change.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
		system( "git", "-C", tmp_clone, "push", "origin", "main", out: File::NULL, err: File::NULL )
		FileUtils.remove_entry( tmp_clone )
	end

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
