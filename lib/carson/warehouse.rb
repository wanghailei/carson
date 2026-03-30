# A governed repository — the intelligent, self-managing building
# where parcels are built on workbenches. Each warehouse belongs
# to a client. The warehouse is the local authority — everything
# inside the repository is its domain.
#
# At the heart of the warehouse is the vault — where the production
# standard lives. The vault is the source of truth.
require "fileutils"
require "open3"

require_relative "warehouse/workbench"
require_relative "warehouse/vault"
require_relative "warehouse/seal"
require_relative "warehouse/bureau"

module Carson
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

		# --- The vault ---

		# The vault — where the production standard lives.
		def vault
			@vault ||= Vault.new( path: main_worktree_root, main_label: @main_label )
		end

		# Accept a parcel into the vault.
		def accept!( parcel )
			vault.accept!( parcel )
		end

		# Has this label been absorbed into the vault?
		def absorbed?( label )
			vault.absorbed?( label )
		end

		# --- What the warehouse knows ---

		# The label on the current workbench.
		def current_label
			git( "rev-parse", "--abbrev-ref", "HEAD" ).first.strip
		end

		# The tip of the parcel on the current workbench.
		def current_head
			git( "rev-parse", "HEAD" ).first.strip
		end

		# What the production standard is called.
		def main_label
			@main_label
		end

		# The bureau's address — where to send things.
		def bureau_address
			@bureau_address
		end

		# Is the floor clean? No loose material lying around.
		def clean?
			output, _, status = git( "status", "--porcelain" )
			status.success? && output.strip.empty?
		end

		# --- Warehouse operations ---

		# Ship a parcel to the backup so the courier can work with it.
		def ship( parcel, remote: bureau_address )
			_, _, status = git( "push", "-u", remote, parcel.label )
			status.success?
		end

		# Is this parcel based on the latest standard?
		# The standard is vault state — is the parcel built on top of it?
		def based_on_latest?( parcel )
			standard = "#{bureau_address}/#{main_label}"
			_, _, status = git( "merge-base", "--is-ancestor", standard, parcel.head )
			status.success?
		end

		# Submit compliance — ensure the warehouse meets company standards.
		def submit_compliance!
			return { compliant: true, committed: false } unless @compliance_checker

			@compliance_checker.call( self )
		end

		# Rebase a workbench onto the latest standard.
		# When a parcel falls behind the standard, the warehouse fixes it.
		def rebase!( standard: "#{bureau_address}/#{main_label}" )
			_, _, status = git( "rebase", standard )
			status.success?
		end

		# Pack a parcel — stage all loose material and seal it.
		# Refuses if the workbench is sealed — a parcel is already in flight.
		def pack!( message: )
			if sealed?
				raise "Branch is locked — PR ##{sealed_tracking_number} in flight. " \
					"Create a new worktree to continue working."
			end
			git( "add", "-A" )
			_, _, status = git( "commit", "-m", message )
			status.success?
		end

		# Receive the latest standard.
		# After a parcel is accepted, the standard has changed. The warehouse
		# updates its vault without disturbing the current workbench.
		#
		# Two paths depending on the vault's checkout state:
		# - Main checked out → merge --ff-only (updates ref + working tree).
		# - Main not checked out → fetch refspec (updates ref only).
		def receive_latest!( remote: bureau_address )
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

		# --- Delivery prep ---

		# Prepare a parcel for delivery.
		# Packs if the agent provided a message, checks if the parcel is based
		# on the latest standard, rebases automatically if it's behind.
		def prepare!( parcel, message: nil )
			standard = "#{bureau_address}/#{main_label}"

			if message
				unless pack!( message: message )
					return { status: "error", error: "Nothing to commit.", recovery: "Stage changes first." }
				end
				parcel = Parcel.new( label: parcel.label, head: current_head )
			end

			unless receive_latest!
				return {
					status: "block",
					error: "Cannot receive latest standard.",
					recovery: "Check network and remote config, then deliver again."
				}
			end

			unless based_on_latest?( parcel )
				unless rebase!( standard: standard )
					return {
						status: "block",
						error: "#{parcel.label} conflicts with #{@main_label}.",
						recovery: "Rebase onto #{@main_label}, resolve conflicts, deliver again."
					}
				end
				parcel = Parcel.new( label: parcel.label, head: current_head )
			end

			# Stamp the parcel with its origin so it knows whether it carries anything.
			origin, = git( "merge-base", main_label, parcel.label )
			parcel = Parcel.new( label: parcel.label, head: parcel.head, shelf: parcel.shelf, origin: origin.strip )

			if parcel.empty?
				return {
					status: "block",
					error: "Nothing to deliver — no commits ahead of #{main_label}.",
					recovery: "Commit changes, then carson deliver."
				}
			end

			{ status: "ok", parcel: parcel }
		end

		# --- Inventory ---

		# All labels in the warehouse.
		def labels
			output, = git( "branch", "--format", "%(refname:short)" )
			output.lines.map { it.strip }.reject { it.empty? }
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
