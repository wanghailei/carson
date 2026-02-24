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
end
