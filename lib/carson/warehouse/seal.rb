# The warehouse's workbench seal concern.
# Once a parcel ships and the waybill is filed, the warehouse seals the
# workbench. No more packing until the delivery outcome is confirmed.
# The seal marker lives outside the worktree (~/.carson/seals/) so it
# does not pollute git status.
require "digest"
require "fileutils"

module Carson
	class Warehouse
		module Seal

			# Seal the workbench — no more packing until delivery outcome is confirmed.
			# The courier seals the workbench after shipping and filing the waybill.
			def seal_workbench!( tracking_number: )
				marker = delivering_marker_path
				FileUtils.mkdir_p( File.dirname( marker ) )
				File.write( marker, "#{tracking_number}\n#{@path}" )
			end

			# Unseal the workbench — the courier brought back the parcel.
			# Called when the delivery outcome is held or rejected.
			def unseal_workbench!
				File.delete( delivering_marker_path ) if File.exist?( delivering_marker_path )
			end

			# Is this workbench sealed for a delivery in flight?
			def sealed?
				File.exist?( delivering_marker_path )
			end

			# The tracking number of the in-flight delivery (nil if not sealed).
			def sealed_tracking_number
				return nil unless sealed?
				File.read( delivering_marker_path ).lines.first.strip
			end

			# --- Transitional aliases ---
			# Keep old names working until all callers are updated.
			alias seal_shelf! seal_workbench!
			alias unseal_shelf! unseal_workbench!

		private

			# Path to the delivery marker file.
			# Lives outside the worktree at ~/.carson/seals/<sha256-of-path>
			# so it does not pollute git status.
			def delivering_marker_path
				seals_dir = File.join( Dir.home, ".carson", "seals" )
				key = Digest::SHA256.hexdigest( @path )
				File.join( seals_dir, key )
			end
		end
	end
end
