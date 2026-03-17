# Lists governed repositories from Carson's global config.
# Portfolio-level query — not scoped to any single repository.
require "json"

module Carson
	class Runtime
		module List
			def list!( json_output: false )
				repos = config.govern_repos

				if json_output
					output.puts JSON.pretty_generate( { command: "list", repos: repos } )
				else
					if repos.empty?
						puts_line "No governed repositories."
						puts_line "  Run carson onboard in a repo to register it."
					else
						puts_line "Governed repositories (#{repos.length}):"
						repos.each { |path| puts_line "  #{path}" }
					end
				end

				EXIT_OK
			end
		end

		include List
	end
end
