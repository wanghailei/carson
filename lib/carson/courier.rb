# Carson Co.
require "open3"

module Carson
	# The delivery worker — waits at the gate, picks up parcels, delivers them.
	#
	# The courier is a Carson employee assigned to a warehouse. They pick up
	# a parcel, ask the warehouse to ship it, file a waybill, and wait at
	# the bureau while the bureaucrats check it.
	#
	# The courier is a thin orchestrator: it asks the warehouse to interact
	# with the bureau, reads the waybill for status, and reports results.
	# The domain logic lives in the objects, not the courier.
	#
	# == The bureau
	#
	# The bureau (GitHub) is where bureaucrats work. They check parcels
	# (CI, review, mergeability) and either accept them into the registry
	# or hold them with a reason. The warehouse owns the connection to
	# the bureau — the courier asks the warehouse to check, file, and
	# register.
	#
	# == Shelf seal
	#
	# Once the parcel ships and the waybill is filed, the warehouse seals
	# the shelf. No more packing until the delivery outcome is confirmed.
	# Delivered → shelf done (housekeep removes it).
	# Held/rejected → courier unseals (agent can fix and re-deliver).
	# Filed (checks exhausted) → shelf stays sealed (parcel still in flight).
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
	#   05. Pending at bureau — bureaucrats still checking (CI running).
	#   06. Failed at bureau — bureaucrats rejected (CI failed).
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
	# == Design: wait and poll at the bureau
	#
	# The courier waits at the bureau while the bureaucrats check the parcel.
	# It polls up to MAX_CHECKS_AT_BUREAU times, pausing between each check.
	# If the bureaucrats give a definitive answer (accepted or rejected), the
	# courier acts immediately. If the checks are exhausted without a definitive
	# answer, the courier reports "filed" — the parcel is still at the bureau
	# and the shelf stays sealed.
	#
	# == Workstyle
	#
	# The courier's gesture depends on the workstyle:
	# - :local — push main to backup vault (simple, no PR, no waiting)
	# - :remote — ship → waybill → bureau → acceptance (complex Bureau trip)
	#
	# The courier doesn't know whether it's doing "backup" or "primary" —
	# it just delivers to wherever the workstyle dictates.
	class Courier
		# Exit codes — shared contract between Carson employees and the CLI.
		OK = 0
		ERROR = 1
		BLOCKED = 2

		BADGE = "\u29D3".freeze

		# The courier checks the bureau up to 6 times before leaving.
		MAX_CHECKS_AT_BUREAU = 6

		def initialize( warehouse, workstyle: :local, ledger: nil, merge_method: "rebase", poll_interval_at_bureau: 30, output: $stdout )
			@warehouse = warehouse
			@workstyle = workstyle
			@ledger = ledger
			@merge_method = merge_method
			@poll_interval_at_bureau = poll_interval_at_bureau
			@output = output
		end

		# Deliver a parcel.
		# Local gesture: push main to backup vault.
		# Remote gesture: ship to Bureau, file waybill, poll, register.
		def deliver( parcel, title: nil, body_file: nil, commit_message: nil )
			return deliver_locally( parcel ) if @workstyle == :local

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
			#     The courier rebases automatically. Only blocks on conflict.
			unless @warehouse.fetch_latest( registry: @warehouse.main_label )
				return blocked( result,
					"cannot verify freshness — fetch failed",
					recovery: "carson sync, then carson deliver" )
			end
			unless @warehouse.based_on_latest_standard?( parcel )
				remote_main = "#{@warehouse.bureau_address}/#{@warehouse.main_label}"
				say "Branch is behind #{remote_main} — rebasing..."
				unless @warehouse.rebase_on_latest_standard!
					return blocked( result,
						"rebase conflict onto #{remote_main}",
						recovery: "resolve conflicts, then carson deliver" )
				end
				parcel = Parcel.new( label: parcel.label, head: @warehouse.current_head, shelf: parcel.shelf )
			end

			# Announce the delivery.
			say "Carson is delivering committed changes on branch #{parcel.label} to #{result[ :remote_main ]}..."

			# The courier picks up the parcel — start tracking.
			record( parcel, status: "preparing", summary: "delivery accepted" )

			# 03. Shipping fails — warehouse couldn't push to the bureau.
			unless @warehouse.ship( parcel )
				return error( result, "push failed" )
			end

			# File a waybill with the bureau — the warehouse handles the gh call.
			waybill = @warehouse.file_waybill_for!( parcel, title: title, body_file: body_file )

			# 04. Waybill filing fails — bureau rejected the paperwork.
			unless waybill
				return error( result, "PR creation failed", recovery: "carson deliver" )
			end

			result[ :tracking_number ] = waybill.tracking_number
			result[ :url ] = waybill.url

			# Seal the shelf — no more packing until the outcome is confirmed.
			@warehouse.seal_shelf!( tracking_number: waybill.tracking_number )

			# Wait at the bureau while the bureaucrats check the parcel.
			wait_and_poll_at_bureau( waybill, result )

			# Unseal based on outcome:
			# delivered/held/rejected → unseal (shelf done or parcel returned)
			# filed → stay sealed (parcel still in flight)
			outcome = result[ :outcome ]
			@warehouse.unseal_shelf! if outcome == "delivered" || outcome == "held" || outcome == "rejected"

			# Update the ledger with the final outcome and PR identity.
			record( parcel, status: outcome || "filed", summary: result[ :hold_reason ], waybill: waybill )

			result[ :exit ] ||= OK
			result
		end

	private

		# Wait at the bureau, polling the bureaucrats up to MAX_CHECKS_AT_BUREAU
		# times. The courier stays until a definitive answer comes back or the
		# checks are exhausted.
		def wait_and_poll_at_bureau( waybill, result )
			MAX_CHECKS_AT_BUREAU.times do |check|
				@warehouse.check_parcel_at_bureau_with( waybill )

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

				# Cleared or mergeability pending — ask the warehouse to register.
				if waybill.cleared? || waybill.mergeability_pending?
					@warehouse.register_parcel_at_bureau_with!( waybill, method: @merge_method )

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
					result[ :hold_summary ] = waybill.hold_summary( remote_main: result[ :remote_main ] )
					result[ :diagnostic ] = waybill.ci_diagnostic
					return
				end

				# Report progress — client-language summary from the waybill.
				summary = waybill.hold_summary( remote_main: result[ :remote_main ] )
				detail = waybill.ci_diagnostic ? " \u2014 #{waybill.ci_diagnostic}" : ""
				say "#{summary}#{detail} (#{check + 1}/#{MAX_CHECKS_AT_BUREAU})..."

				# Still waiting — pause before the next check.
				pause_between_polls unless check == MAX_CHECKS_AT_BUREAU - 1
			end

			# Exhausted all checks — bureau hasn't given a definitive answer.
			result[ :outcome ] = "filed"
			result[ :hold_reason ] = waybill.hold_reason
			result[ :hold_summary ] = waybill.hold_summary( remote_main: result[ :remote_main ] )
			result[ :diagnostic ] = waybill.ci_diagnostic
		end

		# Local gesture: sync the vault to the remote.
		# The parcel is already in the vault (accepted by the Warehouse).
		# The courier's job is to push the vault state to the remote.
		def deliver_locally( parcel )
			result = {
				command: "deliver",
				label: parcel.label,
				remote_main: "#{@warehouse.bureau_address}/#{@warehouse.main_label}"
			}

			remote = @warehouse.bureau_address
			main = @warehouse.main_label
			root = @warehouse.main_worktree_root

			# The pre-push hook understands local workstyle — no bypass needed.
			_, stderr, status = Open3.capture3(
				"git", "-C", root, "push", remote, main
			)

			if status.success?
				result[ :exit ] = OK
				result[ :outcome ] = "delivered"
				result[ :synced ] = true
			else
				result[ :exit ] = OK
				result[ :outcome ] = "delivered"
				result[ :synced ] = false
				result[ :sync_error ] = stderr.strip
			end

			result
		end

		# Is the waybill blocked by something that won't resolve by waiting?
		# CI failure, merge conflict, policy block — the courier should take
		# the parcel back immediately.
		def definitively_blocked?( waybill )
			return false unless waybill.held?
			reason = waybill.hold_reason
			[ "failed_at_bureau", "merge_conflict",
				"behind_bureau", "policy_block", "draft" ].include?( reason )
		end

		# The courier speaks — reports progress to whoever is listening.
		def say( message )
			@output&.puts "#{BADGE} #{message}"
		end

		# Pause between poll checks. Overridable for test isolation.
		def pause_between_polls
			sleep @poll_interval_at_bureau
		end

		# Record a delivery state change in the ledger.
		# When a waybill is provided, its PR identity is persisted.
		def record( parcel, status:, summary: nil, waybill: nil )
			return unless @ledger

			# The ledger needs a repository-like object with .path pointing
			# to the main warehouse root (not a side shelf).
			repo = Struct.new( :path ).new( @warehouse.main_worktree_root )
			@ledger.upsert_delivery(
				repository: repo,
				branch_name: parcel.label,
				head: parcel.head,
				worktree_path: @warehouse.path,
				pr_number: waybill&.tracking_number,
				pr_url: waybill&.url,
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
