# Domain object representing a git remote.
# Owns name, owner, and repo — parsed from the remote URL on initialisation.
# Runtime provides infrastructure (git, gh, config, output) the way
# ActiveRecord models hold a database connection.
module Carson
	class Remote
		class Error < StandardError
			attr_reader :recovery

			def initialize( message, recovery: nil )
				super( message )
				@recovery = recovery
			end
		end

		URL_PATTERN = %r{\A(?:git@|https?://|ssh://git@)?[^/:]+[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?\z}.freeze

		attr_reader :name, :owner, :repo

		def initialize( name:, runtime: )
			@name = name
			@runtime = runtime
			@owner, @repo = parse_remote_url
		end

	private

		attr_reader :runtime

		def parse_remote_url
			remote_url = runtime.git_capture!( "config", "--get", "remote.#{name}.url" ).strip
			match = remote_url.match( URL_PATTERN )
			return [ match[ :owner ], match[ :repo ] ] if match

			# Fallback: ask gh for nameWithOwner.
			stdout_text, _stderr, success = runtime.gh_run( "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" )
			if success
				name_with_owner = stdout_text.to_s.strip
				if name_with_owner.include?( "/" )
					owner, repo = name_with_owner.split( "/", 2 )
					return [ owner, repo ] unless owner.to_s.empty? || repo.to_s.empty?
				end
			end

			# Last resort: derive repo name from URL, mark owner as local.
			repo_name = File.basename( remote_url ).sub( /\.git\z/, "" )
			return [ "local", repo_name ] unless repo_name.empty?

			raise Error.new( "unable to parse owner/repo from remote URL #{remote_url}" )
		end
	end
end
