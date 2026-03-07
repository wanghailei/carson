require_relative "test_helper"

class RuntimeWorktreeTest < Minitest::Test
	include CarsonTestSupport

	def with_worktree_repo
		Dir.mktmpdir( "carson-worktree-test", carson_tmp_root ) do |tmp_dir|
			bare_root = File.join( tmp_dir, "bare" )
			repo_root = File.join( tmp_dir, "repo" )
			system( "git", "init", "--bare", "-b", "main", bare_root, out: File::NULL, err: File::NULL )
			system( "git", "clone", bare_root, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "README.md" ), "init\n" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: true
				)
				yield runtime, repo_root, bare_root, out
			end
		end
	end

	def create_worktree( repo_root:, worktree_name:, push: true )
		worktree_dir = File.join( repo_root, ".claude", "worktrees", worktree_name )
		branch_name = "worktree-#{worktree_name}"
		system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_dir, out: File::NULL, err: File::NULL )
		File.write( File.join( worktree_dir, "#{worktree_name}.txt" ), "work\n" )
		system( "git", "-C", worktree_dir, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_dir, "commit", "-m", "work on #{worktree_name}", out: File::NULL, err: File::NULL )
		if push
			system( "git", "-C", worktree_dir, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
		end
		{ path: worktree_dir, branch: branch_name }
	end

	def test_worktree_remove_by_path
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "test-remove" )

			assert Dir.exist?( wt.fetch( :path ) ), "worktree directory should exist"
			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( wt.fetch( :path ) ), "worktree directory should be removed"
			assert_includes out.string, "worktree_removed:"
			assert_includes out.string, "branch_deleted: #{wt.fetch( :branch )}"
		end
	end

	def test_worktree_remove_by_name
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "by-name" )

			assert Dir.exist?( wt.fetch( :path ) ), "worktree directory should exist"
			# Pass just the name, not full path.
			status = runtime.worktree_remove!( worktree_path: "by-name" )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( wt.fetch( :path ) ), "worktree directory should be removed"
		end
	end

	def test_worktree_remove_branch_deleted
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "branch-del" )
			branch = wt.fetch( :branch )

			# Verify branch exists before removal.
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should exist before worktree remove"

			runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )

			refute system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should be deleted after worktree remove"
		end
	end

	def test_worktree_remove_protected_branch_preserved
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			# Create a worktree on main — should not delete the main branch.
			worktree_dir = File.join( repo_root, ".claude", "worktrees", "on-main" )
			system( "git", "-C", repo_root, "worktree", "add", "--detach", worktree_dir, out: File::NULL, err: File::NULL )

			status = runtime.worktree_remove!( worktree_path: worktree_dir )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree_dir ), "worktree directory should be removed"
			# Main branch should still exist.
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", "main", out: File::NULL, err: File::NULL ),
				"main branch should be preserved"
		end
	end

	def test_worktree_remove_unregistered_path_fails
		with_worktree_repo do |runtime, _repo_root, _bare_root, out|
			status = runtime.worktree_remove!( worktree_path: "/nonexistent/path" )
			assert_equal Carson::Runtime::EXIT_ERROR, status
			assert_includes out.string, "not a registered worktree"
		end
	end

	def test_worktree_remove_dirty_refused_without_force
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "dirty-refuse" )

			# Add uncommitted changes to the worktree.
			File.write( File.join( wt.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_ERROR, status
			assert Dir.exist?( wt.fetch( :path ) ), "dirty worktree must be preserved without --force"
			assert_includes out.string, "uncommitted changes"
			assert_includes out.string, "--force"
		end
	end

	def test_worktree_remove_dirty_accepted_with_force
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "dirty-force" )

			# Add uncommitted changes to the worktree.
			File.write( File.join( wt.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ), force: true )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( wt.fetch( :path ) ), "dirty worktree should be removed with --force"
		end
	end

	def test_worktree_remove_blocks_unpushed_commits
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "unpushed-rm", push: false )

			# Branch has a commit that was never pushed — remove should block.
			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_BLOCK, status
			assert Dir.exist?( wt.fetch( :path ) ), "worktree must be preserved when unpushed"
			assert_includes out.string, "not been pushed"
			assert_includes out.string, "--force"
		end
	end

	def test_worktree_remove_allows_pushed_branch
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			# Helper pushes by default — branch is safe to remove.
			wt = create_worktree( repo_root: repo_root, worktree_name: "pushed-rm" )

			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( wt.fetch( :path ) ), "pushed worktree should be removed"
		end
	end

	def test_worktree_remove_force_overrides_unpushed_guard
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "force-unpushed", push: false )

			# Branch has unpushed commits but --force should override.
			status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ), force: true )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( wt.fetch( :path ) ), "force should remove even with unpushed commits"
		end
	end

	# --- sweep_stale_worktrees! ---

	def test_sweep_stale_worktrees_removes_absorbed
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "stale-sweep" )
			branch = wt.fetch( :branch )

			# Merge the worktree branch into main so its content is absorbed.
			system( "git", "-C", repo_root, "merge", branch, "--no-edit", out: File::NULL, err: File::NULL )

			assert Dir.exist?( wt.fetch( :path ) ), "worktree directory should exist before sweep"
			runtime.sweep_stale_worktrees!
			refute Dir.exist?( wt.fetch( :path ) ), "absorbed worktree should be swept"

			# Branch should be deleted.
			refute system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should be deleted after sweep"

			assert_includes out.string, "swept stale worktree: stale-sweep"
			assert_includes out.string, "deleted branch: #{branch}"
		end
	end

	def test_sweep_stale_worktrees_skips_non_absorbed
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "active-work" )

			# Do NOT merge — content is still unique to the branch.
			assert Dir.exist?( wt.fetch( :path ) ), "worktree directory should exist"
			runtime.sweep_stale_worktrees!
			assert Dir.exist?( wt.fetch( :path ) ), "non-absorbed worktree must be preserved"
		end
	end

	def test_sweep_stale_worktrees_scans_codex_directory
		with_worktree_repo do |runtime, repo_root, _bare_root, out|
			# Create a worktree under .codex/worktrees/ manually.
			codex_dir = File.join( repo_root, ".codex", "worktrees" )
			worktree_path = File.join( codex_dir, "codex-task" )
			branch_name = "codex-task"
			FileUtils.mkdir_p( codex_dir )
			system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_path, out: File::NULL, err: File::NULL )
			File.write( File.join( worktree_path, "codex-file.txt" ), "codex work\n" )
			system( "git", "-C", worktree_path, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", worktree_path, "commit", "-m", "codex work", out: File::NULL, err: File::NULL )

			# Merge into main so content is absorbed.
			system( "git", "-C", repo_root, "merge", branch_name, "--no-edit", out: File::NULL, err: File::NULL )

			assert Dir.exist?( worktree_path ), "codex worktree should exist before sweep"
			runtime.sweep_stale_worktrees!
			refute Dir.exist?( worktree_path ), "absorbed codex worktree should be swept"

			assert_includes out.string, "swept stale worktree: codex-task"
		end
	end

	def test_sweep_stale_worktrees_skips_worktrees_outside_agent_dirs
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			# Create a worktree outside .claude/ and .codex/.
			external_path = File.join( repo_root, "custom-worktrees", "external" )
			branch_name = "external-branch"
			FileUtils.mkdir_p( File.dirname( external_path ) )
			system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, external_path, out: File::NULL, err: File::NULL )

			# Even if content is on main (no changes), sweep should not touch it.
			assert Dir.exist?( external_path ), "external worktree should exist"
			runtime.sweep_stale_worktrees!
			assert Dir.exist?( external_path ), "worktree outside agent dirs must be preserved"
		end
	end

	def test_sweep_stale_worktrees_skips_dirty_worktree
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			wt = create_worktree( repo_root: repo_root, worktree_name: "dirty-sweep" )
			branch = wt.fetch( :branch )

			# Merge into main so content is absorbed.
			system( "git", "-C", repo_root, "merge", branch, "--no-edit", out: File::NULL, err: File::NULL )

			# Add uncommitted changes — git worktree remove will refuse.
			File.write( File.join( wt.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			runtime.sweep_stale_worktrees!
			assert Dir.exist?( wt.fetch( :path ) ), "dirty worktree must be preserved even if absorbed"
		end
	end

	def test_worktree_remove_concise_output
		Dir.mktmpdir( "carson-worktree-test", carson_tmp_root ) do |tmp_dir|
			bare_root = File.join( tmp_dir, "bare" )
			repo_root = File.join( tmp_dir, "repo" )
			system( "git", "init", "--bare", "-b", "main", bare_root, out: File::NULL, err: File::NULL )
			system( "git", "clone", bare_root, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "README.md" ), "init\n" )
			system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "" ) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: false
				)

				wt = create_worktree( repo_root: repo_root, worktree_name: "concise-test" )
				status = runtime.worktree_remove!( worktree_path: wt.fetch( :path ) )
				assert_equal Carson::Runtime::EXIT_OK, status
				assert_includes out.string, "Worktree removed: concise-test"
				refute_includes out.string, "worktree_removed:"
			end
		end
	end
end
