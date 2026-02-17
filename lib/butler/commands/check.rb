# frozen_string_literal: true

module Butler
	module Commands
		class Check
			def self.run( runtime: )
				runtime.check!
			end
		end
	end
end
