require_relative "test_helper"

class RuntimeAuditScopeTest < Minitest::Test
	include ButlerTestSupport

	def setup
		@runtime, @repo_root = build_runtime
	end

	def teardown
		destroy_runtime_repo( repo_root: @repo_root )
	end

	def test_pattern_matches_directory_prefix
		result = @runtime.send( :pattern_matches_path?, pattern: "lib/**", path: "lib/butler/runtime.rb" )
		assert_equal true, result
	end

	def test_pattern_does_not_match_outside_directory_prefix
		result = @runtime.send( :pattern_matches_path?, pattern: "lib/**", path: "script/ci_smoke.sh" )
		assert_equal false, result
	end

	def test_scope_integrity_passes_for_lane_matched_group
		scope = @runtime.send( :scope_integrity_status, files: [ "lib/butler/config.rb", "README.md" ], branch: "tool/refactor-config" )
		assert_equal "ok", scope.fetch( :status )
		assert_equal false, scope.fetch( :split_required )
		assert_equal "tool", scope.fetch( :primary_group )
		assert_equal "tool", scope.fetch( :lane )
	end

	def test_scope_integrity_requires_split_for_lane_mismatch
		scope = @runtime.send( :scope_integrity_status, files: [ "app/models/user.rb" ], branch: "tool/review-gate" )
		assert_equal true, scope.fetch( :split_required )
		assert_equal true, scope.fetch( :mismatched_lane_scope )
		assert_equal "attention", scope.fetch( :status )
	end

	def test_scope_integrity_marks_unknown_lane_when_branch_pattern_not_matched
		scope = @runtime.send( :scope_integrity_status, files: [ "lib/butler/config.rb" ], branch: "codex/tool/legacy" )
		assert_equal true, scope.fetch( :unknown_lane )
		assert_equal "attention", scope.fetch( :status )
	end
end
