# The warehouse's workbench concern.
# Builds, removes, sweeps, and inventories workbenches.
# Workbenches are passive objects — the warehouse acts on them.
require "fileutils"
require "open3"
require "pathname"

module Carson
	class Warehouse
		module Workbench

			# Agent directory names whose workbenches the warehouse may sweep.
			AGENT_DIRS = %w[ .claude .codex ].freeze

			# --- Inventory ---

			# All workbenches in this warehouse.
			# Parses the git worktree registry into Worktree instances.
			# Normalises paths with realpath so comparisons work across symlinks.
			def workbenches
				raw, = git( "worktree", "list", "--porcelain" )
				entries = []
				current_path = nil
				current_branch = :unset
				current_prunable_reason = nil

				raw.lines.each do |line|
					line = line.strip
					if line.empty?
						entries << Carson::Worktree.new(
							path: current_path,
							branch: current_branch == :unset ? nil : current_branch,
							prunable_reason: current_prunable_reason
						) if current_path
						current_path = nil
						current_branch = :unset
						current_prunable_reason = nil
					elsif line.start_with?( "worktree " )
						current_path = realpath_safe( line.sub( "worktree ", "" ) )
					elsif line.start_with?( "branch " )
						current_branch = line.sub( "branch refs/heads/", "" )
					elsif line == "detached"
						current_branch = nil
					elsif line.start_with?( "prunable" )
						reason = line.sub( "prunable", "" ).strip
						current_prunable_reason = reason.empty? ? "prunable" : reason
					end
				end

				# Handle the last entry (porcelain output may not end with a blank line).
				entries << Carson::Worktree.new(
					path: current_path,
					branch: current_branch == :unset ? nil : current_branch,
					prunable_reason: current_prunable_reason
				) if current_path

				entries
			end

			# Find a workbench by canonical path.
			def workbench_at( path: )
				canonical = realpath_safe( path )
				workbenches.find { |wb| wb.path == canonical }
			end

			# Resolve a bare name and find the workbench.
			# Tries .claude/worktrees/<name> first, then searches all registered
			# workbenches by directory name.
			def workbench_named( name )
				if Pathname.new( name ).absolute?
					return workbench_at( path: name )
				end

				# Try as a relative path from CWD.
				relative_candidate = realpath_safe( File.expand_path( name, Dir.pwd ) )
				found = workbench_at( path: relative_candidate )
				return found if found

				# Try scoped path (e.g. "claude/foo" → .claude/worktrees/claude/foo).
				if name.include?( "/" )
					scoped_candidate = realpath_safe( File.join( main_worktree_root, ".claude", "worktrees", name ) )
					found = workbench_at( path: scoped_candidate )
					return found if found
				end

				# Try flat layout: .claude/worktrees/<name>.
				root = main_worktree_root
				candidate = realpath_safe( File.join( root, ".claude", "worktrees", name ) )
				found = workbench_at( path: candidate )
				return found if found

				# Search all registered workbenches by dirname.
				matches = workbenches.select { |wb| File.basename( wb.path ) == name }
				return matches.first if matches.size == 1

				nil
			end

			# Is this path a registered workbench?
			def workbench_registered?( path: )
				canonical = realpath_safe( path )
				workbenches.any? { |wb| wb.path == canonical }
			end

			# --- Lifecycle ---

			# Build a new workbench from local main.
			# Creates the directory, branches from the local standard,
			# ensures .claude/ is excluded from git status.
			def build_workbench!( name: )
				root = main_worktree_root
				worktrees_dir = File.join( root, ".claude", "worktrees" )
				workbench_path = File.join( worktrees_dir, name )

				if Dir.exist?( workbench_path )
					return { command: "worktree create", status: "error", name: name,
						path: workbench_path,
						error: "worktree already exists: #{name}",
						recovery: "carson worktree remove #{name}, then retry" }
				end

				# Ensure .claude/ is excluded from git status.
				ensure_claude_dir_excluded!

				# Create the worktree with a new branch.
				FileUtils.mkdir_p( File.dirname( workbench_path ) )
				wt_stdout, wt_stderr, wt_status = git( "worktree", "add", workbench_path, "-b", name, @main_label )
				unless wt_status.success?
					error_text = wt_stderr.to_s.strip
					error_text = "unable to create worktree" if error_text.empty?
					return { command: "worktree create", status: "error", name: name,
						error: error_text }
				end

				# Verify the build succeeded.
				unless workbench_creation_verified?( path: workbench_path, branch: name )
					diagnostics = gather_build_diagnostics(
						git_stdout: wt_stdout, git_stderr: wt_stderr, name: name )
					cleanup_partial_build!( path: workbench_path, branch: name )
					return { command: "worktree create", status: "error", name: name,
						path: workbench_path, branch: name,
						error: "git reported success but Carson could not verify the worktree and branch",
						recovery: "git worktree list --porcelain && git branch --list '#{name}'",
						diagnostics: diagnostics }
				end

				{ command: "worktree create", status: "ok", name: name,
					path: workbench_path, branch: name }
			end

			# Agent checks in — prepare a fresh workbench from local main.
			# Sweeps delivered workbenches first — the Warehouse cleans behind the agent.
			def checkin!( name: )
				sweep!
				result = build_workbench!( name: name )
				result[ :command ] = "checkin"
				result
			end

			# Agent checks out — release the workbench when safe.
			# A sealed workbench has a parcel in flight at the Bureau.
			def checkout!( workbench, force: false )
				unless force
					seal_check = Warehouse.new( path: workbench.path )
					if seal_check.sealed?
						tracking = seal_check.sealed_tracking_number || "unknown"
						return { command: "checkout", status: "block",
							name: File.basename( workbench.path ), branch: workbench.branch,
							error: "workbench is sealed — PR ##{tracking} is still in flight",
							recovery: "wait for CI checks to complete, or run carson deliver to check status" }
					end
				end

				result = remove_workbench!( workbench, force: force )
				result[ :command ] = "checkout"
				result
			end

			# Remove a workbench — directory, registration, local branch.
			# The warehouse checks safety before acting.
			# Remote branch cleanup is GitHub's concern, not the warehouse's.
			def remove_workbench!( workbench, force: false, skip_unpushed: false )
				# If the directory is already gone, repair the stale registration.
				unless workbench.exists?
					return repair_missing_workbench!( workbench )
				end

				# Safety assessment.
				assessment = assess_removal( workbench, force: force, skip_unpushed: skip_unpushed )
				unless assessment[ :status ] == :ok
					return { command: "worktree remove", status: assessment[ :result_status ] || "error",
						name: File.basename( workbench.path ), branch: workbench.branch,
						error: assessment[ :error ], recovery: assessment[ :recovery ] }
				end

				# Step 1: remove the worktree (directory + git registration).
				rm_args = [ "worktree", "remove" ]
				rm_args << "--force" if force
				rm_args << workbench.path
				_, rm_stderr, rm_status = git( *rm_args )
				unless rm_status.success?
					error_text = rm_stderr.to_s.strip
					error_text = "unable to remove worktree" if error_text.empty?
					if !force && ( error_text.downcase.include?( "untracked" ) || error_text.downcase.include?( "modified" ) )
						return { command: "worktree remove", status: "error",
							name: File.basename( workbench.path ),
							error: "worktree has uncommitted changes",
							recovery: "commit or discard changes first, or use --force to override" }
					end
					return { command: "worktree remove", status: "error",
						name: File.basename( workbench.path ), error: error_text }
				end

				# Step 2: delete the local branch.
				branch = workbench.branch
				branch_deleted = false
				if branch
					_, _, del_ok = git( "branch", "-D", branch )
					branch_deleted = del_ok.success?
				end

				{ command: "worktree remove", status: "ok",
					name: File.basename( workbench.path ),
					branch: branch, branch_deleted: branch_deleted }
			end

			# Full safety assessment before removal.
			# Asks the workbench about its own state — no duplicate checks.
			# Returns { status: :ok } or { status: :block/:error, error:, recovery: }.
			def assess_removal( workbench, force: false, skip_unpushed: false )
				unless workbench.exists?
					return { status: :ok, missing: true }
				end

				if workbench.holds_cwd?
					return { status: :block, result_status: "block",
						error: "current working directory is inside this worktree",
						recovery: "cd #{main_worktree_root} && carson checkout #{File.basename( workbench.path )}" }
				end

				if workbench.held_by_other_process?
					return { status: :block, result_status: "block",
						error: "another process has its working directory inside this worktree",
						recovery: "wait for the other session to finish, then retry" }
				end

				if !force && !workbench.clean?
					return { status: :error, result_status: "error",
						error: "worktree has uncommitted changes",
						recovery: "commit or discard changes first, or use --force to override" }
				end

				unless force || skip_unpushed
					unpushed = workbench_has_unpushed_work?( workbench )
					return unpushed if unpushed
				end

				{ status: :ok, missing: false }
			end

			# The warehouse sweeps — autonomous housekeeping.
			# Walks all agent-owned workbenches. Asks each one about its state.
			# If the label has been absorbed into the vault, and the workbench
			# isn't sealed or occupied — safe to remove, tears it down.
			# Repairs missing ones.
			def sweep!
				root = main_worktree_root

				agent_prefixes = AGENT_DIRS.map do |dir|
					full = File.join( root, dir, "worktrees" )
					File.join( realpath_safe( full ), "" ) if Dir.exist?( full )
				end.compact
				return if agent_prefixes.empty?

				workbenches.each do |workbench|
					next unless workbench.branch
					next unless agent_prefixes.any? { |prefix| workbench.path.start_with?( prefix ) }

					unless workbench.exists?
						repair_missing_workbench!( workbench )
						next
					end

					# Only sweep workbenches whose content has been absorbed into the vault.
					next unless absorbed?( workbench.branch )

					# Ask the workbench about its own state — not occupied, not held.
					next if workbench.holds_cwd?
					next if workbench.held_by_other_process?

					# Do not sweep sealed workbenches — parcel still in flight.
					seal_check = Warehouse.new( path: workbench.path )
					next if seal_check.sealed?

					_, _, rm_ok = git( "worktree", "remove", workbench.path )
					next unless rm_ok.success?

					git( "branch", "-D", workbench.branch ) if workbench.branch
				end
			end

		private

			# Would tearing down lose unpushed work?
			# Content-aware: compares tree content vs main, not SHAs.
			# Returns nil if safe, or { status:, error:, recovery: } if blocked.
			def workbench_has_unpushed_work?( workbench )
				branch = workbench.branch
				return nil unless branch

				remote_ref = "#{@bureau_address}/#{branch}"
				ahead, _, ahead_status = Open3.capture3(
					"git", "rev-list", "--count", "#{remote_ref}..#{branch}",
					chdir: workbench.path )

				if !ahead_status.success?
					# Remote ref missing. Only block if branch has unique commits vs main.
					unique, _, unique_status = Open3.capture3(
						"git", "rev-list", "--count", "#{@main_label}..#{branch}",
						chdir: workbench.path )
					if unique_status.success? && unique.strip.to_i > 0
						# Content-aware: if diff is empty, work is on main (squash/rebase merged).
						_, _, diff_ok = Open3.capture3(
							"git", "diff", "--quiet", @main_label, branch,
							chdir: workbench.path )
						unless diff_ok.success?
							return { status: :block, result_status: "block",
								error: "branch has not been pushed to #{@bureau_address}",
								recovery: "git -C #{workbench.path} push -u #{@bureau_address} #{branch}, or use --force to override" }
						end
					end
				elsif ahead.strip.to_i > 0
					return { status: :block, result_status: "block",
						error: "worktree has unpushed commits",
						recovery: "git -C #{workbench.path} push #{@bureau_address} #{branch}, or use --force to override" }
				end

				nil
			end

			# --- Repair ---

			# Handle a missing workbench — prune stale registration, clean up label.
			def repair_missing_workbench!( workbench )
				branch = workbench.branch
				git( "worktree", "prune" )

				branch_deleted = false
				if branch
					_, _, del_ok = git( "branch", "-D", branch )
					branch_deleted = del_ok.success?
				end

				{ command: "worktree remove", status: "ok",
					name: File.basename( workbench.path ),
					branch: branch, branch_deleted: branch_deleted }
			end

			# --- Build helpers ---

			# Verify the workbench was created correctly.
			def workbench_creation_verified?( path:, branch: )
				entry = workbench_at( path: path )
				return false if entry.nil?
				return false if entry.prunable?
				return false unless Dir.exist?( path )

				_, _, success = git( "show-ref", "--verify", "--quiet", "refs/heads/#{branch}" )
				success.success?
			end

			# Clean up partial state from a failed build.
			def cleanup_partial_build!( path:, branch: )
				FileUtils.rm_rf( path ) if Dir.exist?( path )
				git( "worktree", "prune" )
				_, _, ref_ok = git( "show-ref", "--verify", "--quiet", "refs/heads/#{branch}" )
				git( "branch", "-D", branch ) if ref_ok.success?
			end

			# Capture diagnostic state for a build verification failure.
			def gather_build_diagnostics( git_stdout:, git_stderr:, name: )
				root = main_worktree_root
				wt_list, = git( "worktree", "list", "--porcelain" )
				branch_list, = git( "branch", "--list", name )
				git_version, = Open3.capture3( "git", "--version" )
				workbench_path = File.join( root, ".claude", "worktrees", name )
				entry = workbench_at( path: workbench_path )
				{
					git_stdout: git_stdout.to_s.strip,
					git_stderr: git_stderr.to_s.strip,
					main_worktree_root: root,
					worktree_list: wt_list.to_s.strip,
					branch_list: branch_list.to_s.strip,
					git_version: git_version.to_s.strip,
					worktree_directory_exists: Dir.exist?( workbench_path ),
					registered_worktree: !entry.nil?,
					prunable_reason: entry&.prunable_reason
				}
			end

			# Ensure .claude/ is in .git/info/exclude.
			def ensure_claude_dir_excluded!
				git_dir = File.join( main_worktree_root, ".git" )
				return unless File.directory?( git_dir )

				info_dir = File.join( git_dir, "info" )
				exclude_path = File.join( info_dir, "exclude" )

				FileUtils.mkdir_p( info_dir )
				existing = File.exist?( exclude_path ) ? File.read( exclude_path ) : ""
				return if existing.lines.any? { |line| line.strip == ".claude/" }

				File.open( exclude_path, "a" ) { |file| file.puts ".claude/" }
			rescue StandardError
				# Best-effort — do not block workbench creation.
			end

			# Resolve a path to its canonical form, tolerating non-existent paths.
			def realpath_safe( a_path )
				File.realpath( a_path )
			rescue Errno::ENOENT
				expanded = File.expand_path( a_path )
				missing_segments = []
				candidate = expanded

				until File.exist?( candidate ) || Dir.exist?( candidate )
					parent = File.dirname( candidate )
					break if parent == candidate
					missing_segments.unshift( File.basename( candidate ) )
					candidate = parent
				end

				base = if File.exist?( candidate ) || Dir.exist?( candidate )
					File.realpath( candidate )
				else
					candidate
				end

				missing_segments.empty? ? base : File.join( base, *missing_segments )
			end
		end
	end
end
