# The warehouse's vault concern.
# The vault is local main — where accepted parcels live.
# In local-centred workstyle, the vault is the source of truth.
# In remote-centred workstyle, the vault is the backup (receives
# the standard from the bureau's registry after acceptance).
require "open3"

module Carson
	class Warehouse
		module Vault

			# Accept a parcel into the vault.
			# Fast-forwards local main to include the parcel's branch.
			# Runs from the main worktree root where main is checked out.
			#
			# Precondition: the parcel's branch must be a fast-forward of main.
			# If not, the agent must rebase first.
			#
			# Returns a result hash:
			#   { status: "ok", branch: ..., head: ... }
			#   { status: "block", error: ..., recovery: ... }
			#   { status: "error", error: ..., recovery: ... }
			def accept!( parcel )
				root = main_worktree_root

				# Verify main is checked out in the main worktree.
				unless main_checked_out_at?( root )
					return {
						status: "error",
						error: "#{@main_label} is not checked out in the main worktree.",
						recovery: "Check the main worktree state at #{root}."
					}
				end

				# Fast-forward main to include the parcel's branch.
				_, stderr, status = Open3.capture3(
					"git", "-C", root, "merge", "--ff-only", parcel.label
				)

				return vault_accepted( parcel, root ) if status.success?

				vault_blocked( parcel, stderr )
			end

		private

			# Check whether main is the checked-out branch at a given path.
			def main_checked_out_at?( root )
				head_ref, _, status = Open3.capture3(
					"git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD"
				)
				status.success? && head_ref.strip == @main_label
			end

			# Build the success result after vault acceptance.
			def vault_accepted( parcel, root )
				new_head, = Open3.capture3( "git", "-C", root, "rev-parse", "HEAD" )
				{
					status: "ok",
					branch: parcel.label,
					head: new_head.strip
				}
			end

			# Build the blocked/error result when vault acceptance fails.
			def vault_blocked( parcel, stderr )
				{
					status: "block",
					error: "#{parcel.label} cannot be fast-forwarded into #{@main_label}.",
					recovery: "Rebase onto #{@main_label} and deliver again."
				}
			end

		end
	end
end
