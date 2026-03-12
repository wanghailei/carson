# Tests for audit! --json output.
# Runs against a minimal git repo without gh, so PR and baseline sections are skipped.
require_relative "test_helper"

class RuntimeAuditTest < Minitest::Test
	include CarsonTestSupport

	def test_audit_json_includes_command_and_status
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "audit", json[ "command" ]
		assert_includes %w[ok attention block], json[ "status" ]
		assert_equal result, json[ "exit_code" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "main", json[ "branch" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_hooks_section
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "hooks" ), "JSON must include hooks section"
		assert_includes %w[ok mismatch], json[ "hooks" ][ "status" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_main_sync
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "main_sync" ), "JSON must include main_sync section"
		sync = json[ "main_sync" ]
		assert sync.key?( "ahead" )
		assert sync.key?( "behind" )
		assert sync.key?( "status" )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_working_tree_section
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "working_tree" ), "JSON must include working_tree section"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_checks_section
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "checks" ), "JSON must include checks section"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_baseline_section
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "baseline" ), "JSON must include baseline section"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_includes_problems_array
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert json.key?( "problems" ), "JSON must include problems array"
		assert_kind_of Array, json[ "problems" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_human_output_unchanged
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		runtime.audit!( json_output: false )
		output = output_string( runtime )
		# Human output should contain "Audit:" line, not JSON.
		assert_includes output, "Audit:"
		refute output.strip.start_with?( "{" ), "Human output should not be JSON"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_dirty_main_worktree_blocks_with_governance_message
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		File.write( File.join( repo_root, "uncommitted.txt" ), "dirty" )

		result = runtime.audit!( json_output: false )
		output = output_string( runtime )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_includes output, "Working tree: main working tree has uncommitted changes"
		assert_includes output, "carson worktree create <name>"
		assert_includes output, "Audit: block"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_dirty_main_worktree_reports_specific_block
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		File.write( File.join( repo_root, "uncommitted.txt" ), "dirty" )

		result = runtime.audit!( json_output: true )
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal Carson::Runtime::EXIT_BLOCK, result
		assert_equal "block", json[ "working_tree" ][ "status" ]
		assert_equal "main_worktree", json[ "working_tree" ][ "context" ]
		assert_equal "main working tree has uncommitted changes", json[ "working_tree" ][ "error" ]
		assert_includes json[ "working_tree" ][ "recovery" ], "carson worktree create <name>"
		assert_includes json[ "problems" ], "Working tree: main working tree has uncommitted changes — create a worktree with carson worktree create <name>."
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_audit_json_no_commits_returns_skipped
		runtime, repo_root = build_runtime( verbose: false )
		# Initialise git but do not commit — head_exists? returns false.
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )

		result = runtime.audit!( json_output: true )
		assert_equal Carson::Runtime::EXIT_OK, result
		json = JSON.parse( output_string( runtime ).strip )
		assert_equal "skipped", json[ "status" ]
		assert_equal "no commits yet", json[ "reason" ]
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

	def output_string( runtime )
		runtime.instance_variable_get( :@output ).string
	end
end
