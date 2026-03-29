# The warehouse's seal concern — bureau enhancement only.
#
# The seal is inactive in the base (local-centred) model.
# There is no "in flight" period — the parcel goes directly
# into the vault.
#
# The seal only activates with bureau enhancement, where there's
# a waiting period between shipping and bureau acceptance. During
# that period, the workbench is sealed — no more packing until
# the delivery outcome is confirmed.
#
# The seal marker lives outside the worktree (~/.carson/seals/)
# so it does not pollute git status.
require "digest"
require "fileutils"

module Carson
	class Warehouse
		module Seal

			# Seal the workbench — no more packing until the bureau answers.
			def seal!( tracking: )
				marker = delivering_marker_path
				FileUtils.mkdir_p( File.dirname( marker ) )
				File.write( marker, "#{tracking}\n#{@path}" )
			end

			# Unseal the workbench — the courier brought back the parcel.
			def unseal!
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
