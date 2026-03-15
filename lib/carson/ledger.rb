# JSON file-backed ledger for Carson's deliveries and revisions.
require "fileutils"
require "json"
require "time"

module Carson
	class Ledger
		UNSET = Object.new
		ACTIVE_DELIVERY_STATES = Delivery::ACTIVE_STATES

		def initialize( path: )
			@path = File.expand_path( path )
			FileUtils.mkdir_p( File.dirname( @path ) )
		end

		attr_reader :path

		# Creates or refreshes a delivery for the same branch head.
		def upsert_delivery( repository:, branch_name:, head:, worktree_path:, pr_number:, pr_url:, status:, summary:, cause: )
			timestamp = now_utc

			with_state do |state|
				key = delivery_key( repo_path: repository.path, branch_name: branch_name, head: head )
				existing = state[ "deliveries" ][ key ]

				if existing
					existing[ "repo_path" ] = repository.path
					existing[ "worktree_path" ] = worktree_path
					existing[ "status" ] = status
					existing[ "pr_number" ] = pr_number
					existing[ "pr_url" ] = pr_url
					existing[ "cause" ] = cause
					existing[ "summary" ] = summary
					existing[ "updated_at" ] = timestamp
					return build_delivery( key: key, data: existing, repository: repository )
				end

				supersede_branch!( state: state, repo_path: repository.path, branch_name: branch_name, timestamp: timestamp )
				state[ "deliveries" ][ key ] = {
					"repo_path" => repository.path,
					"branch_name" => branch_name,
					"head" => head,
					"worktree_path" => worktree_path,
					"status" => status,
					"pr_number" => pr_number,
					"pr_url" => pr_url,
					"cause" => cause,
					"summary" => summary,
					"created_at" => timestamp,
					"updated_at" => timestamp,
					"integrated_at" => nil,
					"superseded_at" => nil,
					"revisions" => []
				}
				build_delivery( key: key, data: state[ "deliveries" ][ key ], repository: repository )
			end
		end

		# Looks up the active delivery for a branch, if one exists.
		def active_delivery( repo_path:, branch_name: )
			state = load_state
			repo_paths = repo_identity_paths( repo_path: repo_path )

			candidates = state[ "deliveries" ].select do |_key, data|
				repo_paths.include?( data[ "repo_path" ] ) &&
					data[ "branch_name" ] == branch_name &&
					ACTIVE_DELIVERY_STATES.include?( data[ "status" ] )
			end

			return nil if candidates.empty?

			key, data = candidates.max_by { |k, d| [ d[ "updated_at" ].to_s, k ] }
			build_delivery( key: key, data: data )
		end

		# Lists active deliveries for a repository in creation order.
		def active_deliveries( repo_path: )
			state = load_state
			repo_paths = repo_identity_paths( repo_path: repo_path )

			state[ "deliveries" ]
				.select { |_key, data| repo_paths.include?( data[ "repo_path" ] ) && ACTIVE_DELIVERY_STATES.include?( data[ "status" ] ) }
				.sort_by { |key, data| [ data[ "created_at" ].to_s, key ] }
				.map { |key, data| build_delivery( key: key, data: data ) }
		end

		# Updates a delivery record in place.
		def update_delivery(
			delivery:,
			status: UNSET,
			pr_number: UNSET,
			pr_url: UNSET,
			cause: UNSET,
			summary: UNSET,
			worktree_path: UNSET,
			integrated_at: UNSET,
			superseded_at: UNSET
		)
			with_state do |state|
				data = state[ "deliveries" ][ delivery.key ]
				raise "delivery not found: #{delivery.key}" unless data

				data[ "status" ] = status unless status.equal?( UNSET )
				data[ "pr_number" ] = pr_number unless pr_number.equal?( UNSET )
				data[ "pr_url" ] = pr_url unless pr_url.equal?( UNSET )
				data[ "cause" ] = cause unless cause.equal?( UNSET )
				data[ "summary" ] = summary unless summary.equal?( UNSET )
				data[ "worktree_path" ] = worktree_path unless worktree_path.equal?( UNSET )
				data[ "integrated_at" ] = integrated_at unless integrated_at.equal?( UNSET )
				data[ "superseded_at" ] = superseded_at unless superseded_at.equal?( UNSET )
				data[ "updated_at" ] = now_utc

				build_delivery( key: delivery.key, data: data, repository: delivery.repository )
			end
		end

		# Records one revision cycle against a delivery.
		def record_revision( delivery:, cause:, provider:, status:, summary: )
			timestamp = now_utc

			with_state do |state|
				data = state[ "deliveries" ][ delivery.key ]
				raise "delivery not found: #{delivery.key}" unless data

				revisions = data[ "revisions" ] ||= []
				next_number = ( revisions.map { |r| r[ "number" ].to_i }.max || 0 ) + 1
				finished = %w[completed failed stalled].include?( status ) ? timestamp : nil

				revision_data = {
					"number" => next_number,
					"cause" => cause,
					"provider" => provider,
					"status" => status,
					"started_at" => timestamp,
					"finished_at" => finished,
					"summary" => summary
				}
				revisions << revision_data
				data[ "updated_at" ] = timestamp

				build_revision( data: revision_data )
			end
		end

		# Returns revisions for a delivery in ascending order.
		def revisions_for_delivery( delivery: )
			delivery.revisions.sort_by( &:number )
		end

	private

		# Acquires file lock, loads state, yields for mutation, saves atomically, releases lock.
		def with_state
			lock_path = "#{path}.lock"
			FileUtils.mkdir_p( File.dirname( lock_path ) )
			FileUtils.touch( lock_path )

			File.open( lock_path, File::RDWR | File::CREAT ) do |lock_file|
				lock_file.flock( File::LOCK_EX )
				state = load_state
				result = yield state
				save_state!( state )
				result
			end
		end

		def load_state
			return { "deliveries" => {} } unless File.exist?( path )

			raw = File.read( path )
			return { "deliveries" => {} } if raw.strip.empty?

			parsed = JSON.parse( raw )
			raise "state file must contain a JSON object at #{path}" unless parsed.is_a?( Hash )
			parsed[ "deliveries" ] ||= {}
			parsed
		rescue JSON::ParserError => exception
			raise "invalid JSON in state file #{path}: #{exception.message}"
		end

		def save_state!( state )
			tmp_path = "#{path}.tmp"
			File.write( tmp_path, JSON.pretty_generate( state ) + "\n" )
			File.rename( tmp_path, path )
		end

		def delivery_key( repo_path:, branch_name:, head: )
			"#{repo_path}:#{branch_name}:#{head}"
		end

		def build_delivery( key:, data:, repository: nil )
			return nil unless data

			revisions = Array( data[ "revisions" ] ).map { |r| build_revision( data: r ) }

			Delivery.new(
				repo_path: data.fetch( "repo_path" ),
				repository: repository,
				branch: data.fetch( "branch_name" ),
				head: data.fetch( "head" ),
				worktree_path: data[ "worktree_path" ],
				status: data.fetch( "status" ),
				pull_request_number: data[ "pr_number" ],
				pull_request_url: data[ "pr_url" ],
				revisions: revisions,
				cause: data[ "cause" ],
				summary: data[ "summary" ],
				created_at: data.fetch( "created_at" ),
				updated_at: data.fetch( "updated_at" ),
				integrated_at: data[ "integrated_at" ],
				superseded_at: data[ "superseded_at" ]
			)
		end

		def build_revision( data: )
			return nil unless data

			Revision.new(
				number: data.fetch( "number" ).to_i,
				cause: data.fetch( "cause" ),
				provider: data.fetch( "provider" ),
				status: data.fetch( "status" ),
				started_at: data.fetch( "started_at" ),
				finished_at: data[ "finished_at" ],
				summary: data[ "summary" ]
			)
		end

		def supersede_branch!( state:, repo_path:, branch_name:, timestamp: )
			repo_paths = repo_identity_paths( repo_path: repo_path )
			state[ "deliveries" ].each do |_key, data|
				next unless repo_paths.include?( data[ "repo_path" ] )
				next unless data[ "branch_name" ] == branch_name
				next unless ACTIVE_DELIVERY_STATES.include?( data[ "status" ] )

				data[ "status" ] = "superseded"
				data[ "superseded_at" ] = timestamp
				data[ "updated_at" ] = timestamp
			end
		end

		def repo_identity_paths( repo_path: )
			canonical_path = File.expand_path( repo_path )
			canonical_realpath = realpath_or_nil( path: canonical_path )
			worktree_gitdirs = Dir.glob( File.join( canonical_path, ".git", "worktrees", "*", "gitdir" ) )
			paths = worktree_gitdirs.each_with_object( path_aliases( path: canonical_path ) ) do |gitdir_path, identities|
				worktree_git_path = File.read( gitdir_path ).to_s.strip
				next if worktree_git_path.empty?

				worktree_path = File.dirname( File.expand_path( worktree_git_path, File.dirname( gitdir_path ) ) )
				identities.concat( path_aliases( path: worktree_path ) )

				worktree_realpath = realpath_or_nil( path: worktree_path )
				next unless canonical_realpath && worktree_realpath

				canonical_prefix = File.join( canonical_realpath, "" )
				next unless worktree_realpath.start_with?( canonical_prefix )

				relative_path = worktree_realpath.delete_prefix( canonical_prefix )
				identities << File.join( canonical_path, relative_path ) unless relative_path.empty?
			end
			paths.uniq
		rescue StandardError
			[ File.expand_path( repo_path ) ]
		end

		def path_aliases( path: )
			expanded_path = File.expand_path( path )
			aliases = [ expanded_path, realpath_or_nil( path: expanded_path ) ]
			aliases << expanded_path.delete_prefix( "/private" ) if expanded_path.start_with?( "/private/" )
			aliases.compact.uniq
		end

		def realpath_or_nil( path: )
			File.realpath( path )
		rescue StandardError
			nil
		end

		def now_utc
			Time.now.utc.iso8601
		end
	end
end
