# Passive ledger record for one branch delivery attempt.
module Carson
	class Delivery
		ACTIVE_STATES = %w[preparing gated queued integrating escalated filed].freeze
		BLOCKED_STATES = %w[gated escalated].freeze
		READY_STATES = %w[queued].freeze
		TERMINAL_STATES = %w[integrated failed superseded].freeze

		attr_reader :repo_path, :repository, :branch, :head, :worktree_path, :status,
			:pull_request_number, :pull_request_url, :revisions, :cause, :summary,
			:created_at, :updated_at, :integrated_at, :superseded_at,
			:pull_request_state, :pull_request_draft, :pull_request_merged_at, :merge_proof

		def initialize(
			repo_path:, branch:, head:, worktree_path:, status:,
			pull_request_number:, pull_request_url:, cause:, summary:,
			created_at:, updated_at:, integrated_at:, superseded_at:,
			revisions: [], repository: nil,
			pull_request_state: nil, pull_request_draft: nil, pull_request_merged_at: nil,
			merge_proof: nil
		)
			@repo_path = repo_path
			@repository = repository
			@branch = branch
			@head = head
			@worktree_path = worktree_path
			@status = status
			@pull_request_number = pull_request_number
			@pull_request_url = pull_request_url
			@revisions = revisions
			@cause = cause
			@summary = summary
			@created_at = created_at
			@updated_at = updated_at
			@integrated_at = integrated_at
			@superseded_at = superseded_at
			@pull_request_state = pull_request_state
			@pull_request_draft = pull_request_draft
			@pull_request_merged_at = pull_request_merged_at
			@merge_proof = merge_proof
		end

		def key
			"#{repo_path}:#{branch}:#{head}"
		end

		def revision_count
			revisions.length
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

		def filed?
			status == "filed"
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
