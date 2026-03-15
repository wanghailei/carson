# Passive ledger record for one feedback-driven revision cycle.
module Carson
	class Revision
		attr_reader :number, :cause, :provider, :status, :started_at, :finished_at, :summary

		def initialize( number:, cause:, provider:, status:, started_at:, finished_at:, summary: )
			@number = number
			@cause = cause
			@provider = provider
			@status = status
			@started_at = started_at
			@finished_at = finished_at
			@summary = summary
		end

		def open?
			%w[queued running].include?( status )
		end

		def completed?
			status == "completed"
		end

		def failed?
			%w[failed stalled].include?( status )
		end
	end
end
