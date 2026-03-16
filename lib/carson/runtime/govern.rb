# Carson govern — portfolio-wide oversight over branch deliveries.
# Govern reassesses queued/gated deliveries, records revision cycles, and integrates one ready delivery at a time.
require "json"
require "time"

module Carson
	class Runtime
		module Govern
			# Portfolio-level entry point. Scans governed repos (or the current repo) and advances deliveries.
			def govern!( dry_run: false, json_output: false, loop_seconds: nil )
				if loop_seconds
					govern_loop!( dry_run: dry_run, json_output: json_output, loop_seconds: loop_seconds )
				else
					govern_cycle!( dry_run: dry_run, json_output: json_output )
				end
			end

			def govern_cycle!( dry_run:, json_output: )
				repositories = governed_repo_paths
				repositories = [ repository_record.path ] if repositories.empty?
				print_header "Governing #{repositories.length} repo#{plural_suffix( count: repositories.length )}" unless json_output

				report = {
					cycle_at: Time.now.utc.iso8601,
					dry_run: dry_run,
					repositories: repositories.map { |path| govern_repo!( repo_path: path, dry_run: dry_run, silent: json_output ) }
				}

				if json_output
					output.puts JSON.pretty_generate( report )
				else
					print_govern_summary( report: report )
				end

				EXIT_OK
			rescue StandardError => exception
				puts_line "Govern did not complete: #{exception.message}"
				EXIT_ERROR
			end

			def govern_loop!( dry_run:, json_output:, loop_seconds: )
				cycle_count = 0
				loop do
					cycle_count += 1
					puts_line ""
					puts_line "cycle #{cycle_count} at #{Time.now.utc.strftime( '%Y-%m-%d %H:%M:%S UTC' )}"
					govern_cycle!( dry_run: dry_run, json_output: json_output )
					next_at = Time.now + loop_seconds
					puts_line "sleeping #{loop_seconds}s — next cycle at #{next_at.strftime( '%Y-%m-%d %H:%M:%S %z' )}"
					sleep loop_seconds
				end
			rescue Interrupt
				puts_line "govern loop stopped after #{cycle_count} cycle#{plural_suffix( count: cycle_count )}"
				EXIT_OK
			end

		private

			def governed_repo_paths
				config.govern_repos.map do |path|
					expanded = File.expand_path( path )
					next nil unless Dir.exist?( expanded )
					expanded
				end.compact
			end

			def govern_repo!( repo_path:, dry_run:, silent: false )
				scoped_runtime = repo_runtime_for( repo_path: repo_path )
				repository = Repository.new( path: repo_path, runtime: scoped_runtime )
				deliveries = scoped_runtime.ledger.active_deliveries( repo_path: repo_path )

				repo_report = {
					repository: repository.name,
					path: repo_path,
					deliveries: [],
					error: nil
				}

				if deliveries.empty?
					puts_line "#{repository.name}: no active deliveries" unless silent
					return repo_report
				end

				puts_line "#{repository.name}: #{deliveries.length} active deliver#{deliveries.length == 1 ? 'y' : 'ies'}" unless silent

				reconciled = deliveries.map { |item| scoped_runtime.send( :reconcile_delivery!, delivery: item ) }
				next_to_integrate = reconciled.find( &:ready? )&.key

				reconciled.each do |delivery|
					hint = delivery_action_hint( delivery: delivery, next_to_integrate: next_to_integrate, dry_run: dry_run )
					puts_line "  #{delivery.branch} — #{hint}" if hint && !silent
					delivery_report = scoped_runtime.send(
						:decide_delivery_action,
						delivery: delivery,
						repo_path: repo_path,
						dry_run: dry_run,
						next_to_integrate: next_to_integrate
					)
					repo_report[ :deliveries ] << delivery_report
				end

				repo_report
			rescue StandardError => exception
				if defined?( repo_report ) && repo_report.is_a?( Hash )
					repo_report[ :error ] = exception.message
					repo_report
				else
					{ repository: File.basename( repo_path ), path: repo_path, deliveries: [], error: exception.message }
				end
			end

			def reconcile_delivery!( delivery: )
				branch = repository_record.branch( delivery.branch ).reload
				if branch.head && branch.head != delivery.head
					return ledger.update_delivery(
						delivery: delivery,
						status: "superseded",
						superseded_at: Time.now.utc.iso8601,
						summary: "branch head advanced to #{branch.head}; run carson deliver again"
					)
				end

				pr_state = pull_request_state( number: delivery.pull_request_number )
				if pr_state && pr_state[ "state" ] == "MERGED"
					return ledger.update_delivery(
						delivery: delivery,
						status: "integrated",
						integrated_at: Time.now.utc.iso8601,
						summary: "integrated into #{config.main_branch}",
						pull_request_state: "MERGED",
						pull_request_draft: false,
						pull_request_merged_at: pr_state[ "mergedAt" ]
					)
				end

				if pr_state && pr_state[ "state" ] == "CLOSED"
					return ledger.update_delivery(
						delivery: delivery,
						status: "failed",
						cause: "policy",
						summary: "pull request closed without integration",
						pull_request_state: "CLOSED",
						pull_request_draft: pr_state[ "isDraft" ],
						pull_request_merged_at: pr_state[ "mergedAt" ]
					)
				end

				assess_delivery!( delivery: delivery, branch_name: delivery.branch )
			end

				def decide_delivery_action( delivery:, repo_path:, dry_run:, next_to_integrate: )
					report = {
						key: delivery.key,
						branch: delivery.branch,
						status: delivery.status,
						cause: delivery.cause,
						summary: delivery.summary,
						revision_count: delivery.revision_count,
						action: "none"
					}

				if delivery.superseded? || delivery.integrated? || delivery.failed?
					return report
				end

					if delivery.ready? && delivery.key == next_to_integrate
						report[ :action ] = dry_run ? "would_integrate" : "integrate"
						unless dry_run
							updated = execute_delivery_action!( action: report[ :action ], delivery: delivery, repo_path: repo_path, dry_run: dry_run )
							report[ :status ] = updated.status
							report[ :cause ] = updated.cause
							report[ :summary ] = updated.summary
							report[ :merge_proof ] = merge_proof_payload( proof: updated.merge_proof ) if updated.integrated? && updated.merge_proof
						end
						return report
					end

					if delivery.blocked?
						if held_delivery?( delivery: delivery )
							report[ :action ] = dry_run ? "would_hold" : "hold"
							return report
						end

						if delivery.revision_count >= 3
							report[ :action ] = dry_run ? "would_escalate" : "escalate"
							unless dry_run
								updated = execute_delivery_action!( action: report[ :action ], delivery: delivery, repo_path: repo_path, dry_run: dry_run )
								report[ :status ] = updated.status
								report[ :cause ] = updated.cause
								report[ :summary ] = updated.summary
							end
						else
							report[ :action ] = dry_run ? "would_revise" : "revise"
							unless dry_run
								updated = execute_delivery_action!( action: report[ :action ], delivery: delivery, repo_path: repo_path, dry_run: dry_run )
								report[ :status ] = updated.status
								report[ :cause ] = updated.cause
								report[ :summary ] = updated.summary
							end
						end
					end

				report
			end

			def execute_delivery_action!( action:, delivery:, repo_path:, dry_run: )
				return delivery if dry_run

				case action
				when "integrate"
					integrate_delivery!( delivery: delivery, repo_path: repo_path )
				when "revise"
					revise_delivery!( delivery: delivery, repo_path: repo_path )
				when "escalate"
					escalate_delivery!( delivery: delivery, reason: "revision limit reached" )
				else
					delivery
				end
			end

				def integrate_delivery!( delivery:, repo_path: )
					result = {}
					freshness = assess_branch_freshness(
						head_ref: delivery.head || delivery.branch,
						remote: config.git_remote,
						main: config.main_branch
					)
					unless freshness.fetch( :ready )
						return ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: "freshness",
							summary: freshness.fetch( :summary )
						)
					end

					prepared = ledger.update_delivery(
						delivery: delivery,
						status: "integrating",
						summary: "integrating into #{config.main_branch}"
					)
				merge_exit = merge_pr!( number: prepared.pull_request_number, result: result )
				if merge_exit == EXIT_OK
					integrated = ledger.update_delivery(
						delivery: prepared,
						status: "integrated",
						integrated_at: Time.now.utc.iso8601,
						summary: "integrated into #{config.main_branch}",
						pull_request_state: "MERGED",
						pull_request_draft: false,
						pull_request_merged_at: Time.now.utc.iso8601
					)
					# Fetch-only: update the remote tracking ref without mutating the
					# main worktree. Reap and prune are deferred to explicit housekeep.
					fetch_for_merge_proof!( repo_path: repo_path )
					proof = merge_proof_for_remote_ref( branch: integrated.branch )
					ledger.update_delivery(
						delivery: integrated,
						merge_proof: proof
					)
				else
					ledger.update_delivery(
						delivery: prepared,
						status: "gated",
						cause: "policy",
						summary: result.fetch( :error, "merge failed" )
					)
				end
			end

			def revise_delivery!( delivery:, repo_path: )
				provider = select_agent_provider
				return escalate_delivery!( delivery: delivery, reason: "no agent provider available" ) if provider.nil?
				return escalate_delivery!( delivery: delivery, reason: "worktree missing for revision" ) unless File.directory?( delivery.worktree_path.to_s )

				# Defer if the target worktree is occupied — temporary hold, not failure.
				worktree = Carson::Worktree.find( path: delivery.worktree_path.to_s, runtime: self )
				if worktree
					if worktree.held_by_other_process?
						return ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: "busy",
							summary: "worktree held by another process — deferring revision"
						)
					end
					if worktree.dirty?
						return ledger.update_delivery(
							delivery: delivery,
							status: "gated",
							cause: "busy",
							summary: "worktree has uncommitted changes — deferring revision"
						)
					end
				end

				objective = revision_objective( cause: delivery.cause )
				context = evidence( delivery: delivery, repo_path: repo_path, objective: objective )
				work_order = Adapters::Agent::WorkOrder.new(
					repo: repo_path,
					branch: delivery.branch,
					pr_number: delivery.pull_request_number,
					objective: objective,
					context: context,
					acceptance_checks: nil
				)

				result = build_agent_adapter( provider: provider, repo_path: delivery.worktree_path ).dispatch( work_order: work_order )
				revision = ledger.record_revision(
					delivery: delivery,
					cause: delivery.cause || "policy",
					provider: provider,
					status: revision_status_for( result: result ),
					summary: result.summary
				)

				if revision.completed?
					updated = ledger.update_delivery(
						delivery: delivery,
						status: "gated",
						summary: "revision #{revision.number} completed — waiting for reassessment"
					)
					return reconcile_delivery!( delivery: updated )
				end

				if revision.number >= 3
					escalate_delivery!( delivery: delivery, reason: "revision #{revision.number} failed: #{result.summary}" )
				else
					ledger.update_delivery(
						delivery: delivery,
						status: "gated",
						summary: "revision #{revision.number} failed: #{result.summary}"
					)
				end
			end

			def escalate_delivery!( delivery:, reason: )
				ledger.update_delivery(
					delivery: delivery,
					status: "escalated",
					cause: delivery.cause || "policy",
					summary: reason
				)
			end

			def revision_objective( cause: )
				case cause
				when "ci" then "fix_ci"
				when "review" then "address_review"
				else "fix_audit"
				end
			end

			def revision_status_for( result: )
				case result.status
				when "done" then "completed"
				when "timeout" then "stalled"
				else "failed"
				end
			end

				def held_delivery?( delivery: )
					[ "merge", "freshness", "busy" ].include?( delivery.cause )
				end

				def delivery_action_hint( delivery:, next_to_integrate:, dry_run: )
					return nil if dry_run
					return nil if delivery.superseded? || delivery.integrated? || delivery.failed?
					return "integrating…" if delivery.ready? && delivery.key == next_to_integrate
					return nil unless delivery.blocked?
					return nil if held_delivery?( delivery: delivery )
					delivery.revision_count >= 3 ? "escalating…" : "revising…"
				end

			def housekeep_repo!( repo_path: )
				scoped_runtime = repo_runtime_for( repo_path: repo_path )
				scoped_runtime.send( :housekeep_one_entry, repo_path: repo_path, silent: true )
			end

			# Fetch-only helper for post-merge proof generation.
			# Updates the remote tracking ref without mutating the main worktree.
			def fetch_for_merge_proof!( repo_path: )
				scoped = repo_runtime_for( repo_path: repo_path )
				scoped.send( :git_run, "fetch", scoped.config.git_remote, "--prune" )
			rescue StandardError
				# Best-effort — merge proof falls back to unavailable if fetch fails.
			end

			def select_agent_provider
				provider = config.govern_agent_provider
				case provider
				when "codex"
					command_available?( "codex" ) ? "codex" : nil
				when "claude"
					command_available?( "claude" ) ? "claude" : nil
				when "auto"
					return "codex" if command_available?( "codex" )
					return "claude" if command_available?( "claude" )
					nil
				else
					nil
				end
			end

			def command_available?( name )
				_, _, status = Open3.capture3( "which", name )
				status.success?
			end

			def build_agent_adapter( provider:, repo_path: )
				case provider
				when "codex"
					Adapters::Codex.new( repo_root: repo_path )
				when "claude"
					Adapters::Claude.new( repo_root: repo_path )
				else
					raise "unknown agent provider: #{provider}"
				end
			end

			def evidence( delivery:, repo_path:, objective: )
				context = { title: delivery.summary.to_s }
				case objective
				when "fix_ci"
					context.merge!( ci_evidence( delivery: delivery, repo_path: repo_path ) )
				when "address_review"
					context.merge!( review_evidence( delivery: delivery, repo_path: repo_path ) )
				end
				prior = prior_attempt( delivery: delivery )
				context[ :prior_attempt ] = prior if prior
				context
			rescue StandardError => exception
				puts_line "evidence gathering failed for #{delivery.branch}: #{exception.message}"
				{ title: delivery.summary.to_s }
			end

			CI_LOG_LIMIT = 8_000

			def ci_evidence( delivery:, repo_path: )
				branch = delivery.branch
				stdout_text, _, status = Open3.capture3(
					"gh", "run", "list",
					"--branch", branch,
					"--status", "failure",
					"--limit", "1",
					"--json", "databaseId,url",
					chdir: repo_path
				)
				return {} unless status.success?

				runs = JSON.parse( stdout_text )
				return {} if runs.empty?

				run_id = runs.first[ "databaseId" ].to_s
				run_url = runs.first[ "url" ].to_s
				log_stdout, _, log_status = Open3.capture3( "gh", "run", "view", run_id, "--log-failed", chdir: repo_path )
				return { ci_run_url: run_url } unless log_status.success?

				{ ci_logs: truncate_log( text: log_stdout ), ci_run_url: run_url }
			end

			def truncate_log( text:, limit: CI_LOG_LIMIT )
				text = text.to_s
				return text if text.length <= limit
				text[ -limit.. ]
			end

			def review_evidence( delivery:, repo_path: )
				repo_runtime = repo_runtime_for( repo_path: repo_path )
				owner, repo = repo_runtime.send( :repository_coordinates )
				details = repo_runtime.send( :pull_request_details, owner: owner, repo: repo, pr_number: delivery.pull_request_number )
				pr_author = details.dig( :author, :login ).to_s
				threads = repo_runtime.send( :unresolved_thread_entries, details: details )
				top_level = repo_runtime.send( :actionable_top_level_items, details: details, pr_author: pr_author )

				findings = []
				threads.each do |entry|
					body = thread_body( details: details, url: entry[ :url ] )
					findings << { kind: "unresolved_thread", url: entry[ :url ], body: body }
				end
				top_level.each do |entry|
					body = comment_body( details: details, url: entry[ :url ] )
					findings << { kind: entry[ :kind ], url: entry[ :url ], body: body }
				end

				{ review_findings: findings }
			end

			def prior_attempt( delivery: )
				revision = delivery.revisions.last
				return nil unless revision&.failed?
				{ summary: revision.summary.to_s, dispatched_at: revision.started_at.to_s }
			end

			def repo_runtime_for( repo_path: )
				realpath_safe( repo_path ) == realpath_safe( repo_root ) ? self : build_scoped_runtime( repo_path: repo_path )
			end

			def thread_body( details:, url: )
				Array( details[ :review_threads ] ).each do |thread|
					thread[ :comments ].each do |comment|
						return comment[ :body ].to_s if comment[ :url ] == url
					end
				end
				""
			end

			def comment_body( details:, url: )
				Array( details[ :comments ] ).each do |comment|
					return comment[ :body ].to_s if comment[ :url ] == url
				end
				Array( details[ :reviews ] ).each do |review|
					return review[ :body ].to_s if review[ :url ] == url
				end
				""
			end

			def print_govern_summary( report: )
				Array( report[ :repositories ] ).each do |repo_report|
					if repo_report[ :error ]
						puts_line "#{repo_report[ :repository ]}: #{repo_report[ :error ]}"
						next
					end

					next if repo_report[ :deliveries ].empty?

						repo_report[ :deliveries ].each do |delivery|
							action_text = format_govern_action( status: delivery[ :status ], action: delivery[ :action ], cause: delivery[ :cause ] )
							puts_line "#{repo_report[ :repository ]}/#{delivery[ :branch ]} — #{action_text}"
							puts_line "  #{delivery[ :summary ]}" unless delivery[ :summary ].to_s.empty?
							puts_line "  Merge proof: #{delivery.dig( :merge_proof, :summary )}" if delivery[ :merge_proof ]
						end
					end
				end

				def format_govern_action( status:, action:, cause: )
					case action
					when "integrate"
						format_govern_integration_outcome( status: status, cause: cause )
					when "would_integrate" then "ready to integrate (dry run)"
					when "hold" then cause == "freshness" ? "refresh required" : "held at gate"
					when "would_hold" then cause == "freshness" ? "would require refresh (dry run)" : "would hold at gate (dry run)"
					when "revise" then "revision dispatched"
					when "would_revise" then "would revise (dry run)"
				when "escalate" then "escalated"
				when "would_escalate" then "would escalate (dry run)"
				else status
				end
			end

				def format_govern_integration_outcome( status:, cause: )
					case status
					when "integrated" then "integrated"
					when "gated" then cause == "freshness" ? "refresh required" : "held at gate"
					when "failed" then "integration failed"
					when "escalated" then "integration escalated"
					else status
				end
			end
		end

		include Govern
	end
end
