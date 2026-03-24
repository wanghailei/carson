# Tests for Carson.report — output in client language for agents.
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

	def test_report_text_shows_merged_delivery
		result = { label: "feature/test", tracking_number: 42, url: "https://example.com/42", outcome: "delivered", synced: true }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Delivery: feature/test"
		assert_includes output.string, "PR #42"
		assert_includes output.string, "Merged"
		assert_includes output.string, "Local main synced"
	end

	def test_report_text_shows_error_with_recovery
		result = { error: "branch is behind origin/main", recovery: "carson deliver" }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "branch is behind"
		assert_includes output.string, "carson deliver"
	end

	def test_report_text_shows_ci_pending_with_recovery
		result = { label: "feature/ci", outcome: "held", hold_reason: "pending_at_bureau", hold_summary: "Waiting for CI checks." }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Waiting for CI checks"
		assert_includes output.string, "carson status"
	end

	def test_report_text_shows_ci_failed_with_recovery
		result = { label: "feature/ci-fail", outcome: "held", hold_reason: "failed_at_bureau", hold_summary: "CI checks failed." }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "CI checks failed"
		assert_includes output.string, "carson deliver"
	end

	def test_report_text_shows_merge_conflict_with_rebase_command
		result = { label: "feature/conflict", outcome: "held", hold_reason: "merge_conflict",
			hold_summary: "Merge conflict with origin/main.", remote_main: "origin/main" }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Merge conflict with origin/main"
		assert_includes output.string, "git rebase origin/main"
		assert_includes output.string, "carson deliver"
	end

	def test_report_text_shows_filed_with_status_command
		result = { label: "feature/filed", outcome: "filed", hold_summary: "Waiting for CI checks." }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Waiting for CI checks."
		assert_includes output.string, "carson status"
	end

	def test_report_text_shows_filed_with_diagnostic
		result = { label: "feature/filed", outcome: "filed",
			hold_summary: "Unable to assess CI checks.", diagnostic: "HTTP 404: Not Found" }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Unable to assess CI checks."
		assert_includes output.string, "HTTP 404: Not Found"
		assert_includes output.string, "carson status"
	end

	def test_report_text_shows_pr_closed
		result = { label: "feature/closed", outcome: "rejected" }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "PR closed externally"
	end

	def test_report_text_shows_sync_failure
		result = { label: "feature/sync-fail", outcome: "delivered", synced: false }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Merged"
		assert_includes output.string, "not synced"
		assert_includes output.string, "carson sync"
	end

	def test_report_text_omits_sync_line_when_key_absent
		result = { label: "feature/no-sync-key", outcome: "delivered" }
		output = StringIO.new
		Carson.report( result, format: :text, output: output )

		assert_includes output.string, "Merged"
		refute_includes output.string, "synced"
	end

	# --- No story language in output ---

	def test_report_text_contains_no_story_language
		held_result = { label: "feature/test", outcome: "held",
			hold_reason: "pending_at_bureau", hold_summary: "Waiting for CI checks." }
		filed_result = { label: "feature/test", outcome: "filed",
			hold_summary: "Unable to assess CI checks.", diagnostic: "timeout" }

		[ held_result, filed_result ].each do |result|
			output = StringIO.new
			Carson.report( result, format: :text, output: output )
			text = output.string.downcase
			refute_includes text, "bureau"
			refute_includes text, "bureaucrat"
			refute_includes text, "parcel"
			refute_includes text, "waybill"
			refute_includes text, "shelf"
			refute_includes text, "registry"
		end
	end
end
