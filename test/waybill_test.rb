# Tests for Carson::Waybill — the shipping document filed with the bureau.
require "minitest/autorun"
require_relative "../lib/carson/waybill"

class WaybillTest < Minitest::Test
	# --- Identity and filing ---

	def test_unfiled_waybill_is_not_filed
		waybill = Carson::Waybill.new( label: "feature/test", warehouse_path: "/tmp/repo" )
		refute waybill.filed?
	end

	def test_waybill_with_tracking_number_is_filed
		waybill = Carson::Waybill.new(
			label: "feature/test",
			warehouse_path: "/tmp/repo",
			tracking_number: 42,
			url: "https://github.com/owner/repo/pull/42"
		)
		assert waybill.filed?
		assert_equal 42, waybill.tracking_number
		assert_equal "https://github.com/owner/repo/pull/42", waybill.url
	end

	def test_default_title_humanises_label
		waybill = Carson::Waybill.new( label: "fix/payment-bug", warehouse_path: "/tmp/repo" )
		assert_equal "Fix: payment bug", waybill.default_title
	end

	# --- Bureau response: accepted / rejected ---

	def test_accepted_when_state_merged
		waybill = build_filed_waybill
		waybill.stub_bureau_response( state: { "state" => "MERGED" } )
		assert waybill.accepted?
	end

	def test_rejected_when_state_closed
		waybill = build_filed_waybill
		waybill.stub_bureau_response( state: { "state" => "CLOSED" } )
		assert waybill.rejected?
	end

	def test_draft_when_is_draft
		waybill = build_filed_waybill
		waybill.stub_bureau_response( state: { "state" => "OPEN", "isDraft" => true } )
		assert waybill.draft?
	end

	# --- Bureau response: cleared / held ---

	def test_cleared_when_ci_passes_and_merge_clean
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		assert waybill.cleared?
		refute waybill.held?
	end

	def test_held_when_ci_pending
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :pending
		)
		assert waybill.held?
		assert_equal "inspector_pending", waybill.hold_reason
		assert_equal "waiting for customs inspection", waybill.hold_summary
	end

	def test_held_when_ci_fails
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeStateStatus" => "UNKNOWN" },
			ci: :fail
		)
		assert waybill.held?
		assert_equal "inspector_failed", waybill.hold_reason
	end

	def test_held_when_draft
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => true, "mergeStateStatus" => "CLEAN" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "draft", waybill.hold_reason
	end

	def test_held_when_merge_conflict
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "CONFLICTING", "mergeStateStatus" => "DIRTY" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "merge_conflict", waybill.hold_reason
	end

	def test_held_when_behind_registry
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "MERGEABLE", "mergeStateStatus" => "BEHIND" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "behind_registry", waybill.hold_reason
	end

	def test_held_when_policy_block
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "BLOCKED" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "policy_block", waybill.hold_reason
	end

	def test_held_when_mergeability_pending
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :pass
		)
		assert waybill.held?
		assert_equal "mergeability_pending", waybill.hold_reason
	end

	def test_mergeability_pending_predicate
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergeable" => "UNKNOWN", "mergeStateStatus" => "UNKNOWN" },
			ci: :pass
		)
		assert waybill.mergeability_pending?
	end

	# --- Observation data ---

	def test_to_observation_returns_state_hash
		waybill = build_filed_waybill
		waybill.stub_bureau_response(
			state: { "state" => "OPEN", "isDraft" => false, "mergedAt" => nil }
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
			warehouse_path: "/tmp/repo",
			tracking_number: 42,
			url: "https://github.com/owner/repo/pull/42"
		)
	end
end
