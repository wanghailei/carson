# PR delivery lifecycle — push, create PR, and optionally merge.
# Collapses the 8-step manual PR flow into one or two commands.
# `carson deliver` pushes and creates the PR.
# `carson deliver --merge` also merges if CI is green.
module Carson
	class Runtime
		module Deliver
			# Entry point for `carson deliver`.
			# Pushes current branch, creates a PR if needed, reports the PR URL.
			# With merge: true, also merges if CI passes and cleans up.
			def deliver!( merge: false, title: nil, body_file: nil )
				branch = current_branch
				main = config.main_branch
				remote = config.git_remote

				# Guard: cannot deliver from main.
				if branch == main
					puts_line "ERROR: cannot deliver from #{main}. Switch to a feature branch first."
					return EXIT_ERROR
				end

				# Step 1: push the branch.
				push_result = push_branch!( branch: branch, remote: remote )
				return push_result unless push_result == EXIT_OK

				# Step 2: find or create the PR.
				pr_number, pr_url = find_or_create_pr!(
					branch: branch, title: title, body_file: body_file
				)
				return EXIT_ERROR if pr_number.nil?

				puts_line "PR: ##{pr_number} #{pr_url}"

				# Without --merge, we are done.
				return EXIT_OK unless merge

				# Step 3: check CI status.
				ci_status = check_pr_ci( number: pr_number )
				case ci_status
				when :pass
					puts_line "CI: pass"
				when :pending
					puts_line "CI: pending — merge when checks complete."
					return EXIT_OK
				when :fail
					puts_line "CI: failing — fix before merging."
					return EXIT_BLOCK
				else
					puts_line "CI: unknown — check manually."
					return EXIT_OK
				end

				# Step 4: merge.
				merge_result = merge_pr!( number: pr_number )
				return merge_result unless merge_result == EXIT_OK

				# Step 5: sync main.
				sync_after_merge!( remote: remote, main: main )

				EXIT_OK
			end

		private

			# Pushes the branch to the remote with tracking.
			def push_branch!( branch:, remote: )
				_, push_stderr, push_success, = git_run( "push", "-u", remote, branch )
				unless push_success
					error_text = push_stderr.to_s.strip
					error_text = "push failed" if error_text.empty?
					puts_line "ERROR: #{error_text}"
					return EXIT_ERROR
				end
				puts_verbose "pushed #{branch} to #{remote}"
				EXIT_OK
			end

			# Finds an existing PR for the branch, or creates a new one.
			# Returns [number, url] or [nil, nil] on failure.
			def find_or_create_pr!( branch:, title: nil, body_file: nil )
				# Check for existing PR.
				existing = find_existing_pr( branch: branch )
				return existing if existing.first

				# Create a new PR.
				create_pr!( branch: branch, title: title, body_file: body_file )
			end

			# Queries gh for an open PR on this branch.
			# Returns [number, url] or [nil, nil].
			def find_existing_pr( branch: )
				stdout, _, success, = gh_run(
					"pr", "view", branch,
					"--json", "number,url"
				)
				if success
					data = JSON.parse( stdout ) rescue nil
					if data && data[ "number" ]
						return [ data[ "number" ], data[ "url" ].to_s ]
					end
				end
				[ nil, nil ]
			end

			# Creates a PR via gh. Title defaults to branch name humanised.
			# Returns [number, url] or [nil, nil] on failure.
			def create_pr!( branch:, title: nil, body_file: nil )
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
					puts_line "ERROR: #{error_text}"
					return [ nil, nil ]
				end

				# gh pr create prints the URL on success. Parse number from it.
				pr_url = stdout.to_s.strip
				pr_number = pr_url.split( "/" ).last.to_i
				if pr_number > 0
					[ pr_number, pr_url ]
				else
					# Fallback: query the just-created PR.
					find_existing_pr( branch: branch )
				end
			end

			# Generates a default PR title from the branch name.
			def default_pr_title( branch: )
				branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { |c| c.upcase }
			end

			# Checks CI status on a PR. Returns :pass, :fail, :pending, or :none.
			def check_pr_ci( number: )
				stdout, _, success, = gh_run(
					"pr", "checks", number.to_s,
					"--json", "name,state,conclusion"
				)
				return :none unless success

				checks = JSON.parse( stdout ) rescue []
				return :none if checks.empty?

				conclusions = checks.map { |c| c[ "conclusion" ].to_s.upcase }
				states = checks.map { |c| c[ "state" ].to_s.upcase }

				return :fail if conclusions.any? { |c| c == "FAILURE" || c == "CANCELLED" || c == "TIMED_OUT" }
				return :pending if states.any? { |s| s == "PENDING" || s == "QUEUED" || s == "IN_PROGRESS" } ||
					conclusions.any? { |c| c == "" || c == "PENDING" }

				:pass
			end

			# Merges the PR using the configured merge method.
			def merge_pr!( number: )
				method = config.govern_merge_method
				stdout, stderr, success, = gh_run(
					"pr", "merge", number.to_s,
					"--#{method}",
					"--delete-branch"
				)

				if success
					puts_line "Merged PR ##{number} via #{method}."
					EXIT_OK
				else
					error_text = stderr.to_s.strip
					error_text = "merge failed" if error_text.empty?
					puts_line "ERROR: #{error_text}"
					EXIT_ERROR
				end
			end

			# Syncs main after a successful merge.
			def sync_after_merge!( remote:, main: )
				git_run( "checkout", main )
				git_run( "pull", remote, main )
				puts_verbose "synced #{main} from #{remote}"
			end
		end

		include Deliver
	end
end
