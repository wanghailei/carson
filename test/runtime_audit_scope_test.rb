require_relative "test_helper"

class RuntimeAuditScopeTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@runtime, @repo_root = build_runtime
	end

	def teardown
		destroy_runtime_repo( repo_root: @repo_root )
	end

	def test_pattern_matches_directory_prefix
		result = @runtime.send( :pattern_matches_path?, pattern: "lib/**", path: "lib/carson/runtime.rb" )
		assert_equal true, result
	end

	def test_pattern_does_not_match_outside_directory_prefix
		result = @runtime.send( :pattern_matches_path?, pattern: "lib/**", path: "script/ci_smoke.sh" )
		assert_equal false, result
	end

	def test_scope_integrity_passes_for_single_core_group_with_supporting_tests
		scope = @runtime.send(
			:scope_integrity_status,
			files: [ "lib/carson/config.rb", "test/runtime_audit_scope_test.rb", "README.md" ],
			branch: "feature/hook-upgrade"
		)
		assert_equal "ok", scope.fetch( :status )
		assert_equal false, scope.fetch( :split_required )
		assert_equal [ "tool" ], scope.fetch( :core_groups )
		assert_equal [], scope.fetch( :violating_files )
	end

	def test_scope_integrity_requires_split_for_multiple_core_groups
		scope = @runtime.send(
			:scope_integrity_status,
			files: [ "lib/carson/config.rb", "app/models/user.rb" ],
			branch: "any/branch-name"
		)
		assert_equal true, scope.fetch( :split_required )
		assert_equal true, scope.fetch( :mixed_core_groups )
		assert_equal "attention", scope.fetch( :status )
		assert_includes scope.fetch( :core_groups ), "tool"
		assert_includes scope.fetch( :core_groups ), "domain"
		assert_equal 2, scope.fetch( :violating_files ).length
	end

	def test_scope_integrity_is_branch_name_agnostic
		files = [ "lib/carson/config.rb" ]
		scope_one = @runtime.send( :scope_integrity_status, files: files, branch: "hook-upgrade" )
		scope_two = @runtime.send( :scope_integrity_status, files: files, branch: "runtime-review-cleanup" )
		assert_equal scope_one.fetch( :status ), scope_two.fetch( :status )
		assert_equal scope_one.fetch( :split_required ), scope_two.fetch( :split_required )
		assert_equal scope_one.fetch( :core_groups ), scope_two.fetch( :core_groups )
	end

	def test_scope_integrity_marks_misc_paths_as_attention_without_split
		scope = @runtime.send( :scope_integrity_status, files: [ "tmp/experimental.txt" ], branch: "feature/misc-file" )
		assert_equal false, scope.fetch( :split_required )
		assert_equal true, scope.fetch( :misc_present )
		assert_equal "attention", scope.fetch( :status )
		assert_equal [ "tmp/experimental.txt" ], scope.fetch( :unmatched_paths )
	end

	def test_scope_integrity_treats_install_script_as_tool_scope
		scope = @runtime.send( :scope_integrity_status, files: [ "install.sh" ], branch: "any/install-upgrade" )
		assert_equal false, scope.fetch( :split_required )
		assert_equal "ok", scope.fetch( :status )
		assert_equal [ "tool" ], scope.fetch( :core_groups )
	end
end
