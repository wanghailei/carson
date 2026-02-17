module Butler
	module Commands
		class Sync
			def self.run( runtime: )
				runtime.sync!
			end
		end
	end
end
