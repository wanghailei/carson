# Domain object representing a GitHub Pull Request.
# Provides class-level lookup methods and instance-level actions.
require "json"

module Carson
	class PullRequest
		class Error < StandardError
			attr_reader :recovery

			def initialize( message, recovery: nil )
				super( message )
				@recovery = recovery
			end
		end

		attr_reader :number, :url, :state

		def initialize( number:, url: nil, state: nil, runtime: )
			@number = number
			@url = url.to_s
			@state = state.to_s
			@runtime = runtime
		end

		# Finds an open PR for the given branch. Returns instance or nil.
		def self.find_open( branch:, runtime: )
			stdout, _, success, = runtime.gh_run( "pr", "view", branch, "--json", "number,url,state" )
			return nil unless success

			data = JSON.parse( stdout ) rescue nil
			return nil unless data && data[ "number" ] && data[ "state" ] == "OPEN"

			new( number: data[ "number" ], url: data[ "url" ], state: data[ "state" ], runtime: runtime )
		end

		# Finds any PR (any state) for a branch. Returns instance or nil.
		# Used by gate_support for review gate.
		def self.for_branch( branch:, runtime: )
			stdout, _, success, = runtime.gh_run( "pr", "view", "--", branch, "--json", "number,title,url,state" )
			return nil unless success

			data = JSON.parse( stdout ) rescue nil
			return nil unless data && data[ "number" ]

			new( number: data[ "number" ], url: data[ "url" ], state: data[ "state" ], runtime: runtime )
		end

		# Fast check: does this branch have any open PR? Returns boolean.
		# Uses REST API with per_page=1 for speed. Used by prune.
		def self.open_for_branch?( branch:, owner:, repo:, runtime: )
			stdout, _, success, = runtime.gh_run(
				"api", "repos/#{owner}/#{repo}/pulls",
				"--method", "GET",
				"-f", "state=open",
				"-f", "head=#{owner}:#{branch}",
				"-f", "per_page=1"
			)
			return true unless success

			results = Array( JSON.parse( stdout ) )
			!results.empty?
		rescue StandardError
			true
		end

	private

		attr_reader :runtime
	end
end
