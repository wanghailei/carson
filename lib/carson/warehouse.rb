# A governed repository. In the FedEx metaphor, the warehouse is where
# parcels are built on workbenches (worktrees) with labels (branches).
# Git and gh commands are hidden inside — callers never see git or
# GitHub terms.
require "fileutils"
require "open3"

require_relative "warehouse/workbench"
require_relative "warehouse/seal"
require_relative "warehouse/bureau"

module Carson
	# A governed repository — the warehouse where parcels are built on
	# workbenches (worktrees) with labels (branches). An intelligent
	# warehouse that manages itself: packing parcels, checking compliance,
	# managing workbenches, and sweeping up.
	class Warehouse
		include Workbench
		include Seal
		include Bureau

		attr_reader :path

		def initialize( path:, main_label: "main", bureau_address: "github", compliance_checker: nil )
			@path = path
			@main_label = main_label
			@bureau_address = bureau_address
			@compliance_checker = compliance_checker
		end

		# --- What the warehouse knows ---

		# The label on the current workbench (branch name).
		def current_label
			git( "rev-parse", "--abbrev-ref", "HEAD" ).first.strip
		end

		# The tip of the parcel on the current workbench (commit SHA).
		def current_head
			git( "rev-parse", "HEAD" ).first.strip
		end

		# The destination label (from config).
		def main_label
			@main_label
		end

		# The bureau's address (remote name).
		def bureau_address
			@bureau_address
		end

		# Is the warehouse floor clean? No uncommitted changes on the current workbench.
		def clean?
			output, _, status = git( "status", "--porcelain" )
			status.success? && output.strip.empty?
		end

		# --- Warehouse operations ---

		# Ship a parcel to the bureau.
		# The warehouse sends the parcel's label to the remote.
		def ship( parcel, remote: bureau_address )
			_, _, status = git( "push", "-u", remote, parcel.label )
			status.success?
		end

		# Get latest registry state from the bureau (git fetch).
		# Returns true on success, false on failure.
		def fetch_latest( remote: bureau_address, registry: nil )
			arguments = [ "fetch", remote ]
			arguments << registry if registry
			_, _, status = git( *arguments )
			status.success?
		end

		# Is the parcel based on the client's latest production standard?
		# Checks whether the registry tip is an ancestor of the parcel's head.
		def based_on_latest_standard?( parcel, registry: "#{bureau_address}/#{main_label}" )
			_, _, status = git( "merge-base", "--is-ancestor", registry, parcel.head )
			status.success?
		end

		# Ensure the warehouse complies with company standards (template sync).
		# Delegates to the injected compliance checker. If no checker is set,
		# the warehouse assumes compliance — no templates to enforce.
		def submit_compliance!
			return { compliant: true, committed: false } unless @compliance_checker

			@compliance_checker.call( self )
		end

		# Update the warehouse's production standard — rebase onto latest registry state.
		# Called after the bureau refuses a parcel for being behind standard.
		def rebase_on_latest_standard!( registry: "#{bureau_address}/#{main_label}" )
			_, _, status = git( "rebase", registry )
			status.success?
		end

		# Pack a parcel — stage all changes and commit.
		# Refuses if the workbench is sealed (parcel already in flight).
		def pack!( message: )
			if sealed?
				raise "Branch is locked — PR ##{sealed_tracking_number} in flight. " \
					"Create a new worktree to continue working."
			end
			git( "add", "-A" )
			_, _, status = git( "commit", "-m", message )
			status.success?
		end

		# Receive the latest standard from the registry after a parcel is accepted.
		# Fast-forwards local main without switching branches.
		#
		# Two paths depending on the main worktree's checkout state:
		# - Main checked out → merge --ff-only (updates ref + working tree).
		# - Main not checked out → fetch refspec (updates ref only, safe when
		#   no worktree has the branch).
		def receive_latest_standard!( remote: bureau_address )
			root = main_worktree_root

			_, _, fetch_status = Open3.capture3( "git", "-C", root, "fetch", remote )
			return false unless fetch_status.success?

			head_ref, _, head_status = Open3.capture3(
				"git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"
			)
			return false unless head_status.success?

			if head_ref.strip == @main_label
				_, _, merge_status = Open3.capture3(
					"git", "-C", root, "merge", "--ff-only", "#{remote}/#{@main_label}"
				)
				merge_status.success?
			else
				_, _, refspec_status = Open3.capture3(
					"git", "-C", root, "fetch", remote, "#{@main_label}:#{@main_label}"
				)
				refspec_status.success?
			end
		end

		# --- Inventory ---

		# All labels (branch names).
		def labels
			output, = git( "branch", "--format", "%(refname:short)" )
			output.lines.map { it.strip }.reject { it.empty? }
		end

		# Has this label been merged into main?
		def label_absorbed?( name )
			merged_output, = git( "branch", "--merged", main_label, "--format", "%(refname:short)" )
			merged_output.lines.map { it.strip }.include?( name )
		end

		# All worktree paths (transitional — use workbenches for Worktree instances).
		def shelves
			output, = git( "worktree", "list", "--porcelain" )
			output.lines
				.select { it.start_with?( "worktree " ) }
				.map { it.sub( "worktree ", "" ).strip }
		end

		# The main warehouse location — resolves correctly even from a workbench.
		def main_worktree_root
			git_common_dir, = git( "rev-parse", "--path-format=absolute", "--git-common-dir" )
			common = git_common_dir.strip
			common.end_with?( "/.git" ) ? File.dirname( common ) : common
		end

	private

		# All git commands go through this single gateway.
		def git( *arguments )
			Open3.capture3( "git", "-C", path, *arguments )
		end

		# All gh commands go through this single gateway.
		def gh( *arguments )
			Open3.capture3( "gh", *arguments, chdir: path )
		end
	end
end
