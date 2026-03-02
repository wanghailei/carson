require_relative "carson/version"

module Carson
	BADGE = "\u29D3".freeze # ⧓ BLACK BOWTIE (U+29D3)
end

require_relative "carson/config"
require_relative "carson/adapters/git"
require_relative "carson/adapters/github"
require_relative "carson/adapters/agent"
require_relative "carson/adapters/prompt"
require_relative "carson/adapters/codex"
require_relative "carson/adapters/claude"
require_relative "carson/runtime"
require_relative "carson/cli"
