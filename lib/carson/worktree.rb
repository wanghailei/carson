# Domain object representing a single git worktree entry.
# Owns its path, branch, and operating context (runtime).
# Answers state queries (CWD containment, process holds) and
# owns the full lifecycle: create, remove, list, sweep.
# Runtime provides infrastructure — git, config, output —
# the way ActiveRecord models hold a database connection.
require "fileutils"
require "json"
require "open3"
require "pathname"

module Carson
	class Worktree
		# Agent directory names whose worktrees Carson may sweep.
		AGENT_DIRS = %w[ .claude .codex ].freeze

		attr_reader :path, :branch, :prunable_reason

		def initialize( path:, branch:, runtime: nil, prunable_reason: nil )
			@path = path
			@branch = branch
			@runtime = runtime
			@prunable_reason = prunable_reason
		end

		# --- Class lifecycle methods ---

		# Parses `git worktree list --porcelain` into Worktree instances.
		# Normalises paths with realpath so comparisons work across symlink differences.
		def self.list( runtime: )
			raw = runtime.git_capture!( "worktree", "list", "--porcelain" )
			entries = []
			current_path = nil
			current_branch = :unset
			current_prunable_reason = nil
			raw.lines.each do |line|
				line = line.strip
				if line.empty?
					entries << new(
						path: current_path,
						branch: current_branch == :unset ? nil : current_branch,
						runtime: runtime,
						prunable_reason: current_prunable_reason
					) if current_path
					current_path = nil
					current_branch = :unset
					current_prunable_reason = nil
				elsif line.start_with?( "worktree " )
					current_path = runtime.realpath_safe( line.sub( "worktree ", "" ) )
				elsif line.start_with?( "branch " )
					current_branch = line.sub( "branch refs/heads/", "" )
				elsif line == "detached"
					current_branch = nil
				elsif line.start_with?( "prunable" )
					reason = line.sub( "prunable", "" ).strip
					current_prunable_reason = reason.empty? ? "prunable" : reason
				end
			end
			entries << new(
				path: current_path,
				branch: current_branch == :unset ? nil : current_branch,
				runtime: runtime,
				prunable_reason: current_prunable_reason
			) if current_path
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

			# Fetch to update the remote tracking ref without mutating the main worktree.
			# Best-effort — if fetch fails (no remote, offline), branch from local main.
			main_root = runtime.main_worktree_root
			remote = runtime.config.git_remote
			_, _, fetch_ok, = Open3.capture3( "git", "-C", main_root, "fetch", remote, base )
			if fetch_ok.success?
				remote_ref = "#{remote}/#{base}"
				_, _, ref_ok, = Open3.capture3( "git", "-C", main_root, "rev-parse", "--verify", remote_ref )
				if ref_ok.success?
					base = remote_ref
					runtime.puts_verbose( "branching from #{remote_ref}" ) unless json_output
				else
					runtime.puts_verbose( "fetch succeeded but #{remote_ref} not found — branching from local #{runtime.config.main_branch}" ) unless json_output
				end
			else
				runtime.puts_verbose( "fetch skipped — branching from local #{runtime.config.main_branch}" ) unless json_output
			end

			# Ensure .claude/ is excluded from git status in the host repository.
			# Uses .git/info/exclude (local-only, never committed) to respect the outsider boundary.
			ensure_claude_dir_excluded!( runtime: runtime )

			# Create the worktree with a new branch based on the main branch.
			FileUtils.mkdir_p( File.dirname( worktree_path ) )
			worktree_stdout, worktree_stderr, worktree_success, = runtime.git_run( "worktree", "add", worktree_path, "-b", name, base )
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
				diagnostics = gather_create_diagnostics(
					git_stdout: worktree_stdout, git_stderr: worktree_stderr,
					name: name, runtime: runtime
				)
				cleanup_partial_create!( path: worktree_path, branch: name, runtime: runtime )
				return finish(
					result: { command: "worktree create", status: "error", name: name, path: worktree_path, branch: name,
						error: "git reported success but Carson could not verify the worktree and branch",
						recovery: "git worktree list --porcelain && git branch --list '#{name}'",
						diagnostics: diagnostics },
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
		def self.remove!( path:, runtime:, force: false, skip_unpushed: false, json_output: false )
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

			check = remove_check( path: path, runtime: runtime, force: force, skip_unpushed: skip_unpushed )
			unless check.fetch( :status ) == :ok
				return finish(
					result: { command: "worktree remove", status: check.fetch( :result_status ), name: File.basename( check.fetch( :resolved_path ) ),
						branch: check.fetch( :branch, nil ),
						error: check.fetch( :error ),
						recovery: check.fetch( :recovery, nil ) },
					exit_code: check.fetch( :exit_code ), runtime: runtime, json_output: json_output
				)
			end

			resolved_path = check.fetch( :resolved_path )
			branch = check.fetch( :branch )

			# Missing directory: worktree was destroyed externally (e.g. gh pr merge
			# --delete-branch). Clean up the stale git registration and delete the branch.
			if check.fetch( :missing )
				return remove_missing!( resolved_path: resolved_path, runtime: runtime, json_output: json_output )
			end

			runtime.puts_verbose "worktree_remove: path=#{resolved_path} branch=#{branch} force=#{force}"

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

		# Preflight guard for worktree removal. Shared by `worktree remove` and
		# other runtime flows that need to know whether cleanup is safe before
		# mutating GitHub or branch state.
		def self.remove_check( path:, runtime:, force: false, skip_unpushed: false )
			resolved_path = resolve_path( path: path, runtime: runtime )

			if !Dir.exist?( resolved_path ) && registered?( path: resolved_path, runtime: runtime )
				entry = find( path: resolved_path, runtime: runtime )
				return { status: :ok, resolved_path: resolved_path, branch: entry&.branch, missing: true }
			end

			unless registered?( path: resolved_path, runtime: runtime )
				return {
					status: :error,
					result_status: "error",
					exit_code: Runtime::EXIT_ERROR,
					resolved_path: resolved_path,
					branch: nil,
					error: "#{resolved_path} is not a registered worktree",
					recovery: "git worktree list"
				}
			end

			entry = find( path: resolved_path, runtime: runtime )
			branch = entry&.branch

			if entry&.holds_cwd?
				safe_root = runtime.main_worktree_root
				return {
					status: :block,
					result_status: "block",
					exit_code: Runtime::EXIT_BLOCK,
					resolved_path: resolved_path,
					branch: branch,
					error: "current working directory is inside this worktree",
					recovery: "cd #{safe_root} && carson checkout #{File.basename( resolved_path )}"
				}
			end

			if entry&.held_by_other_process?
				return {
					status: :block,
					result_status: "block",
					exit_code: Runtime::EXIT_BLOCK,
					resolved_path: resolved_path,
					branch: branch,
					error: "another process has its working directory inside this worktree",
					recovery: "wait for the other session to finish, then retry"
				}
			end

			if !force && entry&.dirty?
				return {
					status: :error,
					result_status: "error",
					exit_code: Runtime::EXIT_ERROR,
					resolved_path: resolved_path,
					branch: branch,
					error: "worktree has uncommitted changes",
					recovery: "commit or discard changes first, or use --force to override"
				}
			end

			unless force || skip_unpushed
				unpushed = branch_unpushed_issue( branch: branch, worktree_path: resolved_path, runtime: runtime )
				if unpushed
					return {
						status: :block,
						result_status: "block",
						exit_code: Runtime::EXIT_BLOCK,
						resolved_path: resolved_path,
						branch: branch,
						error: unpushed.fetch( :error ),
						recovery: unpushed.fetch( :recovery )
					}
				end
			end

			{ status: :ok, resolved_path: resolved_path, branch: branch, missing: false }
		end

		# Removes agent-owned worktrees that the shared cleanup classifier judges
		# safe to reap. Scans AGENT_DIRS (e.g. .claude/worktrees/, .codex/worktrees/)
		# under the main repo root.
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

				classification = runtime.send( :classify_worktree_cleanup, worktree: worktree )
				next unless classification.fetch( :action ) == :reap

				unless worktree.exists?
					remove_missing!( resolved_path: worktree.path, runtime: runtime, json_output: false )
					next
				end

				# Remove the worktree (no --force: automatic sweep never force-removes dirty worktrees).
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

		def exists?
			Dir.exist?( path )
		end

		def prunable?
			!prunable_reason.to_s.strip.empty?
		end

		def dirty?
			return false unless exists?

			stdout, = Open3.capture3( "git", "status", "--porcelain", chdir: path )
			!stdout.to_s.strip.empty?
		rescue StandardError
			false
		end

		# Is the workbench surface clean? (no uncommitted changes)
		def clean?
			return false unless exists?

			stdout, = Open3.capture3( "git", "status", "--porcelain", chdir: path )
			stdout.to_s.strip.empty?
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
			entry = find( path: path, runtime: runtime )
			return false if entry.nil?
			return false if entry.prunable?
			return false unless Dir.exist?( path )

			branch_exists?( branch: branch, runtime: runtime )
		end
		private_class_method :creation_verified?

		def self.branch_exists?( branch:, runtime: )
			_, _, success, = runtime.git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{branch}" )
			success
		end
		private_class_method :branch_exists?

		# Removes partial state left behind when git worktree add reports success
		# but verification reveals the worktree or branch is incomplete.
		def self.cleanup_partial_create!( path:, branch:, runtime: )
			FileUtils.rm_rf( path ) if Dir.exist?( path )
			runtime.git_run( "worktree", "prune" )
			runtime.git_run( "branch", "-D", branch ) if branch_exists?( branch: branch, runtime: runtime )
		end
		private_class_method :cleanup_partial_create!

		# Captures diagnostic state for a verification failure so the next
		# incident is self-diagnosing without manual investigation.
		def self.gather_create_diagnostics( git_stdout:, git_stderr:, name:, runtime: )
			wt_list, = runtime.git_run( "worktree", "list", "--porcelain" )
			branch_list, = runtime.git_run( "branch", "--list", name )
			git_version, = Open3.capture3( "git", "--version" )
			worktree_path = File.join( runtime.main_worktree_root, ".claude", "worktrees", name )
			entry = find( path: worktree_path, runtime: runtime )
			{
				git_stdout: git_stdout.to_s.strip,
				git_stderr: git_stderr.to_s.strip,
				repo_root: runtime.send( :repo_root ),
				main_worktree_root: runtime.main_worktree_root,
				worktree_list: wt_list.to_s.strip,
				branch_list: branch_list.to_s.strip,
				git_version: git_version.to_s.strip,
				worktree_directory_exists: Dir.exist?( worktree_path ),
				registered_worktree: !entry.nil?,
				prunable_reason: entry&.prunable_reason
			}
		end
		private_class_method :gather_create_diagnostics


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
		def self.branch_unpushed_issue( branch:, worktree_path:, runtime: )
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

		# Resolves a worktree path: if it's a bare name, first tries the flat
		# .claude/worktrees/<name> convention; if that isn't registered, searches
		# all registered worktrees for one whose directory name matches.
		# This handles worktrees created by external tools (e.g. Claude Code) that
		# nest under a subdirectory like .claude/worktrees/claude/<name>.
		# Returns the canonical (realpath) form so comparisons against git worktree list
		# succeed, even when the OS resolves symlinks differently.
		# Uses main_worktree_root (not repo_root) so resolution works from inside worktrees.
		def self.resolve_path( path:, runtime: )
			if Pathname.new( path ).absolute?
				return runtime.realpath_safe( path )
			end

			relative_candidate = runtime.realpath_safe( File.expand_path( path, Dir.pwd ) )
			return relative_candidate if registered?( path: relative_candidate, runtime: runtime )

			if path.include?( "/" )
				scoped_candidate = runtime.realpath_safe( File.join( runtime.main_worktree_root, ".claude", "worktrees", path ) )
				return scoped_candidate if registered?( path: scoped_candidate, runtime: runtime )
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
