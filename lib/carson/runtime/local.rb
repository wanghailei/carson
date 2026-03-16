# Aggregates local repository operation modules (sync, prune, hooks, worktree, template).
require_relative "local/sync"
require_relative "local/merge_proof"
require_relative "local/prune"
require_relative "local/template"
require_relative "local/hooks"
require_relative "local/onboard"
require_relative "local/worktree"

module Carson
	class Runtime
		include Local
	end
end
