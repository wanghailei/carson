# Defines the WorkOrder and Result data structures for agent dispatch.
module Carson
	module Adapters
		module Agent
			WorkOrder = Struct.new( :repo, :branch, :pr_number, :objective, :context, :acceptance_checks, keyword_init: true )
			# objective: "fix_ci" | "address_review"
			# context: String (legacy — PR title) or Hash with structured evidence:
			#   fix_ci:         { title:, ci_logs:, ci_run_url:, prior_attempt: { summary:, dispatched_at: } }
			#   address_review: { title:, review_findings: [{ kind:, url:, body: }], prior_attempt: ... }
			# acceptance_checks: what must pass for the fix to be accepted

			Result = Struct.new( :status, :summary, :evidence, :commit_sha, keyword_init: true )
			# status: "done" | "failed" | "timeout"
		end
	end
end
