# Carson Co.
module Carson
	# The delivery person — picks up parcels and delivers them to the registry.
	#
	# The courier is a Carson employee assigned to a warehouse. They pick up
	# a parcel, ship it to the bureau, file a waybill, and wait at the
	# registry while the bureaucrats check it.
	#
	# The courier is a thin orchestrator: it creates a Waybill and sends it
	# messages. The domain logic lives in the objects, not the courier.
	#
	# == The bureau
	#
	# The bureau is a registry (GitHub) where bureaucrats work. They check
	# parcels (CI, review, mergeability) and either accept them into the
	# registry or hold them with a reason.
	#
	# == Situations the courier encounters
	#
	# Each numbered situation is handled by a specific guard or branch in the
	# delivery flow. The number appears in the code comment where it's handled.
	#
	#   01. Parcel on main — cannot deliver from the destination.
	#   02. Parcel behind standard — not based on client's latest standard.
	#   03. Shipping fails — warehouse couldn't push to the bureau.
	#   04. Waybill filing fails — bureau rejected the paperwork.
	#   05. Pending at registry — bureaucrats still checking (CI running).
	#   06. Failed at registry — bureaucrats rejected (CI failed).
	#   07. Review pending — review still in progress.
	#   08. Review changes requested — reviewer wants corrections.
	#   09. Merge conflict — parcel conflicts with registry contents.
	#   10. Behind standard (post-filing) — standard changed since shipping.
	#   11. Policy block — bureau regulation prevents acceptance.
	#   12. Draft waybill — form not finalised.
	#   13. Mergeability pending — bureau still processing eligibility.
	#   14. Acceptance succeeds — parcel enters the registry. Delivered.
	#   15. Acceptance fails — classify why, report.
	#   16. Bureau unreachable — cannot contact the bureau.
	#   17. Parcel already delivered — already in registry.
	#   18. Waybill closed — cancelled by someone externally.
	#
	# == Design: wait and poll at the registry
	#
	# The courier waits at the registry while the bureaucrats check the parcel.
	# It polls up to MAX_CHECKS_AT_REGISTRY times, pausing between each check.
	# If the bureaucrats give a definitive answer (accepted or rejected), the
	# courier acts immediately. If the checks are exhausted without a definitive
	# answer, the courier reports "filed" — the parcel is still at the registry.
	#
	# == Future: destination modes
	#
	# Currently remote-centred (ship → waybill → registry → acceptance).
	# A future local-centred mode merges locally; remote is a synced backup.
	# The destination mode should be injectable, not baked in.
	class Courier
		# Exit codes — shared contract between Carson employees and the CLI.
		OK = 0
		ERROR = 1
		BLOCKED = 2

		# The courier checks the registry up to 6 times before leaving.
		MAX_CHECKS_AT_REGISTRY = 6

		def initialize( warehouse, ledger: nil, merge_method: "rebase", poll_interval_at_registry: 30 )
			@warehouse = warehouse
			@ledger = ledger
			@merge_method = merge_method
			@poll_interval_at_registry = poll_interval_at_registry
		end

		# Deliver a parcel to the registry.
		# Ships it, files a waybill, waits at the registry for the bureaucrats.
		def deliver( parcel, title: nil, body_file: nil, commit_message: nil )
			result = {
				command: "deliver",
				label: parcel.label,
				remote_main: "#{@warehouse.bureau_address}/#{@warehouse.main_label}"
			}

			# 01. Parcel on main — cannot deliver from the destination.
			if parcel.on_main?( @warehouse.main_label )
				return blocked( result,
					"cannot deliver from #{@warehouse.main_label}",
					recovery: "carson worktree create <name>" )
			end

			# Dirty tree guard — the warehouse knows if its floor is clean.
			if commit_message && @warehouse.clean?
				return blocked( result,
					"working tree is already clean",
					recovery: "carson deliver" )
			end
			if !commit_message && !@warehouse.clean?
				return blocked( result,
					"working tree is dirty",
					recovery: "carson deliver --commit \"describe this delivery\"" )
			end

			# Submit compliance — ensure templates are in sync before delivery.
			compliance = @warehouse.submit_compliance!
			unless compliance[ :compliant ]
				return error( result, compliance[ :error ] || "compliance check failed" )
			end

			# Pack the parcel if the sender provided a commit message.
			# Skip if compliance already committed everything (tree is now clean).
			if commit_message && !@warehouse.clean?
				unless @warehouse.pack!( message: commit_message )
					return error( result, "packing failed — nothing to commit?" )
				end
			end
			# Refresh parcel head — compliance or pack may have created commits.
			parcel = Parcel.new( label: parcel.label, head: @warehouse.current_head, shelf: parcel.shelf )

			# 02. Parcel behind standard — not based on client's latest standard.
			@warehouse.fetch_latest( registry: @warehouse.main_label )
			unless @warehouse.based_on_latest_standard?( parcel )
				remote_main = "#{@warehouse.bureau_address}/#{@warehouse.main_label}"
				return blocked( result,
					"branch is behind #{remote_main}",
					recovery: "git rebase #{remote_main}, then carson deliver" )
			end

			# The courier picks up the parcel — start tracking.
			record( parcel, status: "preparing", summary: "delivery accepted" )

			# 03. Shipping fails — warehouse couldn't push to the bureau.
			unless @warehouse.ship( parcel )
				return error( result, "push failed" )
			end

			# File a waybill with the bureau.
			waybill = Waybill.new(
				label: parcel.label,
				warehouse_path: @warehouse.path
			)
			waybill.file!( title: title, body_file: body_file )

			# 04. Waybill filing fails — bureau rejected the paperwork.
			unless waybill.filed?
				return error( result, "PR creation failed", recovery: "carson deliver" )
			end

			result[ :tracking_number ] = waybill.tracking_number
			result[ :url ] = waybill.url

			# Wait at the registry while the bureaucrats check the parcel.
			wait_and_poll_at_registry( waybill, result )

			# Update the ledger with the final outcome.
			record( parcel, status: result[ :outcome ] || "filed", summary: result[ :hold_reason ] )

			result[ :exit ] ||= OK
			result
		end

	private

		# Wait at the registry, polling the bureaucrats up to MAX_CHECKS_AT_REGISTRY
		# times. The courier stays until a definitive answer comes back or the
		# checks are exhausted.
		def wait_and_poll_at_registry( waybill, result )
			MAX_CHECKS_AT_REGISTRY.times do |check|
				waybill.refresh!

				# 14/17. Already accepted — parcel is in the registry.
				if waybill.accepted?
					result[ :outcome ] = "delivered"
					result[ :synced ] = @warehouse.receive_latest_standard!
					return
				end

				# 18. Waybill closed — cancelled externally.
				if waybill.rejected?
					result[ :outcome ] = "rejected"
					result[ :exit ] = BLOCKED
					return
				end

				# Cleared or mergeability pending — try to accept.
				if waybill.cleared? || waybill.mergeability_pending?
					waybill.accept!( method: @merge_method )

					if waybill.accepted?
						result[ :outcome ] = "delivered"
						result[ :synced ] = @warehouse.receive_latest_standard!
						return
					end
				end

				# 05-12. Definitively blocked — courier takes parcel back.
				if definitively_blocked?( waybill )
					result[ :outcome ] = "held"
					result[ :exit ] = BLOCKED
					result[ :hold_reason ] = waybill.hold_reason
					return
				end

				# Still waiting — pause before the next check.
				pause_between_polls unless check == MAX_CHECKS_AT_REGISTRY - 1
			end

			# Exhausted all checks — bureau hasn't given a definitive answer.
			result[ :outcome ] = "filed"
			result[ :hold_reason ] = waybill.hold_reason
		end

		# Is the waybill blocked by something that won't resolve by waiting?
		# CI failure, merge conflict, policy block — the courier should take
		# the parcel back immediately.
		def definitively_blocked?( waybill )
			return false unless waybill.held?
			reason = waybill.hold_reason
			[ "failed_at_registry", "merge_conflict",
				"behind_registry", "policy_block", "draft" ].include?( reason )
		end

		# Pause between poll checks. Overridable for test isolation.
		def pause_between_polls
			sleep @poll_interval_at_registry
		end

		# Record a delivery state change in the ledger.
		# No-op when no ledger is injected (e.g. tests).
		def record( parcel, status:, summary: nil )
			return unless @ledger

			# The ledger needs a repository-like object with .path pointing
			# to the main warehouse root (not a side shelf).
			repo = Struct.new( :path ).new( @warehouse.main_worktree_root )
			@ledger.upsert_delivery(
				repository: repo,
				branch_name: parcel.label,
				head: parcel.head,
				worktree_path: @warehouse.path,
				pr_number: nil,
				pr_url: nil,
				status: status,
				summary: summary,
				cause: nil
			)
		end

		# Build a blocked result — the courier cannot proceed.
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
