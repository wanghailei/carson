# Carson govern — portfolio-level triage loop.
# Scans repos, lists open PRs, classifies each, takes the right action, reports.
require "json"
require "time"
require "fileutils"

module Carson
	class Runtime
		module Govern
			GOVERN_REPORT_MD = "govern_latest.md".freeze
			GOVERN_REPORT_JSON = "govern_latest.json".freeze

			TRIAGE_READY = "ready".freeze
			TRIAGE_CI_FAILING = "ci_failing".freeze
			TRIAGE_REVIEW_BLOCKED = "review_blocked".freeze
			TRIAGE_NEEDS_ATTENTION = "needs_attention".freeze

			# Portfolio-level entry point. Scans configured repos (or current repo)
			# and triages all open PRs. Returns EXIT_OK/EXIT_ERROR.
			def govern!( dry_run: false, json_output: false )
				print_header "Carson Govern"
				repos = governed_repo_paths
				if repos.empty?
					puts_line "governing current repository: #{repo_root}"
					repos = [ repo_root ]
				else
					puts_line "governing #{repos.length} repo#{plural_suffix( count: repos.length )}"
				end

				portfolio_report = {
					cycle_at: Time.now.utc.iso8601,
					dry_run: dry_run,
					repos: []
				}

				repos.each do |repo_path|
					repo_report = govern_repo!( repo_path: repo_path, dry_run: dry_run )
					portfolio_report[ :repos ] << repo_report
				end

				write_govern_report( report: portfolio_report )

				if json_output
					puts_line JSON.pretty_generate( portfolio_report )
				else
					print_govern_summary( report: portfolio_report )
				end

				EXIT_OK
			rescue StandardError => e
				puts_line "ERROR: govern failed — #{e.message}"
				EXIT_ERROR
			end

			# Standalone housekeep: sync + prune.
			def housekeep!
				print_header "Housekeep"
				sync_status = sync!
				if sync_status != EXIT_OK
					puts_line "housekeep: sync returned #{sync_status}; skipping prune."
					return sync_status
				end
				prune!
			end

		private

			# Resolves the list of repo paths to govern from config.
			def governed_repo_paths
				config.govern_repos.map do |path|
					expanded = File.expand_path( path )
					unless Dir.exist?( expanded )
						puts_line "WARN: governed repo path does not exist: #{expanded}"
						next nil
					end
					expanded
				end.compact
			end

			# Governs a single repository: list open PRs, triage each.
			def govern_repo!( repo_path:, dry_run: )
				puts_line ""
				puts_line "--- #{repo_path} ---"
				repo_report = {
					repo: repo_path,
					prs: [],
					error: nil
				}

				unless Dir.exist?( repo_path )
					repo_report[ :error ] = "path does not exist"
					puts_line "ERROR: #{repo_path} does not exist"
					return repo_report
				end

				prs = list_open_prs( repo_path: repo_path )
				if prs.nil?
					repo_report[ :error ] = "failed to list open PRs"
					puts_line "ERROR: failed to list open PRs for #{repo_path}"
					return repo_report
				end

				if prs.empty?
					puts_line "no open PRs"
					return repo_report
				end

				puts_line "open PRs: #{prs.length}"
				prs.each do |pr|
					pr_report = triage_pr!( pr: pr, repo_path: repo_path, dry_run: dry_run )
					repo_report[ :prs ] << pr_report
				end

				repo_report
			end

			# Lists open PRs via gh CLI.
			def list_open_prs( repo_path: )
				stdout_text, stderr_text, status = Open3.capture3(
					"gh", "pr", "list", "--state", "open",
					"--json", "number,title,headRefName,statusCheckRollup,reviewDecision,url",
					chdir: repo_path
				)
				unless status.success?
					error_text = stderr_text.to_s.strip
					puts_line "gh pr list failed: #{error_text}" unless error_text.empty?
					return nil
				end
				JSON.parse( stdout_text )
			rescue JSON::ParserError => e
				puts_line "gh pr list returned invalid JSON: #{e.message}"
				nil
			end

			# Classifies a PR and takes appropriate action.
			def triage_pr!( pr:, repo_path:, dry_run: )
				number = pr[ "number" ]
				title = pr[ "title" ].to_s
				branch = pr[ "headRefName" ].to_s
				url = pr[ "url" ].to_s

				pr_report = {
					number: number,
					title: title,
					branch: branch,
					url: url,
					classification: nil,
					action: nil,
					detail: nil
				}

				classification, detail = classify_pr( pr: pr, repo_path: repo_path )
				pr_report[ :classification ] = classification
				pr_report[ :detail ] = detail

				action = decide_action( classification: classification, dry_run: dry_run )
				pr_report[ :action ] = action

				puts_line "  PR ##{number} (#{branch}): #{classification} → #{action}"
				puts_line "    #{detail}" unless detail.to_s.empty?

				execute_action!( action: action, pr: pr, repo_path: repo_path, dry_run: dry_run ) unless dry_run

				pr_report
			end

			# Classifies PR state by checking CI, review status, and audit readiness.
			def classify_pr( pr:, repo_path: )
				ci_status = check_ci_status( pr: pr )
				return [ TRIAGE_CI_FAILING, "CI checks failing or pending" ] unless ci_status == :green

				review_decision = pr[ "reviewDecision" ].to_s.upcase
				if review_decision == "CHANGES_REQUESTED"
					return [ TRIAGE_REVIEW_BLOCKED, "changes requested by reviewer" ]
				end

				# Run audit and review gate checks for deeper analysis
				audit_status, audit_detail = check_audit_status( pr: pr, repo_path: repo_path )
				return [ TRIAGE_NEEDS_ATTENTION, audit_detail ] unless audit_status == :pass

				review_status, review_detail = check_review_gate_status( pr: pr, repo_path: repo_path )
				return [ TRIAGE_REVIEW_BLOCKED, review_detail ] unless review_status == :pass

				[ TRIAGE_READY, "all gates pass" ]
			end

			# Checks CI status from PR's statusCheckRollup.
			def check_ci_status( pr: )
				checks = Array( pr[ "statusCheckRollup" ] )
				return :green if checks.empty?

				has_failure = checks.any? { |c| check_state_failing?( state: c[ "state" ].to_s ) || check_conclusion_failing?( conclusion: c[ "conclusion" ].to_s ) }
				return :red if has_failure

				has_pending = checks.any? { |c| check_state_pending?( state: c[ "state" ].to_s ) }
				return :pending if has_pending

				:green
			end

			def check_state_failing?( state: )
				[ "FAILURE", "ERROR" ].include?( state.upcase )
			end

			def check_conclusion_failing?( conclusion: )
				[ "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED" ].include?( conclusion.upcase )
			end

			def check_state_pending?( state: )
				[ "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED" ].include?( state.upcase )
			end

			# Checks if the PR's branch is available locally and defers audit. Returns [:pass/:fail, detail].
			def check_audit_status( pr:, repo_path: )
				branch = pr[ "headRefName" ].to_s
				stdout_text, stderr_text, status = Open3.capture3(
					"git", "rev-parse", "--verify", "refs/heads/#{branch}",
					chdir: repo_path
				)
				unless status.success?
					return [ :pass, "branch not local; skipping audit" ]
				end

				[ :pass, "audit deferred to merge gate" ]
			end

			# Checks review gate status. Returns [:pass/:fail, detail].
			def check_review_gate_status( pr:, repo_path: )
				review_decision = pr[ "reviewDecision" ].to_s.upcase
				case review_decision
				when "APPROVED"
					[ :pass, "approved" ]
				when "CHANGES_REQUESTED"
					[ :fail, "changes requested" ]
				when "REVIEW_REQUIRED"
					[ :fail, "review required" ]
				else
					[ :pass, "no review policy or approved" ]
				end
			end

			# Maps classification to action.
			def decide_action( classification:, dry_run: )
				case classification
				when TRIAGE_READY
					dry_run ? "would_merge" : "merge"
				when TRIAGE_CI_FAILING
					dry_run ? "would_dispatch_ci_fix" : "dispatch_ci_fix"
				when TRIAGE_REVIEW_BLOCKED
					dry_run ? "would_dispatch_review_fix" : "dispatch_review_fix"
				when TRIAGE_NEEDS_ATTENTION
					"escalate"
				else
					"skip"
				end
			end

			# Executes the decided action on a PR.
			def execute_action!( action:, pr:, repo_path:, dry_run: )
				case action
				when "merge"
					merge_if_ready!( pr: pr, repo_path: repo_path )
				when "dispatch_ci_fix"
					dispatch_agent!( pr: pr, repo_path: repo_path, objective: "fix_ci" )
				when "dispatch_review_fix"
					dispatch_agent!( pr: pr, repo_path: repo_path, objective: "address_review" )
				when "escalate"
					puts_line "    ESCALATE: PR ##{pr[ 'number' ]} needs human attention"
				end
			end

			# Merges a PR that has passed all gates.
			def merge_if_ready!( pr:, repo_path: )
				unless config.govern_merge_authority
					puts_line "    merge authority disabled; skipping merge"
					return
				end

				method = config.govern_merge_method
				number = pr[ "number" ]
				stdout_text, stderr_text, status = Open3.capture3(
					"gh", "pr", "merge", number.to_s,
					"--#{method}",
					"--delete-branch",
					chdir: repo_path
				)
				if status.success?
					puts_line "    merged PR ##{number} via #{method}"
					housekeep_repo!( repo_path: repo_path )
				else
					error_text = stderr_text.to_s.strip
					puts_line "    merge failed: #{error_text}"
				end
			end

			# Dispatches an agent to fix an issue on a PR.
			def dispatch_agent!( pr:, repo_path:, objective: )
				state = load_dispatch_state
				state_key = dispatch_state_key( pr: pr, repo_path: repo_path )

				existing = state[ state_key ]
				if existing && existing[ "status" ] == "running"
					puts_line "    agent already dispatched for #{objective}; skipping"
					return
				end

				provider = select_agent_provider
				unless provider
					puts_line "    no agent provider available; escalating"
					return
				end

				work_order = Adapters::Agent::WorkOrder.new(
					repo: repo_path,
					branch: pr[ "headRefName" ].to_s,
					pr_number: pr[ "number" ],
					objective: objective,
					context: pr.fetch( "title", "" ),
					acceptance_checks: nil
				)

				puts_line "    dispatching #{provider} agent for #{objective}"
				adapter = build_agent_adapter( provider: provider, repo_path: repo_path )
				result = adapter.dispatch( work_order: work_order )

				state[ state_key ] = {
					"objective" => objective,
					"provider" => provider,
					"dispatched_at" => Time.now.utc.iso8601,
					"status" => result.status == "done" ? "done" : "failed",
					"summary" => result.summary
				}
				save_dispatch_state( state: state )

				puts_line "    agent result: #{result.status} — #{result.summary.to_s[0, 120]}"
			end

			# Runs housekeep in the given repo after a successful merge.
			def housekeep_repo!( repo_path: )
				if repo_path == self.repo_root
					housekeep!
				else
					rt = Runtime.new( repo_root: repo_path, tool_root: tool_root, out: out, err: err )
					rt.housekeep!
				end
			end

			# Selects which agent provider to use based on config and availability.
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

			# Dispatch state persistence.
			def load_dispatch_state
				path = config.govern_dispatch_state_path
				return {} unless File.file?( path )

				JSON.parse( File.read( path ) )
			rescue JSON::ParserError
				{}
			end

			def save_dispatch_state( state: )
				path = config.govern_dispatch_state_path
				FileUtils.mkdir_p( File.dirname( path ) )
				File.write( path, JSON.pretty_generate( state ) )
			end

			def dispatch_state_key( pr:, repo_path: )
				dir_name = File.basename( repo_path )
				"#{dir_name}##{pr[ 'number' ]}"
			end

			# Report writing.
			def write_govern_report( report: )
				report_dir = report_dir_path
				FileUtils.mkdir_p( report_dir )
				json_path = File.join( report_dir, GOVERN_REPORT_JSON )
				md_path = File.join( report_dir, GOVERN_REPORT_MD )
				File.write( json_path, JSON.pretty_generate( report ) )
				File.write( md_path, render_govern_markdown( report: report ) )
				puts_line "report_json: #{json_path}"
				puts_line "report_markdown: #{md_path}"
			end

			def render_govern_markdown( report: )
				lines = []
				lines << "# Carson Govern Report"
				lines << ""
				lines << "**Cycle**: #{report[ :cycle_at ]}"
				lines << "**Dry run**: #{report[ :dry_run ]}"
				lines << ""

				Array( report[ :repos ] ).each do |repo_report|
					lines << "## #{repo_report[ :repo ]}"
					lines << ""
					if repo_report[ :error ]
						lines << "**Error**: #{repo_report[ :error ]}"
						lines << ""
						next
					end

					prs = Array( repo_report[ :prs ] )
					if prs.empty?
						lines << "No open PRs."
						lines << ""
						next
					end

					prs.each do |pr|
						lines << "### PR ##{pr[ :number ]} — #{pr[ :title ]}"
						lines << ""
						lines << "- **Branch**: #{pr[ :branch ]}"
						lines << "- **Classification**: #{pr[ :classification ]}"
						lines << "- **Action**: #{pr[ :action ]}"
						lines << "- **Detail**: #{pr[ :detail ]}" unless pr[ :detail ].to_s.empty?
						lines << ""
					end
				end

				lines.join( "\n" )
			end

			def print_govern_summary( report: )
				puts_line ""
				total_prs = 0
				ready_count = 0
				blocked_count = 0

				Array( report[ :repos ] ).each do |repo_report|
					Array( repo_report[ :prs ] ).each do |pr|
						total_prs += 1
						case pr[ :classification ]
						when TRIAGE_READY
							ready_count += 1
						else
							blocked_count += 1
						end
					end
				end

				repos_count = Array( report[ :repos ] ).length
				puts_line "govern_summary: repos=#{repos_count} prs=#{total_prs} ready=#{ready_count} blocked=#{blocked_count}"
			end
		end

		include Govern
	end
end
