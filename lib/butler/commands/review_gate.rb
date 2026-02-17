module Butler
	module Commands
		class ReviewGate
			def self.run( runtime: )
				runtime.review_gate!
			end
		end
	end
end
