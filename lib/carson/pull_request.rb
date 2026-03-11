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
			stdout, _, success, = runtime.gh_run( "pr", "view", "--", branch, "--json", "number,url,state" )
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

		# Creates a PR via gh. Returns instance. Raises PullRequest::Error on failure.
		def self.create!( branch:, title: nil, body_file: nil, runtime: )
			pr_title = title || default_title( branch: branch )
			args = [ "pr", "create", "--title", pr_title, "--head", branch ]
			if body_file && File.exist?( body_file )
				args.push( "--body-file", body_file )
			else
				args.push( "--body", "" )
			end

			stdout, stderr, success, = runtime.gh_run( *args )
			unless success
				error_text = stderr.to_s.strip
				error_text = "pr create failed" if error_text.empty?
				raise Error.new( error_text, recovery: "gh pr create --title '#{pr_title}' --head #{branch}" )
			end

			pr_url = stdout.to_s.strip
			pr_number = pr_url.split( "/" ).last.to_i
			if pr_number > 0
				new( number: pr_number, url: pr_url, state: "OPEN", runtime: runtime )
			else
				find_open( branch: branch, runtime: runtime ) ||
					raise( Error, "created PR but could not retrieve it" )
			end
		end

		def self.default_title( branch: )
			branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { it.upcase }
		end

		# Finds a merged PR whose head SHA matches branch_tip_sha.
		# Returns instance or nil. Used by prune for evidence-based deletion.
		def self.merged_for_branch( branch:, branch_tip_sha:, owner:, repo:, main_branch:, runtime: )
			results = []
			page = 1
			max_pages = 50

			loop do
				stdout, _, success, = runtime.gh_run(
					"api", "repos/#{owner}/#{repo}/pulls",
					"--method", "GET",
					"-f", "state=closed",
					"-f", "base=#{main_branch}",
					"-f", "head=#{owner}:#{branch}",
					"-f", "sort=updated",
					"-f", "direction=desc",
					"-f", "per_page=100",
					"-f", "page=#{page}"
				)
				return nil unless success

				page_nodes = Array( JSON.parse( stdout ) )
				break if page_nodes.empty?

				page_nodes.each do |entry|
					next unless entry.dig( "head", "ref" ).to_s == branch.to_s
					next unless entry.dig( "base", "ref" ).to_s == main_branch
					next unless entry.dig( "head", "sha" ).to_s == branch_tip_sha
					next if entry[ "merged_at" ].nil?

					results << {
						number: entry[ "number" ],
						url: entry[ "html_url" ].to_s,
						merged_at: entry[ "merged_at" ]
					}
				end

				break if page >= max_pages
				page += 1
			end

			latest = results.max_by { it.fetch( :merged_at ) }
			return nil if latest.nil?

			new( number: latest[ :number ], url: latest[ :url ], state: "MERGED", runtime: runtime )
		rescue StandardError
			nil
		end

		def merge!( method: )
			_, stderr, success, = runtime.gh_run( "pr", "merge", number.to_s, "--#{method}" )
			unless success
				error_text = stderr.to_s.strip
				error_text = "merge failed" if error_text.empty?
				raise Error.new( error_text, recovery: "gh pr merge #{number} --#{method}" )
			end
			self
		end

		def ci_status
			stdout, _, success, = runtime.gh_run( "pr", "checks", number.to_s, "--json", "name,bucket" )
			return :none unless success

			checks = JSON.parse( stdout ) rescue []
			return :none if checks.empty?

			buckets = checks.map { it[ "bucket" ].to_s.downcase }
			return :fail if buckets.include?( "fail" )
			return :pending if buckets.include?( "pending" )
			:pass
		end

		def review_decision
			stdout, _, success, = runtime.gh_run( "pr", "view", number.to_s, "--json", "reviewDecision" )
			return :none unless success

			data = JSON.parse( stdout ) rescue {}
			decision = data[ "reviewDecision" ].to_s.strip.upcase
			case decision
			when "APPROVED" then :approved
			when "CHANGES_REQUESTED" then :changes_requested
			when "REVIEW_REQUIRED" then :review_required
			else :none
			end
		end

	private

		attr_reader :runtime
	end
end
