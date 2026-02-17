module Butler
	module Commands
		class Prune
			def self.run( runtime: )
				runtime.prune!
			end
		end
	end
end
