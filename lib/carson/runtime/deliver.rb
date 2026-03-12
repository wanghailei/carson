# PR delivery lifecycle — push, create or reuse PR, wait for readiness, merge, then sync local main.
# `carson deliver` is the full post-commit stream.
# `carson deliver --pr-only` is the explicit escape hatch for PR creation without merge/watch.
module Carson
	class Runtime
		module Deliver
			DELIVER_WATCH_CAP_SECONDS = 5

			def deliver!( pr_only: false, merge: false, title: nil, body_file: nil, json_output: false )
				branch = current_branch
				main = config.main_branch
				remote = config.git_remote
				result = { command: "deliver", branch: branch, status: "starting" }

				if branch == main
					result[ :error ] = "cannot deliver from #{main}"
					result[ :recovery ] = "carson worktree create <name>"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				unless send( :working_tree_clean? )
					result[ :error ] = "working tree is dirty"
					result[ :recovery ] = "git add -A && git commit, then carson deliver"
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				end

				push_exit = push_branch!( branch: branch, remote: remote, result: result )
				return deliver_finish( result: result, exit_code: push_exit, json_output: json_output ) unless push_exit == EXIT_OK

				pr_number, pr_url = find_or_create_pr!(
					branch: branch, title: title, body_file: body_file, result: result
				)
				return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output ) if pr_number.nil?

				result[ :pr_number ] = pr_number
				result[ :pr_url ] = pr_url

				if pr_only
					result[ :status ] = "pr_open"
					result[ :recovery ] = "carson deliver"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				end

				readiness = wait_for_deliver_readiness!( pr_number: pr_number, result: result )
				case readiness.fetch( :state )
				when :pending
					result[ :status ] = "pending"
					result[ :recovery ] = "carson deliver or carson govern"
					return deliver_finish( result: result, exit_code: EXIT_OK, json_output: json_output )
				when :block
					result[ :status ] = "blocked"
					result[ :error ] = readiness.fetch( :detail )
					result[ :recovery ] = readiness.fetch( :recovery )
					return deliver_finish( result: result, exit_code: EXIT_BLOCK, json_output: json_output )
				when :error
					result[ :status ] = "error"
					result[ :error ] = readiness.fetch( :detail )
					result[ :recovery ] = readiness.fetch( :recovery )
					return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
				end

			merge_exit = merge_pr!( number: pr_number, result: result )
			return deliver_finish( result: result, exit_code: merge_exit, json_output: json_output ) unless merge_exit == EXIT_OK

				result[ :merged ] = true
				synced = sync_after_merge!( remote: remote, main: main, result: result )
				compute_post_merge_next_step!( result: result )
				result[ :status ] = synced ? "merged" : "merged_unsynced"

				exit_code = synced ? EXIT_OK : EXIT_ERROR
				deliver_finish( result: result, exit_code: exit_code, json_output: json_output )
			end

		private

			def deliver_finish( result:, exit_code:, json_output: )
				result[ :exit_code ] = exit_code

				if json_output
					output.puts JSON.pretty_generate( result )
				else
					print_deliver_human( result: result )
				end

				exit_code
			end

			def print_deliver_human( result: )
				if result[ :error ] && !result[ :merged ]
					puts_line result.fetch( :error )
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
					return
				end

				if result[ :pr_number ]
					puts_line "PR: ##{result[ :pr_number ]} #{result[ :pr_url ]}"
				end

				print_deliver_ci_review( result: result )

				case result[ :status ]
				when "pr_open"
					puts_line "PR updated — merge deferred."
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
				when "pending"
					puts_line "Delivery pending — waiting on checks or review."
					puts_line "  → #{result[ :recovery ]}" if result[ :recovery ]
				when "merged"
					puts_line "Merged PR ##{result[ :pr_number ]} via #{result[ :merge_method ]}."
					puts_line "  Next: #{result[ :next_step ]}" if result[ :next_step ]
				when "merged_unsynced"
					puts_line "Merged PR ##{result[ :pr_number ]} via #{result[ :merge_method ]}, but local #{config.main_branch} did not sync."
					puts_line "  → carson sync"
				end
			end

			def print_deliver_ci_review( result: )
				if result[ :ci ]
					case result[ :ci ]
					when "pass"
						puts_line "CI: pass"
					when "none"
						puts_line "CI: none — no checks configured"
					when "pending"
						puts_line "CI: pending"
					when "fail"
						puts_line "CI: failing"
					end
				end

				if result[ :review ]
					case result[ :review ]
					when "pass"
						puts_line "Review: pass"
					when "pending"
						puts_line "Review: pending"
					when "block"
						puts_line "Review: blocked"
					end
				end
			end

			def wait_for_deliver_readiness!( pr_number:, result: )
				deadline = Time.now + deliver_watch_seconds
				loop do
					readiness = deliver_readiness( pr_number: pr_number )
					result[ :ci ] = readiness[ :ci ].to_s if readiness[ :ci ]
					result[ :review ] = readiness[ :review ].to_s if readiness[ :review ]
					return readiness unless readiness.fetch( :state ) == :pending
					return readiness if Time.now >= deadline
					sleep deliver_poll_interval
				end
			end

			def deliver_watch_seconds
				seconds = config.govern_check_wait.to_i
				seconds = 0 if seconds.negative?
				[ seconds, DELIVER_WATCH_CAP_SECONDS ].min
			end

			def deliver_poll_interval
				interval = config.review_poll_seconds.to_i
				interval = 1 if interval <= 0
				[ interval, deliver_watch_seconds ].reject( &:zero? ).min || 1
			end

			def deliver_readiness( pr_number: )
				ci_status = check_pr_ci( number: pr_number )
				case ci_status
				when :pending
					return { state: :pending, ci: :pending, review: :pending, detail: "checks still running" }
				when :fail
					return {
						state: :block,
						ci: :fail,
						review: :pending,
						detail: "CI checks are failing on PR ##{pr_number}",
						recovery: "fix the failing checks, push, then rerun carson deliver"
					}
				end

				review_state = check_pr_review( number: pr_number )
				if review_state == :changes_requested
					detail_text = "review changes requested on PR ##{pr_number} — actionable review findings remain"
					return {
						state: :block,
						ci: ci_status == :none ? :none : :pass,
						review: :block,
						detail: detail_text,
						recovery: "address review comments, push, then rerun carson deliver"
					}
				end
				if review_state == :review_required
					return {
						state: :pending,
						ci: ci_status == :none ? :none : :pass,
						review: :pending,
						detail: "review approval still required"
					}
				end

				gate = check_pr_review_gate( number: pr_number )
				case gate.fetch( :state )
				when :pass
					{ state: :ready, ci: ci_status == :none ? :none : :pass, review: :pass, detail: gate.fetch( :detail ) }
				when :block
					{
						state: :block,
						ci: ci_status == :none ? :none : :pass,
						review: :block,
						detail: gate.fetch( :detail ),
						recovery: "resolve review blockers, push, then rerun carson deliver"
					}
				else
					{
						state: :error,
						ci: ci_status == :none ? :none : :pass,
						review: :block,
						detail: gate.fetch( :detail ),
						recovery: "run carson review gate, then rerun carson deliver"
					}
				end
			end

			def push_branch!( branch:, remote:, result: )
				_, push_stderr, push_success, = git_run( "push", "--no-verify", "-u", remote, branch )
				if !push_success && push_stderr.to_s.include?( "non-fast-forward" )
					return force_push_with_lease!( branch: branch, remote: remote, result: result )
				end

				unless push_success
					error_text = push_stderr.to_s.strip
					error_text = "push failed" if error_text.empty?
					result[ :error ] = error_text
					return EXIT_ERROR
				end

				puts_verbose "pushed #{branch} to #{remote}"
				EXIT_OK
			end

			def force_push_with_lease!( branch:, remote:, result: )
				puts_verbose "push rejected (non-fast-forward), retrying with --force-with-lease"
				_, lease_stderr, lease_success, = git_run( "push", "--no-verify", "--force-with-lease", "-u", remote, branch )

				if lease_success
					puts_verbose "pushed #{branch} to #{remote} (force-with-lease)"
					return EXIT_OK
				end

				if lease_stderr.to_s.include?( "stale info" )
					result[ :error ] = "force-with-lease rejected — another push landed on #{branch} since your last fetch"
					result[ :recovery ] = "git fetch #{remote} #{branch} && carson deliver"
				else
					error_text = lease_stderr.to_s.strip
					error_text = "push failed (force-with-lease)" if error_text.empty?
					result[ :error ] = error_text
				end
				EXIT_ERROR
			end

			def find_or_create_pr!( branch:, title: nil, body_file: nil, result: )
				existing = find_existing_pr( branch: branch )
				return existing if existing.first

				create_pr!( branch: branch, title: title, body_file: body_file, result: result )
			end

			def find_existing_pr( branch: )
				payload, _, _, success, = github_adapter.run_json(
					"pr", "view", branch,
					"--json", "number,url,state"
				)
				if success && payload.is_a?( Hash ) && payload[ "number" ] && payload[ "state" ] == "OPEN"
					return [ payload[ "number" ], payload[ "url" ].to_s ]
				end
				[ nil, nil ]
			end

			def create_pr!( branch:, title: nil, body_file: nil, result: )
				pr_title = title || default_pr_title( branch: branch )
				args = [ "pr", "create", "--title", pr_title, "--head", branch ]
				if body_file && File.exist?( body_file )
					args.push( "--body-file", body_file )
				else
					args.push( "--body", "" )
				end

				stdout, stderr, success, = gh_run( *args )
				unless success
					error_text = stderr.to_s.strip
					error_text = "pr create failed" if error_text.empty?
					result[ :error ] = error_text
					result[ :recovery ] = "gh pr create --title '#{pr_title}' --head #{branch}"
					return [ nil, nil ]
				end

				pr_url = stdout.to_s.strip
				pr_number = pr_url.split( "/" ).last.to_i
				return [ pr_number, pr_url ] if pr_number.positive?

				find_existing_pr( branch: branch )
			end

			def default_pr_title( branch: )
				branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { it.upcase }
			end

			def check_pr_ci( number: )
				payload, _, _, success, = github_adapter.run_json(
					"pr", "checks", number.to_s,
					"--json", "name,bucket"
				)
				return :none unless success

				checks = Array( payload )
				return :none if checks.empty?

				buckets = checks.map { it[ "bucket" ].to_s.downcase }
				return :fail if buckets.include?( "fail" )
				return :pending if buckets.include?( "pending" )

				:pass
			end

			def check_pr_review( number: )
				payload, _, _, success, = github_adapter.run_json(
					"pr", "view", number.to_s,
					"--json", "reviewDecision"
				)
				return :none unless success

				decision = payload.is_a?( Hash ) ? payload[ "reviewDecision" ].to_s.strip.upcase : ""
				case decision
				when "APPROVED" then :approved
				when "CHANGES_REQUESTED" then :changes_requested
				when "REVIEW_REQUIRED" then :review_required
				else :none
				end
			end

			def check_pr_review_gate( number: )
				owner, repo = repository_coordinates
				snapshot = review_gate_snapshot( owner: owner, repo: repo, pr_number: number )
				if snapshot.fetch( :unresolved_threads ).any?
					return { state: :block, detail: "unresolved review threads remain (#{snapshot.fetch( :unresolved_threads ).count})" }
				end
				if snapshot.fetch( :unacknowledged_actionable ).any?
					return { state: :block, detail: "actionable review findings remain (#{snapshot.fetch( :unacknowledged_actionable ).count})" }
				end
				{ state: :pass, detail: "review gate passed" }
			rescue StandardError => exception
				{ state: :error, detail: "unable to evaluate review gate: #{exception.message}" }
			end

			def merge_pr!( number:, result: )
				method = config.govern_merge_method
				result[ :merge_method ] = method

				_, stderr, success, = gh_run(
					"pr", "merge", number.to_s,
					"--#{method}"
				)

				if success
					EXIT_OK
				else
					error_text = stderr.to_s.strip
					error_text = "merge failed" if error_text.empty?
					result[ :error ] = error_text
					result[ :recovery ] = "gh pr merge #{number} --#{method}"
					EXIT_ERROR
				end
			end

			def sync_after_merge!( remote:, main:, result: )
				main_root = main_worktree_root
				current_branch, = Open3.capture2( "git", "-C", main_root, "branch", "--show-current" )
				current_branch = current_branch.to_s.strip

				_, sync_stderr, sync_success, = if current_branch == main
					Open3.capture3( "git", "-C", main_root, "pull", "--ff-only", remote, main )
				else
					Open3.capture3( "git", "-C", main_root, "fetch", remote, "#{main}:refs/heads/#{main}" )
				end

				if sync_success
					result[ :synced ] = true
					puts_verbose "synced #{main} in #{main_root} from #{remote}"
					true
				else
					result[ :synced ] = false
					result[ :sync_error ] = sync_stderr.to_s.strip
					puts_verbose "sync failed: #{sync_stderr.to_s.strip}"
					false
				end
			end

			def compute_post_merge_next_step!( result: )
				main_root = main_worktree_root
				current_wt = worktree_list
					.reject { it.path == realpath_safe( main_root ) }
					.find { it.holds_cwd? }

				result[ :next_step ] =
					if current_wt
						"cd #{main_root} && carson housekeep"
					else
						"carson housekeep"
					end
			rescue StandardError
				nil
			end
		end

		include Deliver
	end
end
