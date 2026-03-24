# The shipping document filed with the bureau (GitHub PR).
#
# A waybill is a data object — it records findings and answers questions.
# It does not fetch, file, or accept anything. The warehouse handles all
# bureau interaction and writes findings onto the waybill.
#
# The waybill has a tracking number (PR number), a label (branch name),
# and records the bureau's response (cleared/held/accepted/rejected).
# ci_diagnostic preserves the first line of stderr when CI checks fail.

module Carson
	# The shipping document filed with the bureau (GitHub PR). Has a
	# tracking number, records the bureaucrats' response (cleared/held/
	# accepted/rejected). A data object — state is written onto it by
	# the warehouse, never fetched by the waybill itself.
	class Waybill
		attr_reader :tracking_number, :url, :label, :ci_diagnostic

		def initialize( label:, tracking_number: nil, url: nil )
			@label = label
			@tracking_number = tracking_number
			@url = url
			@state = nil
			@ci = nil
			@ci_diagnostic = nil
			@verdict = nil
		end

		# --- Filing ---

		# Has the waybill been filed with the bureau?
		def filed?
			!tracking_number.nil?
		end

		# Generate a title from the label. Class method so the warehouse
		# can compute the title before creating the waybill.
		def self.default_title_for( label )
			label.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) do |character|
				character.upcase
			end
		end

		# Instance convenience — delegates to the class method.
		def default_title
			self.class.default_title_for( label )
		end

		# --- Recorded state ---

		# Record findings from a bureau check onto the waybill.
		# Called by the warehouse after querying the bureau.
		def record( state:, ci:, ci_diagnostic: nil )
			@state = state
			@ci = ci
			@ci_diagnostic = ci_diagnostic
		end

		# Stamp the waybill with a verdict.
		# Called by the warehouse after registering the parcel at the bureau.
		def stamp( verdict )
			@verdict = verdict
		end

		# --- Bureau's response queries ---

		# Has the bureau accepted the parcel into the registry?
		# True when stamped :accepted OR when the recorded state shows MERGED.
		def accepted?
			@verdict == :accepted || @state&.dig( "state" ) == "MERGED"
		end

		# Has the bureau rejected the waybill (closed without merge)?
		def rejected?
			@verdict == :rejected || @state&.dig( "state" ) == "CLOSED"
		end

		# Is the waybill still a draft?
		def draft?
			@state&.dig( "isDraft" ) || false
		end

		# Has the bureau cleared the parcel for delivery?
		# All bureaucrats pass, no merge blocks, merge state is clean.
		def cleared?
			return false unless filed?
			return false if draft?
			return false unless @ci == :pass || @ci == :none
			return false if merge_conflicting? || merge_behind? || merge_policy_blocked?
			merge_status = @state&.dig( "mergeStateStatus" ).to_s.upcase
			mergeable = @state&.dig( "mergeable" ).to_s.upcase
			merge_status == "CLEAN" || mergeable == "MERGEABLE"
		end

		# Is something blocking this waybill?
		def held?
			return false if cleared? || accepted? || rejected?
			filed?
		end

		# Why is the waybill being held? Code string for recovery step lookup.
		def hold_reason
			return "draft" if draft?
			return "pending_at_bureau" if @ci == :pending
			return "failed_at_bureau" if @ci == :fail
			return "error_at_bureau" if @ci == :error
			return "merge_conflict" if merge_conflicting?
			return "behind_bureau" if merge_behind?
			return "policy_block" if merge_policy_blocked?
			"mergeability_pending"
		end

		# Client-language summary of why the waybill is held.
		# Agents read this directly — no translation layer needed.
		def hold_summary( remote_main: "github/main" )
			case hold_reason
			when "draft" then "PR is still a draft."
			when "pending_at_bureau" then "Waiting for CI checks."
			when "failed_at_bureau" then "CI checks failed."
			when "error_at_bureau" then "Unable to assess CI checks."
			when "merge_conflict" then "Merge conflict with #{remote_main}."
			when "behind_bureau" then "Branch is behind #{remote_main}."
			when "policy_block" then "Blocked by branch protection rules."
			when "mergeability_pending" then "GitHub is calculating mergeability."
			else "Waiting for merge readiness."
			end
		end

		# Is the hold specifically because mergeability is still pending?
		def mergeability_pending?
			hold_reason == "mergeability_pending"
		end

		# --- Observation data for delivery records ---

		# Returns a hash of the bureau's current state for tracking records.
		def to_observation
			return {} unless @state.is_a?( Hash )

			{
				pull_request_state: @state[ "state" ],
				pull_request_draft: @state[ "isDraft" ],
				pull_request_merged_at: @state[ "mergedAt" ]
			}
		end

	private

		def merge_conflicting?
			status = @state&.dig( "mergeStateStatus" ).to_s.upcase
			mergeable = @state&.dig( "mergeable" ).to_s.upcase
			mergeable == "CONFLICTING" || status == "DIRTY" || status == "CONFLICTING"
		end

		def merge_behind?
			@state&.dig( "mergeStateStatus" ).to_s.upcase == "BEHIND"
		end

		def merge_policy_blocked?
			@state&.dig( "mergeStateStatus" ).to_s.upcase == "BLOCKED"
		end
	end
end
