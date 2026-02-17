# frozen_string_literal: true

module Butler
	module Commands
		class Hook
			def self.run( runtime: )
				runtime.hook!
			end
		end
	end
end
