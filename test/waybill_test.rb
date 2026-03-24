# Tests for Carson::Waybill — the shipping document (data object).
require "minitest/autorun"
require_relative "../lib/carson/waybill"

class WaybillTest < Minitest::Test
	# --- Identity and filing ---

	def test_unfiled_waybill_is_not_filed
		waybill = Carson::Waybill.new( label: "feature/test" )
		refute waybill.filed?
	end

	def test_waybill_with_tracking_number_is_filed
		waybill = Carson::Waybill.new(
			label: "feature/test",
			tracking_number: 42,
			url: "https://github.com/owner/repo/pull/42"
		)
		assert waybill.filed?
		assert_equal 42, waybill.tracking_number
		assert_equal "https://github.com/owner/repo/pull/42", waybill.url
	end

	def test_default_title_humanises_label
		waybill = Carson::Waybill.new( label: "fix/payment-bug" )
		assert_equal "Fix: payment bug", waybill.default_title
	end

	def test_default_title_for_class_method
		assert_equal "Fix: payment bug", Carson::Waybill.default_title_for( "fix/payment-bug" )
	end

	# --- Record and stamp ---

	def test_record_sets_state_and_ci
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false },
			ci: :pending
		)
		assert waybill.held?
		assert_equal "pending_at_bureau", waybill.hold_reason
	end

	def test_record_captures_ci_diagnostic
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :error,
			ci_diagnostic: "HTTP 404: Not Found"
		)
		assert_equal "HTTP 404: Not Found", waybill.ci_diagnostic
	end

	def test_record_clears_ci_diagnostic_on_success
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN" },
			ci: :error,
			ci_diagnostic: "some error"
		)
		assert_equal "some error", waybill.ci_diagnostic

		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		assert_nil waybill.ci_diagnostic
	end

	def test_stamp_accepted
		waybill = build_filed_waybill
		waybill.stamp( :accepted )
		assert waybill.accepted?
	end

	def test_stamp_rejected
		waybill = build_filed_waybill
		waybill.stamp( :rejected )
		assert waybill.rejected?
	end

	# --- Bureau response: accepted / rejected ---

	def test_accepted_when_state_merged
		waybill = build_filed_waybill
		waybill.record( state: { "state" => "MERGED" }, ci: :pass )
		assert waybill.accepted?
	end

	def test_rejected_when_state_closed
		waybill = build_filed_waybill
		waybill.record( state: { "state" => "CLOSED" }, ci: :pass )
		assert waybill.rejected?
	end

	def test_draft_when_is_draft
		waybill = build_filed_waybill
		waybill.record( state: { "state" => "OPEN", "isDraft" => true }, ci: :pass )
		assert waybill.draft?
	end

	# --- Bureau response: cleared / held ---

	def test_cleared_when_ci_passes_and_merge_clean
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		assert waybill.cleared?
		refute waybill.held?
	end

	def test_held_when_ci_pending
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :pending
		)
		assert waybill.held?
		assert_equal "pending_at_bureau", waybill.hold_reason
		assert_equal "Waiting for CI checks.", waybill.hold_summary
	end

	def test_held_when_ci_fails
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :fail
		)
		assert waybill.held?
		assert_equal "failed_at_bureau", waybill.hold_reason
	end

	def test_held_when_ci_error
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :error,
			ci_diagnostic: "HTTP 404: Not Found"
		)
		assert waybill.held?
		assert_equal "error_at_bureau", waybill.hold_reason
		assert_equal "Unable to assess CI checks.", waybill.hold_summary
		assert_equal "HTTP 404: Not Found", waybill.ci_diagnostic
	end

	def test_held_when_draft
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => true, "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "draft", waybill.hold_reason
	end

	def test_held_when_merge_conflict
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "merge_conflict", waybill.hold_reason
	end

	def test_held_when_behind_bureau
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "behind_bureau", waybill.hold_reason
	end

	def test_held_when_policy_block
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "BLOCKED" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "policy_block", waybill.hold_reason
	end

	def test_held_when_mergeability_pending
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "mergeability_pending", waybill.hold_reason
	end

	def test_mergeability_pending_predicate
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :pass
		)
		assert waybill.mergeability_pending?
	end

	# --- Hold summary uses client language ---

	def test_hold_summary_includes_remote_main_for_conflict
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" },
			ci: :pass
		)
		assert_equal "Merge conflict with origin/main.", waybill.hold_summary( remote_main: "origin/main" )
	end

	def test_hold_summary_includes_remote_main_for_behind
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" },
			ci: :pass
		)
		assert_equal "Branch is behind github/main.", waybill.hold_summary( remote_main: "github/main" )
	end

	# --- No-checks repositories (#465) ---

	def test_cleared_when_no_ci_checks
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
			ci: :none
		)
		assert waybill.cleared?, "repo with no CI checks should clear when merge state is clean"
		refute waybill.held?
	end

	def test_held_reason_not_ci_when_no_checks
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "BEHIND" },
			ci: :none
		)
		assert waybill.held?
		assert_equal "behind_bureau", waybill.hold_reason,
			"no-checks repo held for merge reason, not CI"
	end

	# --- Observation data ---

	def test_to_observation_returns_state_hash
		waybill = build_filed_waybill
		waybill.record(
			state: { "state" => "OPEN", "isDraft" => false, "mergedAt" => nil },
			ci: :pass
		)
		observation = waybill.to_observation
		assert_equal "OPEN", observation[ :pull_request_state ]
		assert_equal false, observation[ :pull_request_draft ]
		assert_nil observation[ :pull_request_merged_at ]
	end

private

	def build_filed_waybill
		Carson::Waybill.new(
			label: "feature/test",
			tracking_number: 42,
			url: "https://github.com/owner/repo/pull/42"
		)
	end
end
