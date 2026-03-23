# The committed changes on a branch — the thing being delivered.
#
# In the FedEx metaphor, a parcel sits on a shelf (worktree) identified
# by a label (branch name). Agents put committed changes — the parcel —
# on a branch, then call Carson to deliver it.
#
# The parcel does not deliver itself. The courier does that.
# The parcel does not pack itself. The warehouse does that.
module Carson
	# The committed changes being delivered. Knows its label (branch),
	# head (commit SHA), and shelf (worktree). The protagonist of every
	# delivery — without a parcel, there is nothing to deliver.
	class Parcel
		attr_reader :label, :head, :shelf

		def initialize( label:, head:, shelf: nil )
			@label = label
			@head = head
			@shelf = shelf
		end

		# Is this parcel sitting on the main shelf?
		# The main shelf is the destination — you cannot deliver FROM the destination.
		def on_main?( main_label )
			label == main_label
		end
	end
end
