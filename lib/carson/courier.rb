# The delivery person — picks up parcels and delivers them to the registry.
#
# In the FedEx metaphor, the courier is a Carson employee assigned to
# a warehouse. They pick up a parcel, ship it to the bureau, file a
# waybill, wait at the customs window, and collect proof of delivery.
#
# The courier is a thin orchestrator: it creates domain objects (Waybill,
# Delivery) and sends them messages. The logic lives in the objects.
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

			# Guard: cannot deliver from the destination.
			if parcel.on_main?( warehouse.main_label )
				return blocked( result,
					"cannot deliver from #{warehouse.main_label}",
					recovery: "carson worktree create <name>" )
			end

			# Guard: parcel must include the latest registry state.
			warehouse.fetch_latest( registry: warehouse.main_label )
			unless warehouse.includes_latest?( parcel )
				return blocked( result,
					"parcel is behind #{warehouse.bureau_address}/#{warehouse.main_label}",
					recovery: "refresh this branch onto #{warehouse.bureau_address}/#{warehouse.main_label}, then carson deliver" )
			end

			# Ship the parcel to the bureau.
			unless warehouse.ship( parcel )
				return error( result, "shipping failed" )
			end

			# File a waybill with the bureau.
			waybill = Waybill.new(
				label: parcel.label,
				warehouse_path: warehouse.path
			)
			waybill.file!( title: title, body_file: body_file )
			unless waybill.filed?
				return error( result, "waybill filing failed", recovery: "carson deliver" )
			end

			result[ :tracking_number ] = waybill.tracking_number
			result[ :url ] = waybill.url

			# Wait at the customs window.
			settle( waybill, result )

			result[ :exit ] = OK
			result
		end

	private

		attr_reader :warehouse

		# The courier waits at the customs window, checking periodically.
		# When the bureau clears the parcel, the courier requests acceptance.
		def settle( waybill, result )
			started = Process.clock_gettime( Process::CLOCK_MONOTONIC )
			merge_attempts = 0
			watch_window = 30

			loop do
				waybill.refresh!

				if waybill.accepted?
					result[ :outcome ] = "delivered"
					return
				end

				if waybill.rejected?
					result[ :outcome ] = "rejected"
					return
				end

				if waybill.cleared? || ( waybill.mergeability_pending? && merge_attempts < MERGE_ATTEMPT_CAP )
					waybill.accept!( method: merge_method )
					merge_attempts += 1
					next if waybill.accepted?
				end

				if waybill.held? && !waybill.mergeability_pending?
					result[ :outcome ] = "held"
					result[ :hold_reason ] = waybill.hold_reason
					result[ :hold_summary ] = waybill.hold_summary
					return
				end

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
