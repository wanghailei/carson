# The shipping document filed with the bureau (GitHub PR).
#
# In the FedEx metaphor, the courier files a waybill with the bureau
# when shipping a parcel. The waybill has a tracking number (PR number),
# knows the bureau's response (CI, review, mergeability), and can ask
# the bureau to accept the parcel into the registry.
#
# The waybill uses gh CLI internally — that's a tool, not the domain.
require "json"
require "open3"

module Carson
	class Waybill
		attr_reader :tracking_number, :url, :label

		def initialize( label:, warehouse_path:, tracking_number: nil, url: nil, review_gate: nil )
			@label = label
			@warehouse_path = warehouse_path
			@tracking_number = tracking_number
			@url = url
			@review_gate = review_gate
			@state = nil
			@ci = nil
		end

		# --- Filing ---

		# Has the waybill been filed with the bureau?
		def filed?
			!tracking_number.nil?
		end

		# File the waybill with the bureau. Creates a PR on GitHub.
		def file!( title: nil, body_file: nil )
			filing_title = title || default_title
			arguments = [ "pr", "create", "--title", filing_title, "--head", label ]

			if body_file && File.exist?( body_file )
				arguments.push( "--body-file", body_file )
			else
				arguments.push( "--body", "" )
			end

			stdout, stderr, success, = gh( *arguments )
			if success
				@url = stdout.to_s.strip
				@tracking_number = @url.split( "/" ).last.to_i
				@tracking_number = nil if @tracking_number == 0
			end

			# If create failed or returned no number, try to find existing.
			find_existing! unless filed?
			self
		end

		# Generate a human-readable title from the label.
		def default_title
			label.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) do |character|
				character.upcase
			end
		end

		# --- Bureau's response ---

		# Check with the bureau for the latest on this waybill.
		def refresh!
			@state = fetch_state
			@ci = fetch_ci
			self
		end

		# Has the bureau accepted the parcel into the registry?
		def accepted?
			@state&.dig( "state" ) == "MERGED"
		end

		# Has the bureau rejected the waybill (closed without merge)?
		def rejected?
			@state&.dig( "state" ) == "CLOSED"
		end

		# Is the waybill still a draft?
		def draft?
			@state&.dig( "isDraft" ) || false
		end

		# Has the bureau cleared the parcel for delivery?
		# All inspectors pass, no merge blocks, merge state is clean.
		def cleared?
			return false unless filed?
			return false if draft?
			return false unless @ci == :pass
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

		# Why is the waybill being held?
		def hold_reason
			return "draft" if draft?
			return "inspector_pending" if @ci == :pending
			return "inspector_failed" if @ci == :fail
			return "inspector_error" if @ci == :error
			return "merge_conflict" if merge_conflicting?
			return "behind_registry" if merge_behind?
			return "policy_block" if merge_policy_blocked?
			"mergeability_pending"
		end

		# Human-readable explanation of why the waybill is held.
		def hold_summary
			case hold_reason
			when "draft" then "waybill is still a draft"
			when "inspector_pending" then "waiting for customs inspection"
			when "inspector_failed" then "customs inspection failed"
			when "inspector_error" then "unable to assess customs inspection"
			when "merge_conflict" then "parcel has conflicts with registry"
			when "behind_registry" then "parcel is behind the registry"
			when "policy_block" then "blocked by bureau policy"
			else "waiting for bureau assessment"
			end
		end

		# Is the hold specifically because mergeability is still pending?
		def mergeability_pending?
			hold_reason == "mergeability_pending"
		end

		# --- Acceptance ---

		# Ask the bureau to accept the parcel into the registry.
		# Updates own state after the attempt.
		def accept!( method: )
			gh( "pr", "merge", tracking_number.to_s, "--#{method}" )
			refresh!
			self
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

		# --- Test support ---

		# Stub the bureau's response for testing without gh CLI.
		def stub_bureau_response( state: nil, ci: nil )
			@state = state if state
			@ci = ci if ci
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

		def fetch_state
			stdout, _, success, = gh(
				"pr", "view", tracking_number.to_s,
				"--json", "number,state,isDraft,url,mergeStateStatus,mergeable,mergedAt"
			)
			return nil unless success

			JSON.parse( stdout )
		rescue JSON::ParserError
			nil
		end

		def fetch_ci
			stdout, _, success, = gh(
				"pr", "checks", tracking_number.to_s,
				"--json", "name,bucket"
			)
			return :error unless success

			checks = JSON.parse( stdout ) rescue []
			return :none if checks.empty?

			buckets = checks.map do |entry|
				entry[ "bucket" ].to_s.downcase
			end
			return :fail if buckets.include?( "fail" )
			return :pending if buckets.include?( "pending" )

			:pass
		end

		def find_existing!
			stdout, _, success, = gh(
				"pr", "view", label,
				"--json", "number,url,state"
			)
			if success
				data = JSON.parse( stdout ) rescue nil
				if data && data[ "number" ] && data[ "state" ] == "OPEN"
					@tracking_number = data[ "number" ]
					@url = data[ "url" ].to_s
				end
			end
		end

		# All gh commands go through this single gateway.
		def gh( *arguments )
			stdout, stderr, status = Open3.capture3( "gh", *arguments, chdir: @warehouse_path )
			[ stdout, stderr, status.success?, status.exitstatus ]
		end
	end
end
