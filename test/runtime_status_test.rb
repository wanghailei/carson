require_relative "test_helper"

class RuntimeStatusTest < Minitest::Test
	include CarsonTestSupport

	def test_status_returns_exit_ok
		runtime, repo_root = build_runtime
		init_git_repo( repo_root )
		result = runtime.status!
		assert_equal Carson::Runtime::EXIT_OK, result
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_prints_version
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!
		assert_includes output_string( runtime ), Carson::VERSION
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_prints_branch_name
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!
		assert_includes output_string( runtime ), "Branch: main"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_shows_dirty_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		File.write( File.join( repo_root, "uncommitted.txt" ), "dirty" )
		runtime.status!
		assert_includes output_string( runtime ), "(dirty)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_shows_clean_state
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!
		refute_includes output_string( runtime ), "(dirty)"
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_output_is_valid_json
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert_equal Carson::VERSION, data[ "version" ]
		assert_equal "main", data[ "branch" ][ "name" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_includes_branch_dirty_flag
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		File.write( File.join( repo_root, "uncommitted.txt" ), "dirty" )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert_equal true, data[ "branch" ][ "dirty" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_json_includes_worktrees_array
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert_kind_of Array, data[ "worktrees" ]
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_status_lists_worktrees
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		# Create a worktree.
		wt_path = File.join( repo_root, ".claude", "worktrees", "test-wt" )
		system( "git", "-C", repo_root, "worktree", "add", wt_path, "-b", "test-branch", out: File::NULL, err: File::NULL )

		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		worktrees = data[ "worktrees" ]
		assert_equal 1, worktrees.size
		assert_equal "test-wt", worktrees.first[ "name" ]
		assert_equal "test-branch", worktrees.first[ "branch" ]

		# Cleanup worktree before destroying tmpdir.
		system( "git", "-C", repo_root, "worktree", "remove", wt_path, out: File::NULL, err: File::NULL )
		destroy_runtime_repo( repo_root: repo_root )
	end

	# Path normalisation: status must filter the main worktree even when
	# repo_root has a different canonical form than git reports (e.g. symlinks).
	def test_status_filters_main_worktree_with_symlinked_path
		Dir.mktmpdir( "carson-status-symlink-test", carson_tmp_root ) do |tmp_dir|
			real_repo = File.join( tmp_dir, "real-repo" )
			symlink_repo = File.join( tmp_dir, "link-repo" )

			FileUtils.mkdir_p( real_repo )
			File.symlink( real_repo, symlink_repo )

			# Initialise git in the real directory.
			system( "git", "-C", real_repo, "init", "-b", "main", out: File::NULL, err: File::NULL )
			system( "git", "-C", real_repo, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			system( "git", "-C", real_repo, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			File.write( File.join( real_repo, "README.md" ), "# Test" )
			system( "git", "-C", real_repo, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", real_repo, "commit", "-m", "init", out: File::NULL, err: File::NULL )

			# Build runtime pointing at the symlink path.
			out = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: symlink_repo,
				tool_root: symlink_repo,
				out: out,
				err: StringIO.new,
				verbose: false
			)

			runtime.status!( json_output: true )
			data = JSON.parse( out.string )
			# Main worktree should be filtered out — worktrees array should be empty.
			assert_equal 0, data[ "worktrees" ].size, "main worktree should be filtered even with symlink"
		end
	end

	def test_status_json_includes_governance
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		runtime.status!( json_output: true )
		data = JSON.parse( output_string( runtime ) )
		assert data.key?( "governance" ), "JSON output should include governance key"
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	# Initialises a bare git repo with one commit so branch operations work.
	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		readme = File.join( repo_root, "README.md" )
		File.write( readme, "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end

	# Extracts captured stdout text from the runtime.
	def output_string( runtime )
		runtime.instance_variable_get( :@out ).string
	end
end
