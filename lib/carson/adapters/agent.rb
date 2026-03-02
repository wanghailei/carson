module Carson
	module Adapters
		module Agent
			WorkOrder = Data.define( :repo, :branch, :pr_number, :objective, :context, :acceptance_checks )
			# objective: "fix_ci" | "address_review" | "fix_audit"
			# context: String (legacy — PR title) or Hash with structured evidence:
			#   fix_ci:         { title:, ci_logs:, ci_run_url:, prior_attempt: { summary:, dispatched_at: } }
			#   address_review: { title:, review_findings: [{ kind:, url:, body: }], prior_attempt: ... }
			# acceptance_checks: what must pass for the fix to be accepted

			Result = Data.define( :status, :summary, :evidence, :commit_sha )
			# status: "done" | "failed" | "timeout"
		end
	end
end
