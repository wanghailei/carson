# Domain object representing a single git worktree entry.
# Owns its path, branch, and operating context (runtime).
# Answers state queries (CWD containment, process holds) and
# owns the full lifecycle: create, remove, list, sweep.
# Runtime provides infrastructure — git, config, output —
# the way ActiveRecord models hold a database connection.
require "fileutils"
require "json"
require "open3"

module Carson
	class Worktree
		# Agent directory names whose worktrees Carson may sweep.
		AGENT_DIRS = %w[ .claude .codex ].freeze

		attr_reader :path, :branch

		def initialize( path:, branch:, runtime: nil )
			@path = path
			@branch = branch
			@runtime = runtime
		end

		# --- Class lifecycle methods ---

		# Parses `git worktree list --porcelain` into Worktree instances.
		# Normalises paths with realpath so comparisons work across symlink differences.
		def self.list( runtime: )
			raw = runtime.git_capture!( "worktree", "list", "--porcelain" )
			entries = []
			current_path = nil
			current_branch = :unset
			raw.lines.each do |line|
				line = line.strip
				if line.empty?
					entries << new( path: current_path, branch: current_branch == :unset ? nil : current_branch, runtime: runtime ) if current_path
					current_path = nil
					current_branch = :unset
				elsif line.start_with?( "worktree " )
					current_path = runtime.realpath_safe( line.sub( "worktree ", "" ) )
				elsif line.start_with?( "branch " )
					current_branch = line.sub( "branch refs/heads/", "" )
				elsif line == "detached"
					current_branch = nil
				end
			end
			entries << new( path: current_path, branch: current_branch == :unset ? nil : current_branch, runtime: runtime ) if current_path
			entries
		end

		# Finds the Worktree entry for a given path, or nil.
		# Compares using realpath to handle symlink differences.
		def self.find( path:, runtime: )
			canonical = runtime.realpath_safe( path )
			list( runtime: runtime ).find { |worktree| worktree.path == canonical }
		end

		# Returns true if the path is a registered git worktree.
		def self.registered?( path:, runtime: )
			canonical = runtime.realpath_safe( path )
			list( runtime: runtime ).any? { |worktree| worktree.path == canonical }
		end

		# Creates a new worktree under .claude/worktrees/<name> with a fresh branch.
		# Uses main_worktree_root so this works even when called from inside a worktree.
		def self.create!( name:, runtime:, json_output: false )
			worktrees_dir = File.join( runtime.main_worktree_root, ".claude", "worktrees" )
			worktree_path = File.join( worktrees_dir, name )

			if Dir.exist?( worktree_path )
				return finish(
					result: { command: "worktree create", status: "error", name: name, path: worktree_path,
						error: "worktree already exists: #{name}",
						recovery: "carson worktree remove #{name}, then retry" },
					exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
				)
			end

			# Determine the base branch (main branch from config).
			base = runtime.config.main_branch

			# Sync main from remote before branching so the worktree starts
			# from the latest code. Prevents stale-base merge conflicts later.
			# Best-effort — if pull fails (non-ff, offline), continue anyway.
			main_root = runtime.main_worktree_root
			_, _, pull_ok, = Open3.capture3( "git", "-C", main_root, "pull", "--ff-only", runtime.config.git_remote, base )
			runtime.puts_verbose pull_ok.success? ? "synced #{base} before branching" : "sync skipped — continuing from local #{base}"

			# Ensure .claude/ is excluded from git status in the host repository.
			# Uses .git/info/exclude (local-only, never committed) to respect the outsider boundary.
			ensure_claude_dir_excluded!( runtime: runtime )

			# Create the worktree with a new branch based on the main branch.
			FileUtils.mkdir_p( worktrees_dir )
			_, worktree_stderr, worktree_success, = runtime.git_run( "worktree", "add", worktree_path, "-b", name, base )
			unless worktree_success
				error_text = worktree_stderr.to_s.strip
				error_text = "unable to create worktree" if error_text.empty?
				return finish(
					result: { command: "worktree create", status: "error", name: name,
						error: error_text },
					exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
				)
			end

			unless creation_verified?( path: worktree_path, branch: name, runtime: runtime )
				return finish(
					result: { command: "worktree create", status: "error", name: name, path: worktree_path, branch: name,
						error: "git reported success but Carson could not verify the worktree and branch",
						recovery: "git worktree list && git branch --list '#{name}'" },
					exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
				)
			end

			finish(
				result: { command: "worktree create", status: "ok", name: name, path: worktree_path, branch: name },
				exit_code: Runtime::EXIT_OK, runtime: runtime, json_output: json_output
			)
		end

		# Removes a worktree: directory, git registration, and branch.
		# Never forces removal — if the worktree has uncommitted changes, refuses unless
		# the caller explicitly passes force: true via CLI --force flag.
		def self.remove!( path:, runtime:, force: false, json_output: false )
			fingerprint_status = runtime.block_if_outsider_fingerprints!
			unless fingerprint_status.nil?
				if json_output
					runtime.output.puts JSON.pretty_generate( {
						command: "worktree remove", status: "block",
						error: "Carson-owned artefacts detected in host repository",
						recovery: "remove Carson-owned files (.carson.yml, bin/carson, .tools/carson) then retry",
						exit_code: Runtime::EXIT_BLOCK
					} )
				end
				return fingerprint_status
			end

			resolved_path = resolve_path( path: path, runtime: runtime )

			# Missing directory: worktree was destroyed externally (e.g. gh pr merge
			# --delete-branch). Clean up the stale git registration and delete the branch.
			if !Dir.exist?( resolved_path ) && registered?( path: resolved_path, runtime: runtime )
				return remove_missing!( resolved_path: resolved_path, runtime: runtime, json_output: json_output )
			end

			unless registered?( path: resolved_path, runtime: runtime )
				return finish(
					result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
						error: "#{resolved_path} is not a registered worktree",
						recovery: "git worktree list" },
					exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
				)
			end

			# Safety: refuse if the caller's shell CWD is inside the worktree.
			# Removing a directory while a shell is inside it kills the shell permanently.
			entry = find( path: resolved_path, runtime: runtime )
			if entry&.holds_cwd?
				safe_root = runtime.main_worktree_root
				return finish(
					result: { command: "worktree remove", status: "block", name: File.basename( resolved_path ),
						error: "current working directory is inside this worktree",
						recovery: "cd #{safe_root} && carson worktree remove #{File.basename( resolved_path )}" },
					exit_code: Runtime::EXIT_BLOCK, runtime: runtime, json_output: json_output
				)
			end

			# Safety: refuse if another process has its CWD inside the worktree.
			# Protects against cross-process CWD crashes (e.g. an agent session
			# removed by a separate cleanup process while the agent's shell is inside).
			if entry&.held_by_other_process?
				return finish(
					result: { command: "worktree remove", status: "block", name: File.basename( resolved_path ),
						error: "another process has its working directory inside this worktree",
						recovery: "wait for the other session to finish, then retry" },
					exit_code: Runtime::EXIT_BLOCK, runtime: runtime, json_output: json_output
				)
			end

			branch = entry&.branch
			runtime.puts_verbose "worktree_remove: path=#{resolved_path} branch=#{branch} force=#{force}"

			# Safety: refuse if the branch has unpushed commits (unless --force).
			# Prevents accidental destruction of work that exists only locally.
			unless force
				unpushed = check_unpushed_commits( branch: branch, worktree_path: resolved_path, runtime: runtime )
				if unpushed
					return finish(
						result: { command: "worktree remove", status: "block", name: File.basename( resolved_path ),
							branch: branch,
							error: unpushed[ :error ],
							recovery: unpushed[ :recovery ] },
						exit_code: Runtime::EXIT_BLOCK, runtime: runtime, json_output: json_output
					)
				end
			end

			# Step 1: remove the worktree (directory + git registration).
			rm_args = [ "worktree", "remove" ]
			rm_args << "--force" if force
			rm_args << resolved_path
			_, rm_stderr, rm_success, = runtime.git_run( *rm_args )
			unless rm_success
				error_text = rm_stderr.to_s.strip
				error_text = "unable to remove worktree" if error_text.empty?
				if !force && ( error_text.downcase.include?( "untracked" ) || error_text.downcase.include?( "modified" ) )
					return finish(
						result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
							error: "worktree has uncommitted changes",
							recovery: "commit or discard changes first, or use --force to override" },
						exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
					)
				end
				return finish(
					result: { command: "worktree remove", status: "error", name: File.basename( resolved_path ),
						error: error_text },
					exit_code: Runtime::EXIT_ERROR, runtime: runtime, json_output: json_output
				)
			end
			runtime.puts_verbose "worktree_removed: #{resolved_path}"

			# Step 2: delete the local branch.
			branch_deleted = false
			if branch && !runtime.config.protected_branches.include?( branch )
				_, del_stderr, del_success, = runtime.git_run( "branch", "-D", branch )
				if del_success
					runtime.puts_verbose "branch_deleted: #{branch}"
					branch_deleted = true
				else
					runtime.puts_verbose "branch_delete_skipped: #{branch} reason=#{del_stderr.to_s.strip}"
				end
			end

			# Step 3: delete the remote branch (best-effort).
			remote_deleted = false
			if branch && !runtime.config.protected_branches.include?( branch )
				remote_branch = branch
				_, _, rd_success, = runtime.git_run( "push", runtime.config.git_remote, "--delete", remote_branch )
				if rd_success
					runtime.puts_verbose "remote_branch_deleted: #{runtime.config.git_remote}/#{remote_branch}"
					remote_deleted = true
				end
			end
			finish(
				result: { command: "worktree remove", status: "ok", name: File.basename( resolved_path ),
					branch: branch, branch_deleted: branch_deleted, remote_deleted: remote_deleted },
				exit_code: Runtime::EXIT_OK, runtime: runtime, json_output: json_output
			)
		end

		# Removes agent-owned worktrees whose branch content is already on main.
		# Scans AGENT_DIRS (e.g. .claude/worktrees/, .codex/worktrees/)
		# under the main repo root. Safe: skips detached HEADs, the caller's CWD,
		# and dirty working trees (git worktree remove refuses without --force).
		def self.sweep_stale!( runtime: )
			main_root = runtime.main_worktree_root
			worktrees = list( runtime: runtime )

			agent_prefixes = AGENT_DIRS.map do |dir|
				full = File.join( main_root, dir, "worktrees" )
				File.join( runtime.realpath_safe( full ), "" ) if Dir.exist?( full )
			end.compact
			return if agent_prefixes.empty?

			worktrees.each do |worktree|
				next unless worktree.branch
				next unless agent_prefixes.any? { |prefix| worktree.path.start_with?( prefix ) }
				next if worktree.holds_cwd?
				next if worktree.held_by_other_process?
				next unless runtime.branch_absorbed_into_main?( branch: worktree.branch )

				# Remove the worktree (no --force: refuses if dirty working tree).
				_, _, rm_success, = runtime.git_run( "worktree", "remove", worktree.path )
				next unless rm_success

				runtime.puts_verbose "swept stale worktree: #{File.basename( worktree.path )} (branch: #{worktree.branch})"

				# Delete the local branch now that no worktree holds it.
				if !runtime.config.protected_branches.include?( worktree.branch )
					runtime.git_run( "branch", "-D", worktree.branch )
					runtime.puts_verbose "deleted branch: #{worktree.branch}"
				end
			end
		end

		# --- Instance query methods ---

		# Is the current process CWD inside this worktree?
		def holds_cwd?
			cwd = realpath_safe( Dir.pwd )
			worktree = realpath_safe( path )
			normalised = File.join( worktree, "" )
			cwd == worktree || cwd.start_with?( normalised )
		rescue StandardError
			false
		end

		# Does another process have its CWD inside this worktree?
		def held_by_other_process?
			canonical = realpath_safe( path )
			return false if canonical.nil? || canonical.empty?
			return false unless Dir.exist?( canonical )

			stdout, = Open3.capture3( "lsof", "-d", "cwd" )
			# Do NOT gate on exit status — lsof exits non-zero on macOS when SIP blocks
			# access to some system processes, even though user-process output is valid.
			return false if stdout.nil? || stdout.empty?

			normalised = File.join( canonical, "" )
			my_pid = Process.pid
			stdout.lines.drop( 1 ).any? do |line|
				fields = line.strip.split( /\s+/ )
				next false unless fields.length >= 9
				next false if fields[ 1 ].to_i == my_pid
				name = fields[ 8.. ].join( " " )
				name == canonical || name.start_with?( normalised )
			end
		rescue Errno::ENOENT
			# lsof not installed.
			false
		rescue StandardError
			false
		end

	# rubocop:disable Layout/AccessModifierIndentation -- tab-width calculation produces unfixable mixed tabs+spaces
	private
	# rubocop:enable Layout/AccessModifierIndentation

		attr_reader :runtime

		# --- Private class methods ---

		# Handles removal when the worktree directory is already gone (destroyed
		# externally by gh pr merge --delete-branch or manual deletion).
		# Prunes the stale git worktree entry and cleans up the branch.
		def self.remove_missing!( resolved_path:, runtime:, json_output: )
			branch = find( path: resolved_path, runtime: runtime )&.branch
			runtime.puts_verbose "worktree_remove_missing: path=#{resolved_path} branch=#{branch}"

			# Prune the stale worktree entry from git's registry.
			runtime.git_run( "worktree", "prune" )
			runtime.puts_verbose "pruned stale worktree entry: #{resolved_path}"

			# Delete the local branch.
			branch_deleted = false
			if branch && !runtime.config.protected_branches.include?( branch )
				_, _, del_success, = runtime.git_run( "branch", "-D", branch )
				if del_success
					runtime.puts_verbose "branch_deleted: #{branch}"
					branch_deleted = true
				end
			end

			# Delete the remote branch (best-effort).
			remote_deleted = false
			if branch && !runtime.config.protected_branches.include?( branch )
				_, _, rd_success, = runtime.git_run( "push", runtime.config.git_remote, "--delete", branch )
				if rd_success
					runtime.puts_verbose "remote_branch_deleted: #{runtime.config.git_remote}/#{branch}"
					remote_deleted = true
				end
			end

			finish(
				result: { command: "worktree remove", status: "ok", name: File.basename( resolved_path ),
					branch: branch, branch_deleted: branch_deleted, remote_deleted: remote_deleted },
				exit_code: Runtime::EXIT_OK, runtime: runtime, json_output: json_output
			)
		end
		private_class_method :remove_missing!

		# Unified output for worktree results — JSON or human-readable.
		def self.finish( result:, exit_code:, runtime:, json_output: )
			result[ :exit_code ] = exit_code

			if json_output
				runtime.output.puts JSON.pretty_generate( result )
			else
				print_human( result: result, runtime: runtime )
			end

			exit_code
		end
		private_class_method :finish

		def self.creation_verified?( path:, branch:, runtime: )
			registered?( path: path, runtime: runtime ) && branch_exists?( branch: branch, runtime: runtime )
		end
		private_class_method :creation_verified?

		def self.branch_exists?( branch:, runtime: )
			_, _, success, = runtime.git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{branch}" )
			success
		end
		private_class_method :branch_exists?

		# Human-readable output for worktree results.
		def self.print_human( result:, runtime: )
			command = result[ :command ]
			status = result[ :status ]

			case status
			when "ok"
				case command
				when "worktree create"
					runtime.puts_line "Worktree created: #{result[ :name ]}"
					runtime.puts_line "  Path: #{result[ :path ]}"
					runtime.puts_line "  Branch: #{result[ :branch ]}"
				when "worktree remove"
					unless runtime.verbose?
						runtime.puts_line "Worktree removed: #{result[ :name ]}"
					end
				end
			when "error"
				runtime.puts_line result[ :error ]
				runtime.puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
			when "block"
				runtime.puts_line "#{result[ :error ]&.capitalize || 'Held'}: #{result[ :name ]}"
				runtime.puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
			end
		end
		private_class_method :print_human

		# Checks whether a branch has unpushed commits that would be lost on removal.
		# Content-aware: after squash/rebase merge, SHAs differ but tree content may match main.
		# Compares content, not SHAs.
		# Returns nil if safe, or { error:, recovery: } hash if unpushed work exists.
		def self.check_unpushed_commits( branch:, worktree_path:, runtime: )
			return nil unless branch

			remote = runtime.config.git_remote
			remote_ref = "#{remote}/#{branch}"
			ahead, _, ahead_status, = Open3.capture3( "git", "rev-list", "--count", "#{remote_ref}..#{branch}", chdir: worktree_path )
			if !ahead_status.success?
				# Remote ref does not exist. Only block if the branch has unique commits vs main.
				unique, _, unique_status, = Open3.capture3( "git", "rev-list", "--count", "#{runtime.config.main_branch}..#{branch}", chdir: worktree_path )
				if unique_status.success? && unique.strip.to_i > 0
					# Content-aware check: after squash/rebase merge, commit SHAs differ
					# but the tree content may be identical to main. Compare content,
					# not SHAs — if the diff is empty, the work is already on main.
					_, _, diff_ok, = Open3.capture3( "git", "diff", "--quiet", runtime.config.main_branch, branch, chdir: worktree_path )
					unless diff_ok.success?
						return { error: "branch has not been pushed to #{remote}",
							recovery: "git -C #{worktree_path} push -u #{remote} #{branch}, or use --force to override" }
					end
					# Diff is empty — content is on main (squash/rebase merged). Safe.
					runtime.puts_verbose "branch #{branch} content matches main — squash/rebase merged, safe to remove"
				end
			elsif ahead.strip.to_i > 0
				return { error: "worktree has unpushed commits",
					recovery: "git -C #{worktree_path} push #{remote} #{branch}, or use --force to override" }
			end

			nil
		end
		private_class_method :check_unpushed_commits

		# Resolves a worktree path: if it's a bare name, first tries the flat
		# .claude/worktrees/<name> convention; if that isn't registered, searches
		# all registered worktrees for one whose directory name matches.
		# This handles worktrees created by external tools (e.g. Claude Code) that
		# nest under a subdirectory like .claude/worktrees/claude/<name>.
		# Returns the canonical (realpath) form so comparisons against git worktree list
		# succeed, even when the OS resolves symlinks differently.
		# Uses main_worktree_root (not repo_root) so resolution works from inside worktrees.
		def self.resolve_path( path:, runtime: )
			if path.include?( "/" )
				return runtime.realpath_safe( path )
			end

			root = runtime.main_worktree_root
			candidate = File.join( root, ".claude", "worktrees", path )
			canonical = runtime.realpath_safe( candidate )
			return canonical if registered?( path: canonical, runtime: runtime )

			# Bare name didn't match flat layout — search registered worktrees by dirname.
			matches = list( runtime: runtime ).select { |worktree| File.basename( worktree.path ) == path }
			return matches.first.path if matches.size == 1

			# No match or ambiguous — return the flat candidate and let the caller
			# produce the appropriate error message.
			canonical
		end
		private_class_method :resolve_path

		# Adds .claude/ to .git/info/exclude if not already present.
		# This prevents worktree directories from appearing as untracked files
		# in the host repository. Uses the local exclude file (never committed)
		# so the host repo's .gitignore is never touched.
		# Uses main_worktree_root — worktrees have .git as a file, not a directory.
		def self.ensure_claude_dir_excluded!( runtime: )
			git_dir = File.join( runtime.main_worktree_root, ".git" )
			return unless File.directory?( git_dir )

			info_dir = File.join( git_dir, "info" )
			exclude_path = File.join( info_dir, "exclude" )

			FileUtils.mkdir_p( info_dir )
			existing = File.exist?( exclude_path ) ? File.read( exclude_path ) : ""
			return if existing.lines.any? { |line| line.strip == ".claude/" }

			File.open( exclude_path, "a" ) { |file| file.puts ".claude/" }
		rescue StandardError
			# Best-effort — do not block worktree creation if exclude fails.
		end
		private_class_method :ensure_claude_dir_excluded!

			# Instance-level realpath helper for query methods.
			def realpath_safe( a_path )
				return runtime.realpath_safe( a_path ) if runtime

				File.realpath( a_path )
			rescue Errno::ENOENT
				File.expand_path( a_path )
			end
		end
end
