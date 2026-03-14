# Passive branch record. Branch holds identity and current facts only.
module Carson
	class Branch
		attr_reader :repository, :name, :purpose, :head, :worktree, :delivery

		def initialize( repository:, name:, runtime:, purpose: nil, head: nil, worktree: nil, delivery: nil )
			@repository = repository
			@name = name
			@runtime = runtime
			@purpose = purpose
			@head = head
			@worktree = worktree
			@delivery = delivery
		end

		# Re-reads the branch facts from git and Carson's ledger.
		def reload
			refreshed_head = runtime.git_capture!( "rev-parse", name ).strip
			refreshed_worktree = runtime.worktree_list.find { |entry| entry.branch == name }&.path || worktree
			refreshed_delivery = runtime.ledger.active_delivery( repo_path: repository.path, branch_name: name )
			self.class.new(
				repository: repository,
				name: name,
				runtime: runtime,
				purpose: purpose,
				head: refreshed_head,
				worktree: refreshed_worktree,
				delivery: refreshed_delivery
			)
		rescue StandardError
			self
		end

	private

		attr_reader :runtime
	end
end
