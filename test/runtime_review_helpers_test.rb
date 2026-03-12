# Tests for review gate and sweep helper methods.
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

	def test_review_gate_snapshot_flags_changes_requested_review_without_disposition
		details = {
			updated_at: "2026-02-20T00:00:00Z",
			author: { login: "owner" },
			comments: [],
			reviews: [
				{
					author: "reviewer",
					state: "CHANGES_REQUESTED",
					body: "Please fix this bug before merge.",
					url: "https://github.com/acme/widgets/pull/12#pullrequestreview-1",
					created_at: "2026-02-20T00:00:01Z"
				}
			],
			review_threads: []
		}
		@runtime.define_singleton_method( :pull_request_details ) { |**| details }

		snapshot = @runtime.send( :review_gate_snapshot, owner: "acme", repo: "widgets", pr_number: 12 )

		assert_equal 1, snapshot.fetch( :unacknowledged_actionable ).length
		assert_equal "changes_requested_review", snapshot.fetch( :unacknowledged_actionable ).first.fetch( :reason )
	end

	def test_review_gate_snapshot_ignores_acknowledged_risk_keyword_comment
		details = {
			updated_at: "2026-02-20T00:00:00Z",
			author: { login: "owner" },
			comments: [
				{
					author: "reviewer",
					body: "This change has regression risk.",
					url: "https://github.com/acme/widgets/pull/12#issuecomment-risk",
					created_at: "2026-02-20T00:00:01Z"
				},
				{
					author: "owner",
					body: "Disposition: accepted https://github.com/acme/widgets/pull/12#issuecomment-risk",
					url: "https://github.com/acme/widgets/pull/12#issuecomment-ack",
					created_at: "2026-02-20T00:00:02Z"
				}
			],
			reviews: [],
			review_threads: []
		}
		@runtime.define_singleton_method( :pull_request_details ) { |**| details }

		snapshot = @runtime.send( :review_gate_snapshot, owner: "acme", repo: "widgets", pr_number: 12 )

		assert_equal 1, snapshot.fetch( :actionable_top_level ).length
		assert_empty snapshot.fetch( :unacknowledged_actionable )
	end

	def test_review_gate_report_for_pr_blocks_when_snapshot_does_not_converge
		call_count = 0
		@runtime.define_singleton_method( :wait_for_review_warmup ) { |**| nil }
		@runtime.define_singleton_method( :wait_for_review_poll ) { nil }
		@runtime.define_singleton_method( :review_gate_snapshot ) do |**|
			call_count += 1
			{
				latest_activity: format( "2026-02-20T00:00:%02dZ", call_count ),
				unresolved_threads: [],
				actionable_top_level: [],
				unacknowledged_actionable: [],
				acknowledgements: []
			}
		end

		report = @runtime.send(
			:review_gate_report_for_pr,
			owner: "acme",
			repo: "widgets",
			pr_number: 12,
			branch_name: "feature/test",
			pr_summary: {
				number: 12,
				title: "Test PR",
				url: "https://github.com/acme/widgets/pull/12",
				state: "OPEN"
			}
		)

		assert_equal "block", report.fetch( :status )
		assert_equal false, report.fetch( :converged )
		assert_includes report.fetch( :block_reasons ), "review snapshot did not converge within #{@runtime.send( :config ).review_max_polls} polls"
	end

	def test_review_gate_report_for_pr_blocks_on_unresolved_threads_after_convergence
		snapshot = {
			latest_activity: "2026-02-20T00:00:00Z",
			unresolved_threads: [
				{
					url: "https://github.com/acme/widgets/pull/12#discussion_r1",
					author: "reviewer",
					created_at: "2026-02-20T00:00:01Z",
					outdated: false,
					reason: "unresolved_thread"
				}
			],
			actionable_top_level: [],
			unacknowledged_actionable: [],
			acknowledgements: []
		}
		@runtime.define_singleton_method( :wait_for_review_warmup ) { |**| snapshot }
		@runtime.define_singleton_method( :wait_for_review_poll ) { nil }
		@runtime.define_singleton_method( :review_gate_snapshot ) { |**| snapshot }

		report = @runtime.send(
			:review_gate_report_for_pr,
			owner: "acme",
			repo: "widgets",
			pr_number: 12,
			branch_name: "feature/test",
			pr_summary: {
				number: 12,
				title: "Test PR",
				url: "https://github.com/acme/widgets/pull/12",
				state: "OPEN"
			}
		)

		assert_equal "block", report.fetch( :status )
		assert_equal true, report.fetch( :converged )
		assert_includes report.fetch( :block_reasons ), "unresolved review threads remain (1)"
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
			assert_equal 51, call_count
		end

		def test_recent_pull_requests_for_sweep_allows_exact_boundary_when_probe_page_is_empty
			call_count = 0
			@runtime.define_singleton_method( :gh_run ) do |*|
				call_count += 1
				if call_count == 51
					[ "[]", "", true, 0 ]
				else
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
			end

			results = @runtime.send(
				:recent_pull_requests_for_sweep,
				owner: "acme",
				repo: "widgets",
				cutoff_time: Time.utc( 2026, 2, 1 )
			)

			assert_equal 50, results.length
			assert_equal 51, call_count
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

		evidence, error_text = @runtime.send( :merged_pr_for_branch,
			branch: "feature/huge-pagination",
			branch_tip_sha: "abc123"
		)

			assert_nil evidence
			assert_match( /pagination safety limit/, error_text )
			assert_equal 51, call_count
		end

		def test_merged_pr_for_branch_allows_exact_boundary_when_probe_page_is_empty
			call_count = 0
			@runtime.define_singleton_method( :repository_coordinates ) { [ "acme", "widgets" ] }
			@runtime.define_singleton_method( :gh_run ) do |*|
				call_count += 1
				if call_count == 51
					[ "[]", "", true, 0 ]
				else
					payload = [
						{
							"head" => { "ref" => "other-branch", "sha" => "no-match" },
							"base" => { "ref" => "main" }
						}
					]
					[ JSON.generate( payload ), "", true, 0 ]
				end
			end

			evidence, error_text = @runtime.send(
				:merged_pr_for_branch,
				branch: "feature/huge-pagination",
				branch_tip_sha: "abc123"
			)

			assert_nil evidence
			assert_match( /no merged PR evidence/, error_text )
			assert_equal 51, call_count
		end

		def test_merged_pr_for_branch_ignores_closed_unmerged_matches
			call_count = 0
			@runtime.define_singleton_method( :repository_coordinates ) { [ "acme", "widgets" ] }
			@runtime.define_singleton_method( :gh_run ) do |*|
				call_count += 1
				if call_count == 1
					payload = [
						{
							"number" => 12,
							"html_url" => "https://github.com/acme/widgets/pull/12",
							"merged_at" => nil,
							"closed_at" => "2026-02-20T12:00:00Z",
							"head" => { "ref" => "feature/reap", "sha" => "abc123" },
							"base" => { "ref" => "main" }
						},
						{
							"number" => 11,
							"html_url" => "https://github.com/acme/widgets/pull/11",
							"merged_at" => "2026-02-19T12:00:00Z",
							"closed_at" => "2026-02-19T12:00:00Z",
							"head" => { "ref" => "feature/reap", "sha" => "abc123" },
							"base" => { "ref" => "main" }
						}
					]
					[ JSON.generate( payload ), "", true, 0 ]
				else
					[ "[]", "", true, 0 ]
				end
			end

			evidence, error_text = @runtime.send(
				:merged_pr_for_branch,
				branch: "feature/reap",
				branch_tip_sha: "abc123"
			)

			assert_nil error_text
			assert_equal 11, evidence.fetch( :number )
			assert_equal "2026-02-19T12:00:00Z", evidence.fetch( :merged_at )
			assert_equal 2, call_count
		end

		def test_abandoned_pr_for_branch_returns_latest_closed_unmerged_match
			call_count = 0
			@runtime.define_singleton_method( :repository_coordinates ) { [ "acme", "widgets" ] }
			@runtime.define_singleton_method( :gh_run ) do |*|
				call_count += 1
				if call_count == 1
					payload = [
						{
							"number" => 21,
							"html_url" => "https://github.com/acme/widgets/pull/21",
							"merged_at" => nil,
							"closed_at" => "2026-02-18T12:00:00Z",
							"head" => { "ref" => "feature/reap", "sha" => "abc123" },
							"base" => { "ref" => "main" }
						},
						{
							"number" => 22,
							"html_url" => "https://github.com/acme/widgets/pull/22",
							"merged_at" => nil,
							"closed_at" => "2026-02-20T12:00:00Z",
							"head" => { "ref" => "feature/reap", "sha" => "abc123" },
							"base" => { "ref" => "main" }
						},
						{
							"number" => 23,
							"html_url" => "https://github.com/acme/widgets/pull/23",
							"merged_at" => "2026-02-19T12:00:00Z",
							"closed_at" => "2026-02-19T12:00:00Z",
							"head" => { "ref" => "feature/reap", "sha" => "abc123" },
							"base" => { "ref" => "main" }
						}
					]
					[ JSON.generate( payload ), "", true, 0 ]
				else
					[ "[]", "", true, 0 ]
				end
			end

			evidence, error_text = @runtime.send(
				:abandoned_pr_for_branch,
				branch: "feature/reap",
				branch_tip_sha: "abc123"
			)

			assert_nil error_text
			assert_equal 22, evidence.fetch( :number )
			assert_equal "2026-02-20T12:00:00Z", evidence.fetch( :closed_at )
			assert_nil evidence.fetch( :merged_at )
			assert_equal 2, call_count
		end

		def test_bot_username_matches_with_and_without_bot_suffix
			# GraphQL returns "gemini-code-assist"; REST returns "gemini-code-assist[bot]".
			# Both must match against the config default "gemini-code-assist[bot]".
			assert @runtime.send( :bot_username?, author: "gemini-code-assist[bot]" )
			assert @runtime.send( :bot_username?, author: "gemini-code-assist" )
			assert @runtime.send( :bot_username?, author: "Gemini-Code-Assist" )
			assert @runtime.send( :bot_username?, author: "github-actions[bot]" )
			assert @runtime.send( :bot_username?, author: "github-actions" )
			refute @runtime.send( :bot_username?, author: "random-user" )
		end
	end
