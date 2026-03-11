# Represents a local Git branch with identity and classification helpers.
module Carson
	class Branch
		attr_reader :name

		def initialize( name: )
			@name = name
		end

		# Returns Branch instance for the current checkout, or nil for detached HEAD.
		def self.current( runtime: )
			raw = runtime.git_capture!( "rev-parse", "--abbrev-ref", "HEAD" ).strip
			return nil if raw == "HEAD"
			new( name: raw )
		end

		# Returns true if a local branch with this name exists.
		def self.exists?( name:, runtime: )
			_, _, success, = runtime.git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{name}" )
			success
		end
	end
end
