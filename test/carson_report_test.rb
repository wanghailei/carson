# Tests for Carson.report — the company's output rendering.
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

	def test_report_human_shows_delivery
		result = { label: "feature/test", tracking_number: 42, url: "https://example.com/42", outcome: "delivered", synced: true }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Delivery: feature/test"
		assert_includes output.string, "PR #42"
		assert_includes output.string, "Delivered"
		assert_includes output.string, "Synced local main"
	end

	def test_report_human_shows_error_with_recovery
		result = { error: "parcel is behind", recovery: "carson deliver" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "parcel is behind"
		assert_includes output.string, "carson deliver"
	end

	def test_report_human_shows_held
		result = { label: "feature/held", outcome: "held", hold_summary: "waiting for customs inspection" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Held"
		assert_includes output.string, "customs inspection"
	end

	def test_report_human_shows_deferred
		result = { label: "feature/deferred", outcome: "deferred" }
		output = StringIO.new
		Carson.report( result, format: :human, output: output )

		assert_includes output.string, "Deferred"
		assert_includes output.string, "carson deliver"
	end
end
