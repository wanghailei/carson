# The warehouse's bureau-facing concern.
# The warehouse owns the connection to the bureau (GitHub).
# It queries, files, and registers on behalf of the courier.
require "json"

module Carson
	class Warehouse
		module Bureau

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

		private

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
end
