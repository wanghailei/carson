# Tests for worktree management and safety guards.
require_relative "test_helper"

class RuntimeWorktreeTest < Minitest::Test
	include CarsonTestSupport

	def with_worktree_repo( mock_gh_script: nil )
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

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			if mock_gh_script
				File.write( File.join( mock_bin, "gh" ), mock_gh_script )
				FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )
			end

			with_env( "HOME" => tmp_dir, "CARSON_CONFIG_FILE" => "", "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
				output = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					output: output,
					error: StringIO.new,
					verbose: true
				)
				yield runtime, repo_root, bare_root, output
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

	def mock_gh_for_worktree_reap( closed_prs_by_branch:, open_pr_branches: [] )
		closed_clauses = closed_prs_by_branch.map do |branch, entries|
			pr_json = JSON.generate(
				Array( entries ).map do |entry|
					{
						"number" => entry.fetch( :number ),
						"html_url" => "https://github.com/test/repo/pull/#{entry.fetch( :number )}",
						"merged_at" => entry[ :merged_at ],
						"closed_at" => entry[ :closed_at ],
						"head" => { "ref" => branch, "sha" => entry.fetch( :sha ) },
						"base" => { "ref" => "main" }
					}
				end
			)
			<<~CLAUSE
				if echo "$@" | grep -q "state=closed" && echo "$@" | grep -q "head=test:#{branch}"; then
					if echo "$@" | grep -qE " page=1$"; then
						cat <<'PRJSON'
			#{pr_json}
			PRJSON
						exit 0
					fi
					echo "[]"
					exit 0
				fi
			CLAUSE
		end.join( "\n" )

		open_clauses = Array( open_pr_branches ).map do |branch|
			pr_json = JSON.generate( [ {
				"number" => 99,
				"html_url" => "https://github.com/test/repo/pull/99",
				"state" => "open",
				"head" => { "ref" => branch },
				"base" => { "ref" => "main" }
			} ] )
			<<~CLAUSE
				if echo "$@" | grep -q "state=open" && echo "$@" | grep -q "head=test:#{branch}"; then
					cat <<'PRJSON'
			#{pr_json}
			PRJSON
					exit 0
				fi
			CLAUSE
		end.join( "\n" )

		<<~BASH
			#!/usr/bin/env bash
			if [[ "$1" == "--version" ]]; then
				echo "gh version mock"
				exit 0
			fi
			if [[ "$1" == "repo" && "$2" == "view" ]]; then
				echo "test/repo"
				exit 0
			fi
			if [[ "$1" == "api" ]]; then
				#{open_clauses}
				#{closed_clauses}
				echo "[]"
				exit 0
			fi
			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def with_mock_gh( repo_root:, script: )
		mock_bin = File.join( repo_root, ".mock-bin" )
		FileUtils.mkdir_p( mock_bin )
		File.write( File.join( mock_bin, "gh" ), script )
		FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

		with_env( "PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}" ) do
			yield
		end
	end

	def test_worktree_remove_by_path
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "test-remove" )

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree directory should exist"
			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree.fetch( :path ) ), "worktree directory should be removed"
			assert_includes output.string, "worktree_removed:"
			assert_includes output.string, "branch_deleted: #{worktree.fetch( :branch )}"
		end
	end

	def test_worktree_remove_by_name
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "by-name" )

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree directory should exist"
			# Pass just the name, not full path.
			status = runtime.worktree_remove!( worktree_path: "by-name" )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree.fetch( :path ) ), "worktree directory should be removed"
		end
	end


	def test_worktree_remove_by_name_nested
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			# Simulate a worktree created by Claude Code under .claude/worktrees/claude/<name>.
			nested_dir = File.join( repo_root, ".claude", "worktrees", "claude", "nested-wt" )
			FileUtils.mkdir_p( File.dirname( nested_dir ) )
			branch_name = "claude/nested-wt"
			system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, nested_dir, out: File::NULL, err: File::NULL )
			File.write( File.join( nested_dir, "nested.txt" ), "work\n" )
			system( "git", "-C", nested_dir, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", nested_dir, "commit", "-m", "nested work", out: File::NULL, err: File::NULL )
			system( "git", "-C", nested_dir, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )

			assert Dir.exist?( nested_dir ), "nested worktree directory should exist"
			# Pass just the leaf name — should resolve to the nested path.
			status = runtime.worktree_remove!( worktree_path: "nested-wt" )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( nested_dir ), "nested worktree directory should be removed"
			assert_includes output.string, "worktree_removed:"
		end
	end

	def test_worktree_remove_branch_deleted
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "branch-del" )
			branch = worktree.fetch( :branch )

			# Verify branch exists before removal.
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should exist before worktree remove"

			runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )

			refute system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should be deleted after worktree remove"
		end
	end

	def test_worktree_remove_protected_branch_preserved
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
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
		with_worktree_repo do |runtime, _repo_root, _bare_root, output|
			status = runtime.worktree_remove!( worktree_path: "/nonexistent/path" )
			assert_equal Carson::Runtime::EXIT_ERROR, status
			assert_includes output.string, "not a registered worktree"
		end
	end

	def test_worktree_remove_dirty_refused_without_force
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "dirty-refuse" )

			# Add uncommitted changes to the worktree.
			File.write( File.join( worktree.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_ERROR, status
			assert Dir.exist?( worktree.fetch( :path ) ), "dirty worktree must be preserved without --force"
			assert_includes output.string, "uncommitted changes"
			assert_includes output.string, "--force"
		end
	end

	def test_worktree_remove_dirty_accepted_with_force
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "dirty-force" )

			# Add uncommitted changes to the worktree.
			File.write( File.join( worktree.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ), force: true )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree.fetch( :path ) ), "dirty worktree should be removed with --force"
		end
	end

	def test_worktree_remove_blocks_unpushed_commits
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "unpushed-rm", push: false )

			# Branch has a commit that was never pushed — remove should block.
			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_BLOCK, status
			assert Dir.exist?( worktree.fetch( :path ) ), "worktree must be preserved when unpushed"
			assert_includes output.string, "not been pushed"
			assert_includes output.string, "--force"
		end
	end

	def test_worktree_remove_allows_pushed_branch
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			# Helper pushes by default — branch is safe to remove.
			worktree = create_worktree( repo_root: repo_root, worktree_name: "pushed-rm" )

			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree.fetch( :path ) ), "pushed worktree should be removed"
		end
	end

	def test_worktree_remove_force_overrides_unpushed_guard
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "force-unpushed", push: false )

			# Branch has unpushed commits but --force should override.
			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ), force: true )
			assert_equal Carson::Runtime::EXIT_OK, status
			refute Dir.exist?( worktree.fetch( :path ) ), "force should remove even with unpushed commits"
		end
	end

	# --- sweep_stale_worktrees! ---

	def test_sweep_stale_worktrees_removes_absorbed
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "stale-sweep" )
			branch = worktree.fetch( :branch )

			# Merge the worktree branch into main so its content is absorbed.
			system( "git", "-C", repo_root, "merge", branch, "--no-edit", out: File::NULL, err: File::NULL )

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree directory should exist before sweep"
			runtime.sweep_stale_worktrees!
			refute Dir.exist?( worktree.fetch( :path ) ), "absorbed worktree should be swept"

			# Branch should be deleted.
			refute system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should be deleted after sweep"

			assert_includes output.string, "swept stale worktree: stale-sweep"
			assert_includes output.string, "deleted branch: #{branch}"
		end
	end

	def test_sweep_stale_worktrees_skips_non_absorbed
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "active-work" )

			# Do NOT merge — content is still unique to the branch.
			assert Dir.exist?( worktree.fetch( :path ) ), "worktree directory should exist"
			runtime.sweep_stale_worktrees!
			assert Dir.exist?( worktree.fetch( :path ) ), "non-absorbed worktree must be preserved"
		end
	end

	def test_sweep_stale_worktrees_scans_codex_directory
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
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

			assert_includes output.string, "swept stale worktree: codex-task"
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

	def test_sweep_stale_worktrees_skips_worktree_held_by_other_process
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "held-sweep" )
			branch = worktree.fetch( :branch )

			# Merge into main so content is absorbed.
			system( "git", "-C", repo_root, "merge", branch, "--no-edit", out: File::NULL, err: File::NULL )

			# Fork a child that holds its CWD inside the worktree.
			child_ready_r, child_ready_w = IO.pipe
			parent_done_r, parent_done_w = IO.pipe

			pid = fork do
				child_ready_r.close
				parent_done_w.close
				Dir.chdir( worktree.fetch( :path ) )
				child_ready_w.write( "ready" )
				child_ready_w.close
				parent_done_r.read
				parent_done_r.close
			end

			child_ready_w.close
			parent_done_r.close
			child_ready_r.read
			child_ready_r.close

			runtime.sweep_stale_worktrees!

			parent_done_w.close
			Process.wait( pid )

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree held by another process must be preserved"
		end
	end

	def test_sweep_stale_worktrees_skips_dirty_worktree
		with_worktree_repo do |runtime, repo_root, _bare_root, _out|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "dirty-sweep" )
			branch = worktree.fetch( :branch )

			# Merge into main so content is absorbed.
			system( "git", "-C", repo_root, "merge", branch, "--no-edit", out: File::NULL, err: File::NULL )

			# Add uncommitted changes — git worktree remove will refuse.
			File.write( File.join( worktree.fetch( :path ), "unsaved.txt" ), "precious work\n" )

			runtime.sweep_stale_worktrees!
			assert Dir.exist?( worktree.fetch( :path ) ), "dirty worktree must be preserved even if absorbed"
		end
	end

	def test_reap_dead_worktrees_reaps_abandoned_worktree_with_closed_pr
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "abandoned-pr" )
			tip_sha = `git -C #{worktree.fetch( :path )} rev-parse HEAD`.strip
			mock_script = mock_gh_for_worktree_reap(
				closed_prs_by_branch: {
					worktree.fetch( :branch ) => [ {
						number: 41,
						sha: tip_sha,
						merged_at: nil,
						closed_at: "2026-03-11T10:00:00Z"
					} ]
				}
			)

			with_mock_gh( repo_root: repo_root, script: mock_script ) do
				runtime.reap_dead_worktrees!
			end

			refute Dir.exist?( worktree.fetch( :path ) ), "abandoned worktree should be reaped"
			refute system( "git", "-C", repo_root, "rev-parse", "--verify", worktree.fetch( :branch ), out: File::NULL, err: File::NULL ),
				"abandoned branch should be deleted after reap"
			assert_includes output.string, "reaped abandoned worktree: abandoned-pr"
			assert_includes output.string, "https://github.com/test/repo/pull/41"
		end
	end

	def test_reap_dead_worktrees_skips_abandoned_worktree_when_open_pr_exists
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "abandoned-open" )
			tip_sha = `git -C #{worktree.fetch( :path )} rev-parse HEAD`.strip
			mock_script = mock_gh_for_worktree_reap(
				closed_prs_by_branch: {
					worktree.fetch( :branch ) => [ {
						number: 42,
						sha: tip_sha,
						merged_at: nil,
						closed_at: "2026-03-11T10:00:00Z"
					} ]
				},
				open_pr_branches: [ worktree.fetch( :branch ) ]
			)

			with_mock_gh( repo_root: repo_root, script: mock_script ) do
				runtime.reap_dead_worktrees!
			end

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree with open PR must be preserved"
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", worktree.fetch( :branch ), out: File::NULL, err: File::NULL ),
				"branch with open PR should still exist"
			refute_includes output.string, "reaped abandoned worktree: abandoned-open"
		end
	end

	def test_reap_dead_worktrees_skips_abandoned_worktree_when_closed_pr_sha_mismatches
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "abandoned-mismatch" )
			mock_script = mock_gh_for_worktree_reap(
				closed_prs_by_branch: {
					worktree.fetch( :branch ) => [ {
						number: 43,
						sha: "deadbeef",
						merged_at: nil,
						closed_at: "2026-03-11T10:00:00Z"
					} ]
				}
			)

			with_mock_gh( repo_root: repo_root, script: mock_script ) do
				runtime.reap_dead_worktrees!
			end

			assert Dir.exist?( worktree.fetch( :path ) ), "worktree should be preserved when closed PR SHA does not match"
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", worktree.fetch( :branch ), out: File::NULL, err: File::NULL ),
				"branch should still exist when closed PR SHA does not match"
			refute_includes output.string, "reaped abandoned worktree: abandoned-mismatch"
		end
	end

	def test_reap_dead_worktrees_skips_dirty_abandoned_worktree
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "abandoned-dirty" )
			tip_sha = `git -C #{worktree.fetch( :path )} rev-parse HEAD`.strip
			File.write( File.join( worktree.fetch( :path ), "unsaved.txt" ), "precious work\n" )
			mock_script = mock_gh_for_worktree_reap(
				closed_prs_by_branch: {
					worktree.fetch( :branch ) => [ {
						number: 44,
						sha: tip_sha,
						merged_at: nil,
						closed_at: "2026-03-11T10:00:00Z"
					} ]
				}
			)

			with_mock_gh( repo_root: repo_root, script: mock_script ) do
				runtime.reap_dead_worktrees!
			end

			assert Dir.exist?( worktree.fetch( :path ) ), "dirty abandoned worktree must be preserved"
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", worktree.fetch( :branch ), out: File::NULL, err: File::NULL ),
				"dirty abandoned branch should still exist"
			refute_includes output.string, "reaped abandoned worktree: abandoned-dirty"
		end
	end

	# --- missing directory tests (gh pr merge --delete-branch aftermath) ---

	def test_worktree_remove_missing_directory_by_name
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "gone-name" )
			branch = worktree.fetch( :branch )

			# Simulate gh pr merge --delete-branch: delete the directory externally.
			FileUtils.rm_rf( worktree.fetch( :path ) )
			refute Dir.exist?( worktree.fetch( :path ) ), "directory should be gone"

			# Branch should still exist before cleanup.
			assert system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should still exist before worktree remove"

			status = runtime.worktree_remove!( worktree_path: "gone-name" )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert_includes output.string, "pruned stale worktree entry"
			assert_includes output.string, "branch_deleted: #{branch}"

			# Branch should be deleted after cleanup.
			refute system( "git", "-C", repo_root, "rev-parse", "--verify", branch, out: File::NULL, err: File::NULL ),
				"branch should be deleted after worktree remove"
		end
	end

	def test_worktree_remove_missing_directory_by_path
		with_worktree_repo do |runtime, repo_root, _bare_root, output|
			worktree = create_worktree( repo_root: repo_root, worktree_name: "gone-path" )

			# Simulate external deletion.
			FileUtils.rm_rf( worktree.fetch( :path ) )

			status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
			assert_equal Carson::Runtime::EXIT_OK, status
			assert_includes output.string, "pruned stale worktree entry"
		end
	end

	def test_worktree_remove_missing_directory_json_output
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
				output = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					output: output,
					error: StringIO.new,
					verbose: false
				)

				worktree = create_worktree( repo_root: repo_root, worktree_name: "gone-json" )
				FileUtils.rm_rf( worktree.fetch( :path ) )

				status = runtime.worktree_remove!( worktree_path: "gone-json", json_output: true )
				assert_equal Carson::Runtime::EXIT_OK, status

				json = JSON.parse( output.string.strip )
				assert_equal "ok", json[ "status" ]
				assert_equal "gone-json", json[ "name" ]
				assert_equal true, json[ "branch_deleted" ]
			end
		end
	end

	def test_worktree_remove_missing_and_unregistered_fails
		with_worktree_repo do |runtime, _repo_root, _bare_root, output|
			# A name that was never a worktree — directory doesn't exist and not registered.
			status = runtime.worktree_remove!( worktree_path: "never-existed" )
			assert_equal Carson::Runtime::EXIT_ERROR, status
			assert_includes output.string, "not a registered worktree"
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
				output = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					output: output,
					error: StringIO.new,
					verbose: false
				)

				worktree = create_worktree( repo_root: repo_root, worktree_name: "concise-test" )
				status = runtime.worktree_remove!( worktree_path: worktree.fetch( :path ) )
				assert_equal Carson::Runtime::EXIT_OK, status
				assert_includes output.string, "Worktree removed: concise-test"
				refute_includes output.string, "worktree_removed:"
			end
		end
	end
end
