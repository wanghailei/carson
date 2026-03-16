# JSON file-backed ledger for Carson's deliveries and revisions.
require "fileutils"
require "json"
require "time"

module Carson
	class Ledger
		UNSET = Object.new
		ACTIVE_DELIVERY_STATES = Delivery::ACTIVE_STATES
		SQLITE_HEADER = "SQLite format 3\0".b.freeze

		def initialize( path: )
			@path = File.expand_path( path )
			FileUtils.mkdir_p( File.dirname( @path ) )
			migrate_legacy_state_if_needed!
		end

		attr_reader :path

		# Creates or refreshes a delivery for the same branch head.
		def upsert_delivery(
			repository:, branch_name:, head:, worktree_path:, pr_number:, pr_url:, status:, summary:, cause:,
			pull_request_state: nil, pull_request_draft: nil, pull_request_merged_at: nil, merge_proof: nil
		)
			timestamp = now_utc

			with_state do |state|
				repo_paths = repo_identity_paths( repo_path: repository.path )
				matches = matching_deliveries(
					state: state,
					repo_paths: repo_paths,
					branch_name: branch_name,
					head: head
				)
				key = delivery_key( repo_path: repository.path, branch_name: branch_name, head: head )
				sequence = matches.map { |_existing_key, data| delivery_sequence( data: data ) }.compact.min
				created_at = matches.map { |_existing_key, data| data.fetch( "created_at", "" ).to_s }.reject( &:empty? ).min || timestamp
				revisions = merged_revisions( entries: matches )
				matches.each { |existing_key, _data| state[ "deliveries" ].delete( existing_key ) }

				supersede_branch!( state: state, repo_path: repository.path, branch_name: branch_name, timestamp: timestamp )
				state[ "deliveries" ][ key ] = {
					"sequence" => sequence || next_delivery_sequence!( state: state ),
					"repo_path" => repository.path,
					"branch_name" => branch_name,
					"head" => head,
					"worktree_path" => worktree_path,
					"status" => status,
					"pr_number" => pr_number,
					"pr_url" => pr_url,
					"pull_request_state" => pull_request_state,
					"pull_request_draft" => pull_request_draft,
					"pull_request_merged_at" => pull_request_merged_at,
					"merge_proof" => serialise_merge_proof( merge_proof: merge_proof ),
					"cause" => cause,
					"summary" => summary,
					"created_at" => created_at,
					"updated_at" => timestamp,
					"integrated_at" => nil,
					"superseded_at" => nil,
					"revisions" => revisions
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

			key, data = candidates.max_by { |k, d| [ d[ "updated_at" ].to_s, delivery_sequence( data: d ), k ] }
			build_delivery( key: key, data: data )
		end

		# Looks up the newest delivery for a branch across active and terminal states.
		def latest_delivery( repo_path:, branch_name: )
			state = load_state
			repo_paths = repo_identity_paths( repo_path: repo_path )

			candidates = state[ "deliveries" ].select do |_key, data|
				repo_paths.include?( data[ "repo_path" ] ) &&
					data[ "branch_name" ] == branch_name
			end

			return nil if candidates.empty?

			key, data = candidates.max_by { |k, d| [ d[ "updated_at" ].to_s, delivery_sequence( data: d ), k ] }
			build_delivery( key: key, data: data )
		end

		# Lists active deliveries for a repository in creation order.
		def active_deliveries( repo_path: )
			state = load_state
			repo_paths = repo_identity_paths( repo_path: repo_path )

			state[ "deliveries" ]
				.select { |_key, data| repo_paths.include?( data[ "repo_path" ] ) && ACTIVE_DELIVERY_STATES.include?( data[ "status" ] ) }
				.sort_by { |key, data| [ delivery_sequence( data: data ), key ] }
				.map { |key, data| build_delivery( key: key, data: data ) }
		end

		# Lists integrated deliveries that still retain a worktree path.
		def integrated_deliveries( repo_path: )
			state = load_state
			repo_paths = repo_identity_paths( repo_path: repo_path )

			state[ "deliveries" ]
				.select do |_key, data|
					repo_paths.include?( data[ "repo_path" ] ) &&
						data[ "status" ] == "integrated" &&
						!data[ "worktree_path" ].to_s.strip.empty?
				end
				.sort_by { |key, data| [ data[ "integrated_at" ].to_s, delivery_sequence( data: data ), key ] }
				.map { |key, data| build_delivery( key: key, data: data ) }
		end

		# Updates a delivery record in place.
		def update_delivery(
			delivery:,
			status: UNSET,
			pr_number: UNSET,
			pr_url: UNSET,
			pull_request_state: UNSET,
			pull_request_draft: UNSET,
			pull_request_merged_at: UNSET,
			merge_proof: UNSET,
			cause: UNSET,
			summary: UNSET,
			worktree_path: UNSET,
			integrated_at: UNSET,
			superseded_at: UNSET
		)
			with_state do |state|
				key, data = resolve_delivery_entry( state: state, delivery: delivery )

				data[ "status" ] = status unless status.equal?( UNSET )
				data[ "pr_number" ] = pr_number unless pr_number.equal?( UNSET )
				data[ "pr_url" ] = pr_url unless pr_url.equal?( UNSET )
				data[ "pull_request_state" ] = pull_request_state unless pull_request_state.equal?( UNSET )
				data[ "pull_request_draft" ] = pull_request_draft unless pull_request_draft.equal?( UNSET )
				data[ "pull_request_merged_at" ] = pull_request_merged_at unless pull_request_merged_at.equal?( UNSET )
				data[ "merge_proof" ] = serialise_merge_proof( merge_proof: merge_proof ) unless merge_proof.equal?( UNSET )
				data[ "cause" ] = cause unless cause.equal?( UNSET )
				data[ "summary" ] = summary unless summary.equal?( UNSET )
				data[ "worktree_path" ] = worktree_path unless worktree_path.equal?( UNSET )
				data[ "integrated_at" ] = integrated_at unless integrated_at.equal?( UNSET )
				data[ "superseded_at" ] = superseded_at unless superseded_at.equal?( UNSET )
				data[ "updated_at" ] = now_utc

				build_delivery( key: key, data: data, repository: delivery.repository )
			end
		end

		# Records one revision cycle against a delivery.
		def record_revision( delivery:, cause:, provider:, status:, summary: )
			timestamp = now_utc

			with_state do |state|
				_key, data = resolve_delivery_entry( state: state, delivery: delivery )

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
			with_state_lock do |lock_file|
				lock_file.flock( File::LOCK_EX )
				state = load_state
				result = yield state
				save_state!( state )
				result
			end
		end

		def load_state
			return { "deliveries" => {}, "recovery_events" => [] } unless File.exist?( path )

			raw = File.binread( path )
			return { "deliveries" => {}, "recovery_events" => [] } if raw.strip.empty?

			parsed = JSON.parse( raw )
			raise "state file must contain a JSON object at #{path}" unless parsed.is_a?( Hash )
			parsed[ "deliveries" ] ||= {}
			normalise_state!( state: parsed )
			parsed
		rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => exception
			raise "invalid JSON in state file #{path}: #{exception.message}"
		end

		def save_state!( state )
			normalise_state!( state: state )
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
				pull_request_state: data[ "pull_request_state" ],
				pull_request_draft: data[ "pull_request_draft" ],
				pull_request_merged_at: data[ "pull_request_merged_at" ],
				merge_proof: deserialise_merge_proof( merge_proof: data[ "merge_proof" ] ),
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

		def migrate_legacy_state_if_needed!
			# Skip lock acquisition entirely when no legacy SQLite file exists.
			# Read-only file checks are safe without the lock; the migration
			# itself is idempotent so a narrow race is harmless.
			return unless state_path_requires_migration?

			with_state_lock do |lock_file|
				lock_file.flock( File::LOCK_EX )
				source_path = legacy_sqlite_source_path
				next unless source_path

				state = load_legacy_sqlite_state( path: source_path )
				save_state!( state )
			end
		end

		def with_state_lock
			lock_path = "#{path}.lock"
			FileUtils.mkdir_p( File.dirname( lock_path ) )
			FileUtils.touch( lock_path )

			File.open( lock_path, File::RDWR | File::CREAT ) do |lock_file|
				yield lock_file
			end
		end

		def legacy_sqlite_source_path
			return nil unless state_path_requires_migration?
			return path if sqlite_database_file?( path: path )

			legacy_path = legacy_state_path
			return nil unless legacy_path
			return legacy_path if sqlite_database_file?( path: legacy_path )

			nil
		end

		def state_path_requires_migration?
			return true if sqlite_database_file?( path: path )
			return false if File.exist?( path )
			!legacy_state_path.nil?
		end

		def legacy_state_path
			return nil unless path.end_with?( ".json" )
			path.sub( /\.json\z/, ".sqlite3" )
		end

		def sqlite_database_file?( path: )
			return false unless File.file?( path )
			File.binread( path, SQLITE_HEADER.bytesize ) == SQLITE_HEADER
		rescue StandardError
			false
		end

		def load_legacy_sqlite_state( path: )
			begin
				require "sqlite3"
			rescue LoadError => exception
				raise "legacy SQLite ledger found at #{path}, but sqlite3 support is unavailable: #{exception.message}"
			end

			database = open_legacy_sqlite_database( path: path )
			deliveries = database.execute( "SELECT * FROM deliveries ORDER BY id ASC" )
			revisions_by_delivery = database.execute(
				"SELECT * FROM revisions ORDER BY delivery_id ASC, number ASC, id ASC"
			).group_by { |row| row.fetch( "delivery_id" ) }

			state = {
				"deliveries" => {},
				"recovery_events" => [],
				"next_sequence" => 1
			}
			deliveries.each do |row|
				key = delivery_key(
					repo_path: row.fetch( "repo_path" ),
					branch_name: row.fetch( "branch_name" ),
					head: row.fetch( "head" )
				)
				state[ "deliveries" ][ key ] = {
					"sequence" => row.fetch( "id" ).to_i,
					"repo_path" => row.fetch( "repo_path" ),
					"branch_name" => row.fetch( "branch_name" ),
					"head" => row.fetch( "head" ),
					"worktree_path" => row.fetch( "worktree_path" ),
					"status" => row.fetch( "status" ),
					"pr_number" => row.fetch( "pr_number" ),
					"pr_url" => row.fetch( "pr_url" ),
					"pull_request_state" => nil,
					"pull_request_draft" => nil,
					"pull_request_merged_at" => nil,
					"merge_proof" => nil,
					"cause" => row.fetch( "cause" ),
					"summary" => row.fetch( "summary" ),
					"created_at" => row.fetch( "created_at" ),
					"updated_at" => row.fetch( "updated_at" ),
					"integrated_at" => row.fetch( "integrated_at" ),
					"superseded_at" => row.fetch( "superseded_at" ),
					"revisions" => Array( revisions_by_delivery[ row.fetch( "id" ) ] ).map do |revision|
						{
							"number" => revision.fetch( "number" ).to_i,
							"cause" => revision.fetch( "cause" ),
							"provider" => revision.fetch( "provider" ),
							"status" => revision.fetch( "status" ),
							"started_at" => revision.fetch( "started_at" ),
							"finished_at" => revision.fetch( "finished_at" ),
							"summary" => revision.fetch( "summary" )
						}
					end
				}
			end
			normalise_state!( state: state )
			state
		ensure
			database&.close
		end

		def open_legacy_sqlite_database( path: )
			database = SQLite3::Database.new( "file:#{path}?immutable=1", readonly: true, uri: true )
			database.results_as_hash = true
			database.busy_timeout = 5_000
			database
		rescue SQLite3::CantOpenException
			database&.close
			database = SQLite3::Database.new( path, readonly: true )
			database.results_as_hash = true
			database.busy_timeout = 5_000
			database
		end

		def normalise_state!( state: )
			deliveries = state[ "deliveries" ]
			raise "state file must contain a JSON object at #{path}" unless deliveries.is_a?( Hash )
			state[ "recovery_events" ] = Array( state[ "recovery_events" ] )

			sequence_counts = Hash.new( 0 )
			deliveries.each_value do |data|
				data[ "revisions" ] = Array( data[ "revisions" ] )
				data[ "merge_proof" ] = serialise_merge_proof( merge_proof: data[ "merge_proof" ] ) if data.key?( "merge_proof" )
				sequence = integer_or_nil( value: data[ "sequence" ] )
				sequence_counts[ sequence ] += 1 unless sequence.nil? || sequence <= 0
			end

			max_sequence = sequence_counts.keys.max.to_i
			next_sequence = max_sequence + 1
			deliveries.keys.sort_by { |key| [ deliveries.fetch( key ).fetch( "created_at", "" ).to_s, key ] }.each do |key|
				data = deliveries.fetch( key )
				sequence = integer_or_nil( value: data[ "sequence" ] )
				if sequence.nil? || sequence <= 0 || sequence_counts[ sequence ] > 1
					sequence = next_sequence
					next_sequence += 1
				end
				data[ "sequence" ] = sequence
			end

			recorded_next = integer_or_nil( value: state[ "next_sequence" ] ) || 1
			state[ "next_sequence" ] = [ recorded_next, next_sequence ].max
		end

		def next_delivery_sequence!( state: )
			sequence = integer_or_nil( value: state[ "next_sequence" ] ) || 1
			state[ "next_sequence" ] = sequence + 1
			sequence
		end

		def integer_or_nil( value: )
			Integer( value )
		rescue ArgumentError, TypeError
			nil
		end

		def delivery_sequence( data: )
			integer_or_nil( value: data[ "sequence" ] ) || 0
		end

		def matching_deliveries( state:, repo_paths:, branch_name:, head: UNSET )
			state[ "deliveries" ].select do |_key, data|
				next false unless repo_paths.include?( data[ "repo_path" ] )
				next false unless data[ "branch_name" ] == branch_name
				next false unless head.equal?( UNSET ) || data[ "head" ] == head

				true
			end
		end

		def resolve_delivery_entry( state:, delivery: )
			data = state[ "deliveries" ][ delivery.key ]
			return [ delivery.key, data ] if data

			repo_paths = repo_identity_paths( repo_path: delivery.repo_path )
			match = matching_deliveries(
				state: state,
				repo_paths: repo_paths,
				branch_name: delivery.branch,
				head: delivery.head
			).max_by { |key, row| [ row[ "updated_at" ].to_s, delivery_sequence( data: row ), key ] }
			raise "delivery not found: #{delivery.key}" unless match

			match
		end

		def merged_revisions( entries: )
			entries
				.flat_map { |_key, data| Array( data[ "revisions" ] ) }
				.map do |revision|
					{
						"number" => revision.fetch( "number", 0 ).to_i,
						"cause" => revision[ "cause" ],
						"provider" => revision[ "provider" ],
						"status" => revision[ "status" ],
						"started_at" => revision[ "started_at" ],
						"finished_at" => revision[ "finished_at" ],
						"summary" => revision[ "summary" ]
					}
				end
				.uniq do |revision|
					[
						revision[ "cause" ],
						revision[ "provider" ],
						revision[ "status" ],
						revision[ "started_at" ],
						revision[ "finished_at" ],
						revision[ "summary" ]
					]
				end
				.sort_by { |revision| [ revision.fetch( "started_at", "" ).to_s, revision.fetch( "number", 0 ).to_i ] }
				.each_with_index
				.map do |revision, index|
					revision.merge( "number" => index + 1 )
				end
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

		def serialise_merge_proof( merge_proof: )
			return nil unless merge_proof.is_a?( Hash )

			{
				"applicable" => merge_proof[ :applicable ].nil? ? merge_proof[ "applicable" ] : merge_proof[ :applicable ],
				"proven" => merge_proof[ :proven ].nil? ? merge_proof[ "proven" ] : merge_proof[ :proven ],
				"basis" => merge_proof[ :basis ] || merge_proof[ "basis" ],
				"summary" => merge_proof[ :summary ] || merge_proof[ "summary" ],
				"main_branch" => merge_proof[ :main_branch ] || merge_proof[ "main_branch" ],
				"changed_files_count" => ( merge_proof[ :changed_files_count ] || merge_proof[ "changed_files_count" ] || 0 ).to_i
			}
		end

		def deserialise_merge_proof( merge_proof: )
			return nil unless merge_proof.is_a?( Hash )

			{
				applicable: merge_proof[ "applicable" ],
				proven: merge_proof[ "proven" ],
				basis: merge_proof[ "basis" ],
				summary: merge_proof[ "summary" ],
				main_branch: merge_proof[ "main_branch" ],
				changed_files_count: merge_proof.fetch( "changed_files_count", 0 ).to_i
			}
		end

		def now_utc
			Time.now.utc.iso8601( 6 )
		end

		def record_recovery_event( repository:, branch_name:, pr_number:, pr_url:, check_name:, default_branch:, default_branch_sha:, pr_sha:, actor:, merge_method:, status:, summary: )
			timestamp = now_utc

			with_state do |state|
				state[ "recovery_events" ] ||= []
				event = {
					"repository" => repository.path,
					"branch_name" => branch_name,
					"pr_number" => pr_number,
					"pr_url" => pr_url,
					"check_name" => check_name,
					"default_branch" => default_branch,
					"default_branch_sha" => default_branch_sha,
					"pr_sha" => pr_sha,
					"actor" => actor,
					"merge_method" => merge_method,
					"status" => status,
					"summary" => summary,
					"recorded_at" => timestamp
				}
				state[ "recovery_events" ] << event
				event
			end
		end
	end
end
