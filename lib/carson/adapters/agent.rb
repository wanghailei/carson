module Carson
	module Adapters
		module Agent
			WorkOrder = Data.define( :repo, :branch, :pr_number, :objective, :context, :acceptance_checks )
			# objective: "fix_ci" | "address_review" | "fix_audit"
			# context: failure details from Carson's analysis
			# acceptance_checks: what must pass for the fix to be accepted

			Result = Data.define( :status, :summary, :evidence, :commit_sha )
			# status: "done" | "failed" | "timeout"
		end
	end
end
