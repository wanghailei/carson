module Butler
	module Commands
		class ReviewSweep
			def self.run( runtime: )
				runtime.review_sweep!
			end
		end
	end
end
