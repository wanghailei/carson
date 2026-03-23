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

	def test_report_human_shows_ci_pending_with_recovery
		result = { label: "feature/ci", outcome: "held", hold_reason: "pending_at_registry" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Waiting for CI checks"
		assert_includes output.string, "carson status"
	end

	def test_report_human_shows_ci_failed_with_recovery
		result = { label: "feature/ci-fail", outcome: "held", hold_reason: "failed_at_registry" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "CI checks failed"
		assert_includes output.string, "carson deliver"
	end

	def test_report_human_shows_merge_conflict_with_rebase_command
		result = { label: "feature/conflict", outcome: "held", hold_reason: "merge_conflict", remote_main: "origin/main" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Merge conflict with origin/main"
		assert_includes output.string, "git rebase origin/main"
		assert_includes output.string, "carson deliver"
	end

	def test_report_human_shows_filed_with_status_command
		result = { label: "feature/filed", outcome: "filed" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "hasn't responded yet"
		assert_includes output.string, "carson status"
	end

	def test_report_human_shows_pr_closed
		result = { label: "feature/closed", outcome: "rejected" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "PR closed externally"
	end
end
