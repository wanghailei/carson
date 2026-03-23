# Tests for Carson.report — output in technical language for agents and humans.
require "minitest/autorun"
require "stringio"
require_relative "../lib/carson"

class CarsonReportTest < Minitest::Test
	def test_report_json_outputs_valid_json
		result = { command: "deliver", label: "feature/test", outcome: "delivered" }
		output = StringIO.new
		Carson.report( result, format: :json, output: output )

		parsed = JSON.parse( output.string )
		assert_equal "delivered", parsed[ "outcome" ]
	end

	def test_report_human_shows_merged_delivery
		result = { label: "feature/test", tracking_number: 42, url: "https://example.com/42", outcome: "delivered", synced: true }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Delivery: feature/test"
		assert_includes output.string, "PR #42"
		assert_includes output.string, "Merged"
		assert_includes output.string, "Local main synced"
	end

	def test_report_human_shows_error_with_recovery
		result = { error: "branch is behind origin/main", recovery: "carson deliver" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "branch is behind"
		assert_includes output.string, "carson deliver"
	end

	def test_report_human_shows_ci_pending
		result = { label: "feature/ci", outcome: "held", hold_reason: "inspector_pending" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Waiting for CI checks"
	end

	def test_report_human_shows_ci_failed
		result = { label: "feature/ci-fail", outcome: "held", hold_reason: "inspector_failed" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "CI checks failed"
	end

	def test_report_human_shows_merge_conflict
		result = { label: "feature/conflict", outcome: "held", hold_reason: "merge_conflict" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Merge conflict with main"
	end

	def test_report_human_shows_deferred
		result = { label: "feature/deferred", outcome: "deferred" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Merge deferred"
		assert_includes output.string, "carson deliver"
	end

	def test_report_human_shows_pr_closed
		result = { label: "feature/closed", outcome: "rejected" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "PR closed externally"
	end
end
