# Passive ledger record for one branch-to-authority delivery attempt.
module Carson
	class Delivery
		ACTIVE_STATES = %w[preparing gated queued integrating escalated].freeze
		BLOCKED_STATES = %w[gated escalated].freeze
		READY_STATES = %w[queued].freeze
		TERMINAL_STATES = %w[integrated failed superseded].freeze

		attr_reader :id, :repository, :branch, :head, :worktree_path, :authority, :status,
			:pull_request_number, :pull_request_url, :revision_count, :cause, :summary,
			:created_at, :updated_at, :integrated_at, :superseded_at

		def initialize(
			id:, repository:, branch:, head:, worktree_path:, authority:, status:,
			pull_request_number:, pull_request_url:, revision_count:, cause:, summary:,
			created_at:, updated_at:, integrated_at:, superseded_at:
		)
			@id = id
			@repository = repository
			@branch = branch
			@head = head
			@worktree_path = worktree_path
			@authority = authority
			@status = status
			@pull_request_number = pull_request_number
			@pull_request_url = pull_request_url
			@revision_count = revision_count
			@cause = cause
			@summary = summary
			@created_at = created_at
			@updated_at = updated_at
			@integrated_at = integrated_at
			@superseded_at = superseded_at
		end

		def active?
			ACTIVE_STATES.include?( status )
		end

		def blocked?
			BLOCKED_STATES.include?( status )
		end

		def ready?
			READY_STATES.include?( status )
		end

		def integrated?
			status == "integrated"
		end

		def failed?
			status == "failed"
		end

		def superseded?
			status == "superseded"
		end

		def terminal?
			TERMINAL_STATES.include?( status )
		end
	end
end
