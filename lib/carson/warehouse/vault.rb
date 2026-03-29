# The vault — where the production standard lives.
# The vault is local main. It is the source of truth.
# Accepted parcels live here permanently.
require "open3"

module Carson
	class Warehouse
		class Vault
			attr_reader :main_label

			def initialize( path:, main_label: )
				@path = path
				@main_label = main_label
			end

			# Accept a parcel into the vault.
			# Fast-forwards the standard to include the parcel's branch.
			#
			# Precondition: the parcel's branch must be a fast-forward of main.
			# If not, the agent must rebase first.
			def accept!( parcel )
				unless main_checked_out?
					return {
						status: "error",
						error: "#{@main_label} is not checked out in the main worktree.",
						recovery: "Check the main worktree state at #{@path}."
					}
				end

				_, stderr, status = Open3.capture3(
					"git", "-C", @path, "merge", "--ff-only", parcel.label
				)

				return accepted( parcel ) if status.success?

				blocked( parcel, stderr )
			end

			# Has this label's content been absorbed into the vault?
			# Content-aware — compares tree content, not SHA ancestry.
			# Catches rebase-merged and squash-merged branches that
			# ancestry-based checks miss (replayed SHAs differ).
			def absorbed?( label )
				_, _, status = Open3.capture3(
					"git", "diff", "--quiet", @main_label, label,
					chdir: @path
				)
				status.success?
			end

		private

			# Is main checked out in the vault's worktree?
			def main_checked_out?
				head_ref, _, status = Open3.capture3(
					"git", "-C", @path, "rev-parse", "--abbrev-ref", "HEAD"
				)
				status.success? && head_ref.strip == @main_label
			end

			# Build the success result after acceptance.
			def accepted( parcel )
				new_head, = Open3.capture3( "git", "-C", @path, "rev-parse", "HEAD" )
				{
					status: "ok",
					branch: parcel.label,
					head: new_head.strip
				}
			end

			# Build the blocked result when acceptance fails.
			# Distinguishes dirty-tree conflicts from diverged-history blocks
			# so the agent gets the correct recovery advice.
			def blocked( parcel, stderr )
				if stderr.to_s.include?( "would be overwritten" )
					{
						status: "block",
						error: "Main worktree has uncommitted changes that conflict with #{parcel.label}.",
						recovery: "Commit or discard the dirty files in the main worktree, then deliver again."
					}
				else
					{
						status: "block",
						error: "#{parcel.label} cannot be fast-forwarded into #{@main_label}.",
						recovery: "Rebase onto #{@main_label} and deliver again."
					}
				end
			end
		end
	end
end
