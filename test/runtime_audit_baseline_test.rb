require_relative "test_helper"

class RuntimeAuditBaselineTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@runtime, @repo_root = build_runtime
	end

	def teardown
		destroy_runtime_repo( repo_root: @repo_root )
	end

	def test_default_branch_check_run_failing_for_completed_failure
		result = @runtime.send(
			:default_branch_check_run_failing?,
			entry: { "status" => "completed", "conclusion" => "failure" }
		)
		assert_equal true, result
	end

	def test_default_branch_check_run_pending_for_in_progress
		result = @runtime.send(
			:default_branch_check_run_pending?,
			entry: { "status" => "in_progress", "conclusion" => nil }
		)
		assert_equal true, result
	end

	def test_default_branch_check_run_pending_for_missing_completed_conclusion
		result = @runtime.send(
			:default_branch_check_run_pending?,
			entry: { "status" => "completed", "conclusion" => nil }
		)
		assert_equal true, result
	end

	def test_default_branch_check_run_not_pending_or_failing_for_completed_success
		failing = @runtime.send(
			:default_branch_check_run_failing?,
			entry: { "status" => "completed", "conclusion" => "success" }
		)
		pending = @runtime.send(
			:default_branch_check_run_pending?,
			entry: { "status" => "completed", "conclusion" => "success" }
		)
		assert_equal false, failing
		assert_equal false, pending
	end

	def test_separate_advisory_check_entries_splits_by_name
		entries = [
			{ "name" => "Carson governance", "status" => "completed", "conclusion" => "failure" },
			{ "name" => "Scheduled review sweep", "status" => "completed", "conclusion" => "failure" },
			{ "name" => "CI build", "status" => "completed", "conclusion" => "failure" }
		]
		critical, advisory = @runtime.send(
			:separate_advisory_check_entries,
			entries: entries,
			advisory_names: [ "Scheduled review sweep" ]
		)
		assert_equal 2, critical.count
		assert_equal 1, advisory.count
		assert_equal "Scheduled review sweep", advisory.first[ "name" ]
	end

	def test_separate_advisory_check_entries_empty_advisory_names_keeps_all_critical
		entries = [
			{ "name" => "Scheduled review sweep", "status" => "completed", "conclusion" => "failure" }
		]
		critical, advisory = @runtime.send(
			:separate_advisory_check_entries,
			entries: entries,
			advisory_names: []
		)
		assert_equal 1, critical.count
		assert_equal 0, advisory.count
	end

	def test_separate_advisory_check_entries_no_match_keeps_all_critical
		entries = [
			{ "name" => "CI build", "status" => "completed", "conclusion" => "failure" }
		]
		critical, advisory = @runtime.send(
			:separate_advisory_check_entries,
			entries: entries,
			advisory_names: [ "Scheduled review sweep" ]
		)
		assert_equal 1, critical.count
		assert_equal 0, advisory.count
	end
end
