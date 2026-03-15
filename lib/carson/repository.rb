# Passive repository record reconstructed from git state and Carson's ledger.
module Carson
	class Repository
		attr_reader :path

		def initialize( path:, runtime: )
			@path = File.expand_path( path )
			@runtime = runtime
		end

		# Human-readable repository name derived from the filesystem path.
		def name
			File.basename( path )
		end

		# Returns a passive branch record for the given branch name.
		def branch( name )
			Branch.new( repository: self, name: name, runtime: runtime )
		end

		# Lists local branches as passive branch records.
		def branches
			runtime.git_capture!( "for-each-ref", "--format=%(refname:short)", "refs/heads" )
				.lines
				.map( &:strip )
				.reject( &:empty? )
				.map { |branch_name| branch( branch_name ) }
		rescue StandardError
			[]
		end

		# Reports the repository's delivery-centred state for status surfaces.
		def status
			{
				name: name,
				path: path,
				branches: runtime.ledger.active_deliveries( repo_path: path ).map { |delivery| delivery.branch }
			}
		end

	private

		attr_reader :runtime
	end
end
