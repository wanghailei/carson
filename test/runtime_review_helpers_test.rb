require_relative "test_helper"

class RuntimeReviewHelpersTest < Minitest::Test
	include CarsonTestSupport

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
					url: "https://github.com/acme/widgets/pull/12#issuecomment-alt",
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

	def test_recent_pull_requests_for_sweep_raises_on_pagination_safety_limit
		call_count = 0
		@runtime.define_singleton_method( :gh_run ) do |*|
			call_count += 1
			payload = [
				{
					"number" => call_count,
					"title" => "PR #{call_count}",
					"html_url" => "https://github.com/acme/widgets/pull/#{call_count}",
					"state" => "open",
					"updated_at" => "2026-02-20T00:00:00Z",
					"merged_at" => nil,
					"closed_at" => nil,
					"user" => { "login" => "octocat" }
				}
			]
			[ JSON.generate( payload ), "", true, 0 ]
		end

		error = assert_raises( RuntimeError ) do
			@runtime.send(
				:recent_pull_requests_for_sweep,
				owner: "acme",
				repo: "widgets",
				cutoff_time: Time.utc( 2026, 2, 1 )
			)
		end
		assert_match( /pagination exceeded safety limit/, error.message )
		assert_equal 50, call_count
	end

	def test_merged_pr_for_branch_reports_error_on_pagination_safety_limit
		call_count = 0
		@runtime.define_singleton_method( :repository_coordinates ) { [ "acme", "widgets" ] }
		@runtime.define_singleton_method( :gh_run ) do |*|
			call_count += 1
			payload = [
				{
					"head" => { "ref" => "other-branch", "sha" => "no-match" },
					"base" => { "ref" => "main" }
				}
			]
			[ JSON.generate( payload ), "", true, 0 ]
		end

		evidence, error_text = @runtime.send(
			:merged_pr_for_branch,
			branch: "feature/huge-pagination",
			branch_tip_sha: "abc123"
		)

		assert_nil evidence
		assert_match( /pagination safety limit/, error_text )
		assert_equal 50, call_count
	end
end
