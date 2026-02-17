# frozen_string_literal: true

module Butler
	module Commands
		class Audit
			def self.run( runtime: )
				runtime.audit!
			end
		end
	end
end
