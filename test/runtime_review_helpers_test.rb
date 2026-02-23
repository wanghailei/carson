require_relative "test_helper"

class RuntimeReviewHelpersTest < Minitest::Test
	include ButlerTestSupport

	def setup
		@runtime, @repo_root = build_runtime
	end

	def teardown
		destroy_runtime_repo( repo_root: @repo_root )
	end

	def test_review_gate_signature_sorts_urls_for_stable_comparison
		signature = @runtime.send(
			:review_gate_signature,
			snapshot: {
				latest_activity: "2026-02-20T10:00:00Z",
				unresolved_threads: [ { url: "b" }, { url: "a" } ],
				unacknowledged_actionable: [ { url: "d" }, { url: "c" } ]
			}
		)
		assert_equal [ "a", "b" ], signature.fetch( :unresolved_urls )
		assert_equal [ "c", "d" ], signature.fetch( :unacknowledged_urls )
	end

	def test_matched_risk_keywords_uses_case_insensitive_whole_words
		hits = @runtime.send( :matched_risk_keywords, text: "Potential Security regression and BUG risk" )
		assert_includes hits, "security"
		assert_includes hits, "regression"
		assert_includes hits, "bug"
		refute_includes hits, "fail"
	end

	def test_normalise_rest_pull_request_state_reports_merged_when_merged_at_present
		state = @runtime.send( :normalise_rest_pull_request_state, entry: { "state" => "closed", "merged_at" => "2026-02-20T00:00:00Z" } )
		assert_equal "MERGED", state
	end

	def test_disposition_acknowledgements_respects_configured_prefix
		details = {
			comments: [
				{
					author: "owner",
					body: "Disposition: accepted https://github.com/acme/widgets/pull/12#issuecomment-risk",
					url: "https://github.com/acme/widgets/pull/12#issuecomment-ack",
					created_at: "2026-02-20T00:00:01Z"
				},
				{
					author: "owner",
					body: "Codex: accepted https://github.com/acme/widgets/pull/12#issuecomment-risk",
					url: "https://github.com/acme/widgets/pull/12#issuecomment-legacy",
					created_at: "2026-02-20T00:00:02Z"
				}
			],
			reviews: [],
			review_threads: []
		}
		acknowledgements = @runtime.send( :disposition_acknowledgements, details: details, pr_author: "owner" )
		assert_equal 1, acknowledgements.length
		assert_equal "accepted", acknowledgements.first.fetch( :disposition )
		assert_equal [ "https://github.com/acme/widgets/pull/12#issuecomment-risk" ], acknowledgements.first.fetch( :target_urls )
	end
end
