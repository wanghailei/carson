require_relative "test_helper"

class RuntimePruneTest < Minitest::Test
	include CarsonTestSupport

	# Sets up a local repo with a bare remote so git fetch origin --prune works.
	# Yields runtime, repo_root, bare_root, and mock_bin directory.
	def with_prune_repo( mock_gh_script: nil, verbose: true )
		Dir.mktmpdir( "carson-prune-test", carson_tmp_root ) do |tmp_dir|
			bare_root = File.join( tmp_dir, "bare" )
			repo_root = File.join( tmp_dir, "repo" )
			system( "git", "init", "--bare", "-b", "main", bare_root, out: File::NULL, err: File::NULL )
			system( "git", "clone", bare_root, repo_root, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
			# Initial commit on main.
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

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				err = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: err,
					verbose: verbose
				)
				yield runtime, repo_root, bare_root, out, mock_bin
			end
		end
	end

	# Creates a local branch with a commit and no upstream tracking.
	def create_orphan_branch( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "work\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
		tip_sha = `git -C #{repo_root} rev-parse HEAD`.strip
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
		tip_sha
	end

	# Creates a local branch with tracking that becomes [gone] after remote deletion.
	def create_gone_branch( repo_root:, bare_root:, branch_name: )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "work\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
		tip_sha = `git -C #{repo_root} rev-parse HEAD`.strip
		system( "git", "-C", repo_root, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
		# Delete remote branch so it becomes [gone] after fetch --prune.
		system( "git", "-C", bare_root, "branch", "-D", branch_name, out: File::NULL, err: File::NULL )
		tip_sha
	end

	# Creates a tracked branch whose content is then independently added to main.
	# The branch has tracking, remote still exists, but content is identical on main.
	def create_absorbed_branch( repo_root:, branch_name: )
		# Create branch with a unique file, push to remote.
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "feature content\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

		# Simulate the same content landing on main via a different PR.
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "feature content\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "land #{branch_name} content via other PR", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )
	end

	# Creates a tracked branch with content that differs from main (not absorbed).
	def create_active_tracked_branch( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "unique content\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )
	end

	def branch_exists?( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "rev-parse", "--verify", branch_name, out: File::NULL, err: File::NULL )
	end

	def remote_branch_exists?( repo_root:, branch_name: )
		system( "git", "-C", repo_root, "rev-parse", "--verify", "origin/#{branch_name}", out: File::NULL, err: File::NULL )
	end

	def mock_gh_with_merged_pr( branch_shas: )
		# branch_shas: { "branch-name" => { sha: "abc123", number: 1 } }
		clauses = branch_shas.map do |branch, info|
			pr_json = JSON.generate( [ {
				"number" => info.fetch( :number ),
				"html_url" => "https://github.com/test/repo/pull/#{info.fetch( :number )}",
				"merged_at" => "2024-01-01T00:00:00Z",
				"head" => { "ref" => branch, "sha" => info.fetch( :sha ) },
				"base" => { "ref" => "main" }
			} ] )
			<<~CLAUSE
				if echo "$@" | grep -q "head=test:#{branch}"; then
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
				#{clauses}
				echo "[]"
				exit 0
			fi
			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def mock_gh_no_evidence
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
				echo "[]"
				exit 0
			fi
			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def mock_gh_with_open_pr( branch_name: )
		pr_json = JSON.generate( [ {
			"number" => 99,
			"html_url" => "https://github.com/test/repo/pull/99",
			"state" => "open",
			"head" => { "ref" => branch_name },
			"base" => { "ref" => "main" }
		} ] )

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
				if echo "$@" | grep -q "state=open"; then
					if echo "$@" | grep -q "head=test:#{branch_name}"; then
						cat <<'PRJSON'
			#{pr_json}
			PRJSON
						exit 0
					fi
				fi
				echo "[]"
				exit 0
			fi
			echo "unsupported: $*" >&2
			exit 1
		BASH
	end

	def mock_gh_unavailable
		<<~BASH
			#!/usr/bin/env bash
			exit 1
		BASH
	end

	# --- Orphan branch tests ---

	def test_orphan_deleted_with_merged_pr_evidence
		branch_name = "feature-orphan"

		Dir.mktmpdir( "carson-prune-test", carson_tmp_root ) do |tmp_dir|
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

			tip_sha = create_orphan_branch( repo_root: repo_root, branch_name: branch_name )
			mock_script = mock_gh_with_merged_pr( branch_shas: { branch_name => { sha: tip_sha, number: 10 } } )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), mock_script )
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: true
				)

				assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should exist before prune"
				status = runtime.prune!
				assert_equal Carson::Runtime::EXIT_OK, status
				refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should be deleted after prune"
				assert_includes out.string, "deleted_orphan_branch: #{branch_name}"
				assert_includes out.string, "merged_pr=https://github.com/test/repo/pull/10"
			end
		end
	end

	def test_orphan_skipped_without_merged_pr_evidence
		branch_name = "feature-no-evidence"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_orphan_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should be preserved without evidence"
			assert_includes out.string, "skip_orphan_branch: #{branch_name}"
		end
	end

	def test_orphan_skipped_when_gh_unavailable
		branch_name = "feature-no-gh"

		with_prune_repo( mock_gh_script: mock_gh_unavailable ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_orphan_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should be preserved when gh unavailable"
			# No orphan-specific log lines when gh is unavailable — silent skip.
			refute_includes out.string, "deleted_orphan_branch"
			refute_includes out.string, "skip_orphan_branch"
		end
	end

	def test_orphan_deleted_concise_output
		branch_name = "feature-concise"

		Dir.mktmpdir( "carson-prune-test", carson_tmp_root ) do |tmp_dir|
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

			tip_sha = create_orphan_branch( repo_root: repo_root, branch_name: branch_name )
			mock_script = mock_gh_with_merged_pr( branch_shas: { branch_name => { sha: tip_sha, number: 30 } } )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), mock_script )
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: false
				)

				status = runtime.prune!
				assert_equal Carson::Runtime::EXIT_OK, status
				refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "orphan branch should be deleted"
				assert_includes out.string, "Pruned 1 stale branch."
			end
		end
	end

	def test_combined_gone_and_orphan_branches_deleted
		gone_branch = "feature-gone"
		orphan_branch = "feature-orphan-combo"

		Dir.mktmpdir( "carson-prune-test", carson_tmp_root ) do |tmp_dir|
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

			gone_sha = create_gone_branch( repo_root: repo_root, bare_root: bare_root, branch_name: gone_branch )
			orphan_sha = create_orphan_branch( repo_root: repo_root, branch_name: orphan_branch )

			mock_script = mock_gh_with_merged_pr( branch_shas: {
				gone_branch => { sha: gone_sha, number: 20 },
				orphan_branch => { sha: orphan_sha, number: 21 }
			} )

			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), mock_script )
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: true
				)

				assert branch_exists?( repo_root: repo_root, branch_name: gone_branch ), "gone branch should exist before prune"
				assert branch_exists?( repo_root: repo_root, branch_name: orphan_branch ), "orphan branch should exist before prune"

				status = runtime.prune!
				assert_equal Carson::Runtime::EXIT_OK, status

				refute branch_exists?( repo_root: repo_root, branch_name: gone_branch ), "gone branch should be deleted"
				refute branch_exists?( repo_root: repo_root, branch_name: orphan_branch ), "orphan branch should be deleted"

				output = out.string
				assert_includes output, "deleted_orphan_branch: #{orphan_branch}"
				assert_includes output, "deleted_local_branch_force: #{gone_branch}"
				assert_includes output, "prune_summary: deleted=2"
			end
		end
	end

	# --- Absorbed branch tests ---

	def test_absorbed_branch_deleted_when_content_on_main
		branch_name = "feature-absorbed"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "absorbed branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "absorbed branch should be deleted"
			assert_includes out.string, "deleted_absorbed_branch: #{branch_name}"
		end
	end

	def test_absorbed_branch_deletes_remote_too
		branch_name = "feature-absorbed-remote"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch( repo_root: repo_root, branch_name: branch_name )

			# Fetch so we can verify remote ref exists.
			system( "git", "-C", repo_root, "fetch", "origin", out: File::NULL, err: File::NULL )
			assert remote_branch_exists?( repo_root: repo_root, branch_name: branch_name ), "remote branch should exist before prune"

			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "local branch should be deleted"

			# After prune, remote branch should also be gone.
			system( "git", "-C", repo_root, "fetch", "origin", "--prune", out: File::NULL, err: File::NULL )
			refute remote_branch_exists?( repo_root: repo_root, branch_name: branch_name ), "remote branch should be deleted"
		end
	end

	def test_absorbed_branch_preserved_when_unique_content
		branch_name = "feature-active"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_active_tracked_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "active branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "active branch with unique content should be preserved"
			refute_includes out.string, "deleted_absorbed_branch"
		end
	end

	def test_absorbed_branch_skipped_when_open_pr_exists
		branch_name = "feature-with-pr"

		with_prune_repo( mock_gh_script: mock_gh_with_open_pr( branch_name: branch_name ) ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch with open PR should be preserved"
			assert_includes out.string, "skip_absorbed_branch: #{branch_name} reason=open PR exists"
		end
	end

	def test_absorbed_branch_skipped_when_gh_unavailable
		branch_name = "feature-no-gh-absorbed"

		with_prune_repo( mock_gh_script: mock_gh_unavailable ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch( repo_root: repo_root, branch_name: branch_name )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch should be preserved when gh unavailable"
			refute_includes out.string, "deleted_absorbed_branch"
		end
	end

	def test_absorbed_ancestor_branch_deleted
		branch_name = "feature-ancestor"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			# Create branch at current main, then advance main. Branch becomes strict ancestor.
			system( "git", "-C", repo_root, "branch", branch_name, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "new-work.txt" ), "main advanced\n" )
			system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "advance main", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )

			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "ancestor branch should exist before prune"
			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "ancestor branch should be deleted"
			assert_includes out.string, "deleted_absorbed_branch: #{branch_name}"
		end
	end

	# Simulates a rebase merge: stale branch (upstream gone), content on main, but SHA
	# doesn't match any merged PR. The absorbed fallback should force-delete it.
	def test_stale_branch_deleted_via_absorbed_fallback
		branch_name = "feature-rebase-merged"

		Dir.mktmpdir( "carson-prune-test", carson_tmp_root ) do |tmp_dir|
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

			# Create branch, push, then simulate rebase merge: same content lands on main
			# with different commit (different SHA). Then delete remote branch.
			system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
			File.write( File.join( repo_root, "#{branch_name}.txt" ), "feature work\n" )
			system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

			# Land the same content on main (simulates rebase merge creating new commits).
			File.write( File.join( repo_root, "#{branch_name}.txt" ), "feature work\n" )
			system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "commit", "-m", "rebase-merged #{branch_name}", out: File::NULL, err: File::NULL )
			system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )

			# Delete remote branch so it becomes [gone].
			system( "git", "-C", bare_root, "branch", "-D", branch_name, out: File::NULL, err: File::NULL )

			# Mock gh returns NO merged PR evidence (SHA mismatch).
			mock_script = mock_gh_no_evidence
			mock_bin = File.join( tmp_dir, "mock-bin" )
			FileUtils.mkdir_p( mock_bin )
			File.write( File.join( mock_bin, "gh" ), mock_script )
			FileUtils.chmod( 0o755, File.join( mock_bin, "gh" ) )

			with_env(
				"HOME" => tmp_dir,
				"CARSON_CONFIG_FILE" => "",
				"PATH" => "#{mock_bin}:#{ENV.fetch( 'PATH' )}"
			) do
				out = StringIO.new
				runtime = Carson::Runtime.new(
					repo_root: repo_root,
					tool_root: File.expand_path( "..", __dir__ ),
					out: out,
					err: StringIO.new,
					verbose: true
				)

				assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "stale branch should exist before prune"
				status = runtime.prune!
				assert_equal Carson::Runtime::EXIT_OK, status
				refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "stale branch should be deleted via absorbed fallback"
				assert_includes out.string, "deleted_local_branch_force: #{branch_name}"
				assert_includes out.string, "absorbed into main"
			end
		end
	end

	def test_absorbed_branch_concise_output
		branch_name = "feature-absorbed-concise"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence, verbose: false ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch( repo_root: repo_root, branch_name: branch_name )

			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			refute branch_exists?( repo_root: repo_root, branch_name: branch_name ), "absorbed branch should be deleted"
			assert_includes out.string, "Pruned 1 stale branch."
			refute_includes out.string, "deleted_absorbed_branch"
		end
	end

	# --- Worktree-aware pruning tests ---

	# Creates an absorbed branch checked out in a worktree.
	def create_absorbed_branch_in_worktree( repo_root:, branch_name: )
		worktree_dir = File.join( repo_root, ".claude", "worktrees", branch_name )
		system( "git", "-C", repo_root, "worktree", "add", "-b", branch_name, worktree_dir, out: File::NULL, err: File::NULL )
		File.write( File.join( worktree_dir, "#{branch_name}.txt" ), "feature content\n" )
		system( "git", "-C", worktree_dir, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_dir, "commit", "-m", "work on #{branch_name}", out: File::NULL, err: File::NULL )
		system( "git", "-C", worktree_dir, "push", "-u", "origin", branch_name, out: File::NULL, err: File::NULL )

		# Land the same content on main so the branch is absorbed.
		File.write( File.join( repo_root, "#{branch_name}.txt" ), "feature content\n" )
		system( "git", "-C", repo_root, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "land #{branch_name} content via other PR", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "push", "origin", "main", out: File::NULL, err: File::NULL )
		worktree_dir
	end

	# Prune never removes worktrees — another session may own them.
	# Branch is skipped with a diagnostic instead.
	def test_absorbed_branch_in_worktree_skipped_with_diagnostic
		branch_name = "feature-wt-clean"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			wt_dir = create_absorbed_branch_in_worktree( repo_root: repo_root, branch_name: branch_name )

			assert Dir.exist?( wt_dir ), "worktree directory should exist before prune"
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch should exist before prune"

			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert branch_exists?( repo_root: repo_root, branch_name: branch_name ), "branch in worktree must be preserved"
			assert Dir.exist?( wt_dir ), "worktree must not be removed by prune"
			assert_includes out.string, "skip_worktree_blocked: #{branch_name}"
			assert_includes out.string, "carson worktree remove"
		end
	end

	def test_concise_output_shows_skipped_count
		branch_name = "feature-wt-skipped-concise"

		with_prune_repo( mock_gh_script: mock_gh_no_evidence, verbose: false ) do |runtime, repo_root, _bare_root, out, _mock_bin|
			create_absorbed_branch_in_worktree( repo_root: repo_root, branch_name: branch_name )

			status = runtime.prune!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert_includes out.string, "Skipped 1 branch (--verbose for details)."
			refute_includes out.string, "No stale branches."
		end
	end
end
