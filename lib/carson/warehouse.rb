# A governed repository. In the FedEx metaphor, the warehouse is where
# parcels (committed changes) are stored on shelves (worktrees) with
# labels (branches). Git commands are hidden inside — callers never
# see git terms.
require "open3"

module Carson
	# A governed repository — the warehouse where parcels are stored on
	# shelves (worktrees) with labels (branches). Wraps git operations
	# with story-language methods. An intelligent warehouse that manages
	# itself: packing parcels, checking compliance, and sweeping up.
	class Warehouse
		attr_reader :path

		def initialize( path:, main_label: "main", bureau_address: "github", compliance_checker: nil )
			@path = path
			@main_label = main_label
			@bureau_address = bureau_address
			@compliance_checker = compliance_checker
		end

		# --- What the warehouse knows ---

		# The label on the current shelf (branch name).
		def current_label
			git( "rev-parse", "--abbrev-ref", "HEAD" ).first.strip
		end

		# The tip of the parcel on the current shelf (commit SHA).
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
		# Returns a hash: { compliant: true/false, committed: true/false, error: nil/string }
		def submit_compliance!
			return { compliant: true, committed: false } unless @compliance_checker

			@compliance_checker.call( self )
		end

		# Update the warehouse's production standard — rebase onto latest registry state.
		# Called after the bureau refuses a parcel for being behind standard.
		# Returns true on success, false on failure.
		def rebase_on_latest_standard!( registry: "#{bureau_address}/#{main_label}" )
			_, _, status = git( "rebase", registry )
			status.success?
		end

		# Pack a parcel — stage all changes and commit.
		# Returns true on success, false on failure.
		def pack!( message: )
			git( "add", "-A" )
			_, _, status = git( "commit", "-m", message )
			status.success?
		end

		# Sync the warehouse's local main with the registry after a parcel is accepted.
		# Fast-forwards local main without switching branches.
		# Returns true on success, false on failure.
		def sync!( remote: bureau_address )
			_, _, status = Open3.capture3(
				"git", "-C", main_worktree_root,
				"fetch", remote, "#{main_label}:#{main_label}"
			)
			status.success?
		end

		# --- Inventory ---

		# All shelves (worktree paths).
		def shelves
			output, = git( "worktree", "list", "--porcelain" )
			output.lines
				.select { it.start_with?( "worktree " ) }
				.map { it.sub( "worktree ", "" ).strip }
		end

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

		# The main warehouse location — resolves correctly even from a side shelf.
		# Used by sync! and ledger recording to always reference the canonical path.
		def main_worktree_root
			git_common_dir, = git( "rev-parse", "--path-format=absolute", "--git-common-dir" )
			common = git_common_dir.strip
			# If it ends with /.git, the parent is the main worktree root.
			common.end_with?( "/.git" ) ? File.dirname( common ) : common
		end

	private

		# All git commands go through this single gateway.
		# Returns [stdout, stderr, status].
		def git( *arguments )
			Open3.capture3( "git", "-C", path, *arguments )
		end
	end
end
