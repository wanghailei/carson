# The delivery person — picks up parcels and delivers them to the registry.
#
# In the FedEx metaphor, the courier is a Carson employee assigned to
# a warehouse. They pick up a parcel, ship it to the bureau, file a
# waybill, wait at the customs window, and collect proof of delivery.
#
# The courier is a thin orchestrator: it creates a Waybill and sends it
# messages. The domain logic lives in the objects, not the courier.
#
# == Situations the courier encounters
#
# Each numbered situation is handled by a specific guard or branch in the
# delivery flow. The number appears in the code comment where it's handled.
#
#   01. Parcel on main — cannot deliver from the destination.
#   02. Parcel behind registry — parcel doesn't include latest registry state.
#   03. Shipping fails — warehouse couldn't push to the bureau.
#   04. Waybill filing fails — bureau rejected the paperwork.
#   05. Inspector pending — customs inspection (CI) still running.
#   06. Inspector fails — customs inspection (CI) failed.
#   07. Review officer pending — review still in progress.
#   08. Review changes requested — officer wants corrections.
#   09. Merge conflict — parcel has conflicts with registry contents.
#   10. Behind registry (post-filing) — registry advanced since shipping.
#   11. Policy block — bureau regulation prevents acceptance.
#   12. Draft waybill — form not finalised.
#   13. Mergeability pending — bureau still processing merge eligibility.
#   14. Acceptance succeeds — parcel enters the registry. Delivered.
#   15. Acceptance fails — classify why, retry or hold.
#   16. Bureau unreachable — cannot contact the bureau.
#   17. Parcel already delivered — already in registry.
#   18. Waybill closed — cancelled by someone externally.
#   19. Watch window expires — end of courier's shift. Deferred.
#
# == Future: destination modes
#
# Currently remote-centred (ship → waybill → bureau customs → registry).
# A future local-centred mode merges locally; remote is a synced backup.
# The destination mode should be injectable, not baked in.
module Carson
	class Courier
		OK = 0
		ERROR = 1
		BLOCKED = 2
		MERGE_ATTEMPT_CAP = 3

		def initialize( warehouse, output: $stdout, verbose: false )
			@warehouse = warehouse
			@output = output
			@verbose = verbose
		end

		# Deliver a parcel to the registry.
		# Ships it, files a waybill, waits for customs, requests acceptance.
		def deliver( parcel, title: nil, body_file: nil )
			result = { command: "deliver", label: parcel.label }

			# 01. Parcel on main — cannot deliver from the destination.
			if parcel.on_main?( warehouse.main_label )
				return blocked( result,
					"cannot deliver from #{warehouse.main_label}",
					recovery: "carson worktree create <name>" )
			end

			# 02. Parcel behind registry — must include latest registry state.
			warehouse.fetch_latest( registry: warehouse.main_label )
			unless warehouse.includes_latest?( parcel )
				return blocked( result,
					"parcel is behind #{warehouse.bureau_address}/#{warehouse.main_label}",
					recovery: "refresh this branch onto #{warehouse.bureau_address}/#{warehouse.main_label}, then carson deliver" )
			end

			# 03. Shipping fails — warehouse couldn't push to the bureau.
			unless warehouse.ship( parcel )
				return error( result, "shipping failed" )
			end

			# File a waybill with the bureau.
			waybill = Waybill.new(
				label: parcel.label,
				warehouse_path: warehouse.path
			)
			waybill.file!( title: title, body_file: body_file )

			# 04. Waybill filing fails — bureau rejected the paperwork.
			unless waybill.filed?
				return error( result, "waybill filing failed", recovery: "carson deliver" )
			end

			result[ :tracking_number ] = waybill.tracking_number
			result[ :url ] = waybill.url

			# Wait at the customs window.
			settle( waybill, result )

			result[ :exit ] ||= OK
			result
		end

	private

		attr_reader :warehouse

		# The courier waits at the customs window, checking periodically.
		# When the bureau clears the parcel, the courier requests acceptance.
		# Handles situations 05-19.
		def settle( waybill, result )
			started = Process.clock_gettime( Process::CLOCK_MONOTONIC )
			merge_attempts = 0
			watch_window = 30

			loop do
				waybill.refresh!

				# 14/17. Acceptance succeeds / parcel already delivered.
				if waybill.accepted?
					result[ :outcome ] = "delivered"
					return
				end

				# 18. Waybill closed — cancelled externally.
				if waybill.rejected?
					result[ :outcome ] = "rejected"
					result[ :exit ] = BLOCKED
					return
				end

				# 14. Cleared — request acceptance. Also attempt on 13 (mergeability pending).
				if waybill.cleared? || ( waybill.mergeability_pending? && merge_attempts < MERGE_ATTEMPT_CAP )
					waybill.accept!( method: merge_method )
					merge_attempts += 1
					# 15. Acceptance fails — loop continues to re-assess.
					next if waybill.accepted?
				end

				# 05-12. Held by a definite blocker — stop waiting.
				if waybill.held? && !waybill.mergeability_pending?
					result[ :outcome ] = "held"
					result[ :exit ] = BLOCKED
					result[ :hold_reason ] = waybill.hold_reason
					result[ :hold_summary ] = waybill.hold_summary
					return
				end

				# 19. Watch window expires — end of shift.
				elapsed = Process.clock_gettime( Process::CLOCK_MONOTONIC ) - started
				if elapsed >= watch_window
					result[ :outcome ] = "deferred"
					return
				end

				sleep poll_interval
			end
		end

		def merge_method
			"rebase"
		end

		def poll_interval
			5
		end

		def blocked( result, message, recovery: nil )
			result[ :exit ] = BLOCKED
			result[ :error ] = message
			result[ :recovery ] = recovery
			result
		end

		def error( result, message, recovery: nil )
			result[ :exit ] = ERROR
			result[ :error ] = message
			result[ :recovery ] = recovery
			result
		end
	end
end
