require_relative "local/sync"
require_relative "local/prune"
require_relative "local/template"
require_relative "local/hooks"
require_relative "local/onboard"

module Carson
	class Runtime
		include Local
	end
end
