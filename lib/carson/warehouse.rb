# A governed repository. In the FedEx metaphor, the warehouse is where
# parcels (committed changes) are stored on shelves (worktrees) with
# labels (branches). Git and gh commands are hidden inside — callers
# never see git or GitHub terms.
require "digest"
require "fileutils"
require "json"
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

		# Is the warehouse floor clean? No uncommitted changes on the current shelf.
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
		# Refuses if the shelf is sealed (parcel already in flight).
		# Returns true on success, false on failure.
		def pack!( message: )
			if sealed?
				raise "Branch is locked — PR ##{sealed_tracking_number} in flight. " \
					"Create a new worktree to continue working."
			end
			git( "add", "-A" )
			_, _, status = git( "commit", "-m", message )
			status.success?
		end

		# --- Shelf seal ---

		# Seal the shelf — no more packing until the delivery outcome is confirmed.
		# The courier seals the shelf after shipping and filing the waybill.
		# The marker lives outside the worktree (~/.carson/seals/) so it does
		# not pollute git status or block delivery with a dirty-tree guard.
		def seal_shelf!( tracking_number: )
			marker = delivering_marker_path
			FileUtils.mkdir_p( File.dirname( marker ) )
			File.write( marker, "#{tracking_number}\n#{@path}" )
		end

		# Unseal the shelf — the courier brought back the parcel.
		# Called when the delivery outcome is held or rejected.
		def unseal_shelf!
			File.delete( delivering_marker_path ) if File.exist?( delivering_marker_path )
		end

		# Is this shelf sealed for a delivery in flight?
		def sealed?
			File.exist?( delivering_marker_path )
		end

		# The tracking number of the in-flight delivery (nil if not sealed).
		def sealed_tracking_number
			return nil unless sealed?
			File.read( delivering_marker_path ).lines.first.strip
		end

		# Receive the latest standard from the registry after a parcel is accepted.
		# Fast-forwards local main without switching branches.
		# Returns true on success, false on failure.
		#
		# Two paths depending on the main worktree's checkout state:
		# - Main checked out → merge --ff-only (updates ref + working tree).
		# - Main not checked out → fetch refspec (updates ref only, safe when
		#   no worktree has the branch).
		def receive_latest_standard!( remote: bureau_address )
			root = main_worktree_root

			# Fetch remote tracking refs — always safe, even when main is checked out.
			_, _, fetch_status = Open3.capture3( "git", "-C", root, "fetch", remote )
			return false unless fetch_status.success?

			# Determine how to advance local main.
			head_ref, _, head_status = Open3.capture3(
				"git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"
			)
			return false unless head_status.success?

			if head_ref.strip == @main_label
				# Main is checked out in the main worktree — fast-forward via merge.
				_, _, merge_status = Open3.capture3(
					"git", "-C", root, "merge", "--ff-only", "#{remote}/#{@main_label}"
				)
				merge_status.success?
			else
				# Main is not checked out — safe to update the ref via fetch refspec.
				_, _, refspec_status = Open3.capture3(
					"git", "-C", root, "fetch", remote, "#{@main_label}:#{@main_label}"
				)
				refspec_status.success?
			end
		end

		# --- Bureau interaction ---
		# The warehouse owns the connection to the bureau (GitHub).
		# It queries, files, and registers on behalf of the courier.

		# Check the parcel's status at the bureau using the waybill.
		# Calls gh pr view + gh pr checks. Records findings onto the waybill.
		def check_parcel_at_bureau_with( waybill )
			state = fetch_pr_state_for( waybill.tracking_number )
			ci, ci_diagnostic = fetch_ci_state_for( waybill.tracking_number )
			waybill.record( state: state, ci: ci, ci_diagnostic: ci_diagnostic )
		end

		# File a waybill at the bureau for this parcel.
		# Calls gh pr create. Returns a Waybill with tracking number, or nil on failure.
		def file_waybill_for!( parcel, title: nil, body_file: nil )
			filing_title = title || Waybill.default_title_for( parcel.label )
			arguments = [ "pr", "create", "--title", filing_title, "--head", parcel.label ]

			if body_file && File.exist?( body_file )
				arguments.push( "--body-file", body_file )
			else
				arguments.push( "--body", "" )
			end

			stdout, _, status = gh( *arguments )
			tracking_number = nil
			url = nil

			if status.success?
				url = stdout.to_s.strip
				tracking_number = url.split( "/" ).last.to_i
				tracking_number = nil if tracking_number == 0
			end

			# If create failed or returned no number, try to find an existing PR.
			unless tracking_number
				tracking_number, url = find_existing_waybill_for( parcel.label )
			end

			return nil unless tracking_number

			Waybill.new( label: parcel.label, tracking_number: tracking_number, url: url )
		end

		# Register the parcel at the bureau using the waybill.
		# Calls gh pr merge. Stamps the waybill on success.
		def register_parcel_at_bureau_with!( waybill, method: )
			_, _, status = gh( "pr", "merge", waybill.tracking_number.to_s, "--#{method}" )
			if status.success?
				waybill.stamp( :accepted )
			else
				# Re-check the state — the merge may have revealed a new blocker.
				check_parcel_at_bureau_with( waybill )
			end
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

		# Path to the delivery marker file — signals the shelf is sealed.
		# Lives outside the worktree at ~/.carson/seals/<sha256-of-path>
		# so it does not pollute git status.
		def delivering_marker_path
			seals_dir = File.join( Dir.home, ".carson", "seals" )
			key = Digest::SHA256.hexdigest( @path )
			File.join( seals_dir, key )
		end

		# All git commands go through this single gateway.
		# Returns [stdout, stderr, status].
		def git( *arguments )
			Open3.capture3( "git", "-C", path, *arguments )
		end

		# All gh commands go through this single gateway.
		# Returns [stdout, stderr, status].
		def gh( *arguments )
			Open3.capture3( "gh", *arguments, chdir: path )
		end

		# Fetch PR state from the bureau for a tracking number.
		# Returns the parsed state hash, or nil on failure.
		def fetch_pr_state_for( tracking_number )
			stdout, _, status = gh(
				"pr", "view", tracking_number.to_s,
				"--json", "number,state,isDraft,url,mergeStateStatus,mergeable,mergedAt"
			)
			return nil unless status.success?

			JSON.parse( stdout )
		rescue JSON::ParserError
			nil
		end

		# Fetch CI state from the bureau for a tracking number.
		# Returns [ci_symbol, diagnostic_or_nil].
		# Captures the first line of stderr as diagnostic when the command fails.
		def fetch_ci_state_for( tracking_number )
			stdout, stderr, status = gh(
				"pr", "checks", tracking_number.to_s,
				"--json", "name,bucket"
			)
			unless status.success?
				return [ :error, stderr.to_s.strip.lines.first&.strip ]
			end

			checks = JSON.parse( stdout ) rescue []
			return [ :none, nil ] if checks.empty?

			buckets = checks.map { it[ "bucket" ].to_s.downcase }
			return [ :fail, nil ] if buckets.include?( "fail" )
			return [ :pending, nil ] if buckets.include?( "pending" )

			[ :pass, nil ]
		end

		# Try to find an existing PR for this label at the bureau.
		# Returns [tracking_number, url] or [nil, nil].
		def find_existing_waybill_for( label )
			stdout, _, status = gh(
				"pr", "view", label,
				"--json", "number,url,state"
			)
			if status.success?
				data = JSON.parse( stdout ) rescue nil
				if data && data[ "number" ] && data[ "state" ] == "OPEN"
					return [ data[ "number" ], data[ "url" ].to_s ]
				end
			end
			[ nil, nil ]
		end
	end
end
