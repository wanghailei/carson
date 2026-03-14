# SQLite-backed ledger for Carson's deliveries and revisions.
require "fileutils"
require "sqlite3"
require "time"

module Carson
	class Ledger
		UNSET = Object.new
		ACTIVE_DELIVERY_STATES = %w[preparing gated queued integrating escalated].freeze

		def initialize( path: )
			@path = File.expand_path( path )
			prepare!
		end

		attr_reader :path

		# Ensures the SQLite schema exists before Carson uses the ledger.
		def prepare!
			FileUtils.mkdir_p( File.dirname( path ) )

			with_database do |database|
				database.execute_batch( <<~SQL )
					CREATE TABLE IF NOT EXISTS deliveries (
						id INTEGER PRIMARY KEY AUTOINCREMENT,
						repo_path TEXT NOT NULL,
						branch_name TEXT NOT NULL,
						head TEXT NOT NULL,
						worktree_path TEXT,
						authority TEXT NOT NULL,
						status TEXT NOT NULL,
						pr_number INTEGER,
						pr_url TEXT,
						revision_count INTEGER NOT NULL DEFAULT 0,
						cause TEXT,
						summary TEXT,
						created_at TEXT NOT NULL,
						updated_at TEXT NOT NULL,
						integrated_at TEXT,
						superseded_at TEXT
					);

					CREATE UNIQUE INDEX IF NOT EXISTS index_deliveries_on_identity
						ON deliveries ( repo_path, branch_name, head );

					CREATE INDEX IF NOT EXISTS index_deliveries_on_state
						ON deliveries ( repo_path, status, created_at );

					CREATE TABLE IF NOT EXISTS revisions (
						id INTEGER PRIMARY KEY AUTOINCREMENT,
						delivery_id INTEGER NOT NULL,
						number INTEGER NOT NULL,
						cause TEXT NOT NULL,
						provider TEXT NOT NULL,
						status TEXT NOT NULL,
						started_at TEXT NOT NULL,
						finished_at TEXT,
						summary TEXT,
						FOREIGN KEY ( delivery_id ) REFERENCES deliveries ( id )
					);

					CREATE UNIQUE INDEX IF NOT EXISTS index_revisions_on_delivery_number
						ON revisions ( delivery_id, number );
				SQL
			end
		end

		# Creates or refreshes a delivery for the same branch head.
		def upsert_delivery( repository:, branch_name:, head:, worktree_path:, authority:, pr_number:, pr_url:, status:, summary:, cause: )
			timestamp = now_utc

			with_database do |database|
				row = database.get_first_row(
					"SELECT * FROM deliveries WHERE repo_path = ? AND branch_name = ? AND head = ? LIMIT 1",
					[ repository.path, branch_name, head ]
				)

				if row
					database.execute(
						<<~SQL,
							UPDATE deliveries
							   SET worktree_path = ?, authority = ?, status = ?, pr_number = ?, pr_url = ?,
							       cause = ?, summary = ?, updated_at = ?
							 WHERE id = ?
						SQL
						[ worktree_path, authority, status, pr_number, pr_url, cause, summary, timestamp, row.fetch( "id" ) ]
					)
					return fetch_delivery( database: database, id: row.fetch( "id" ), repository: repository )
				end

				supersede_branch!( database: database, repository: repository, branch_name: branch_name, timestamp: timestamp )
				database.execute(
					<<~SQL,
						INSERT INTO deliveries (
							repo_path, branch_name, head, worktree_path, authority, status,
							pr_number, pr_url, revision_count, cause, summary, created_at, updated_at
						) VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ? )
					SQL
					[
						repository.path, branch_name, head, worktree_path, authority, status,
						pr_number, pr_url, cause, summary, timestamp, timestamp
					]
				)
				fetch_delivery( database: database, id: database.last_insert_row_id, repository: repository )
			end
		end

		# Looks up the active delivery for a branch, if one exists.
		def active_delivery( repo_path:, branch_name: )
			with_database do |database|
				row = database.get_first_row(
					<<~SQL,
						SELECT * FROM deliveries
						 WHERE repo_path = ? AND branch_name = ? AND status IN ( #{active_state_placeholders} )
						 ORDER BY updated_at DESC
						 LIMIT 1
					SQL
					[ repo_path, branch_name, *ACTIVE_DELIVERY_STATES ]
				)
				build_delivery( row: row ) if row
			end
		end

		# Lists active deliveries for a repository in creation order.
		def active_deliveries( repo_path: )
			with_database do |database|
				rows = database.execute(
					<<~SQL,
						SELECT * FROM deliveries
						 WHERE repo_path = ? AND status IN ( #{active_state_placeholders} )
						 ORDER BY created_at ASC, id ASC
					SQL
					[ repo_path, *ACTIVE_DELIVERY_STATES ]
				)
				rows.map { |row| build_delivery( row: row ) }
			end
		end

		# Lists queued deliveries ready for integration.
		def queued_deliveries( repo_path: )
			with_database do |database|
				database.execute(
					"SELECT * FROM deliveries WHERE repo_path = ? AND status = ? ORDER BY created_at ASC, id ASC",
					[ repo_path, "queued" ]
				).map { |row| build_delivery( row: row ) }
			end
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
			revision_count: UNSET,
			integrated_at: UNSET,
			superseded_at: UNSET
		)
			updates = {}
			updates[ "status" ] = status unless status.equal?( UNSET )
			updates[ "pr_number" ] = pr_number unless pr_number.equal?( UNSET )
			updates[ "pr_url" ] = pr_url unless pr_url.equal?( UNSET )
			updates[ "cause" ] = cause unless cause.equal?( UNSET )
			updates[ "summary" ] = summary unless summary.equal?( UNSET )
			updates[ "worktree_path" ] = worktree_path unless worktree_path.equal?( UNSET )
			updates[ "revision_count" ] = revision_count unless revision_count.equal?( UNSET )
			updates[ "integrated_at" ] = integrated_at unless integrated_at.equal?( UNSET )
			updates[ "superseded_at" ] = superseded_at unless superseded_at.equal?( UNSET )
			updates[ "updated_at" ] = now_utc

			with_database do |database|
				assignments = updates.keys.map { |key| "#{key} = ?" }.join( ", " )
				database.execute(
					"UPDATE deliveries SET #{assignments} WHERE id = ?",
					updates.values + [ delivery.id ]
				)
				fetch_delivery( database: database, id: delivery.id, repository: delivery.repository )
			end
		end

		# Records one revision cycle against a delivery and bumps the delivery counter.
		def record_revision( delivery:, cause:, provider:, status:, summary: )
			timestamp = now_utc

			with_database do |database|
				next_number = database.get_first_value(
					"SELECT COALESCE( MAX(number), 0 ) + 1 FROM revisions WHERE delivery_id = ?",
					[ delivery.id ]
				).to_i
				database.execute(
					<<~SQL,
						INSERT INTO revisions ( delivery_id, number, cause, provider, status, started_at, finished_at, summary )
						VALUES ( ?, ?, ?, ?, ?, ?, ?, ? )
					SQL
					[
						delivery.id, next_number, cause, provider, status, timestamp,
						( status == "completed" || status == "failed" || status == "stalled" ) ? timestamp : nil,
						summary
					]
				)
				database.execute(
					"UPDATE deliveries SET revision_count = ?, updated_at = ? WHERE id = ?",
					[ next_number, timestamp, delivery.id ]
				)
				build_revision(
					row: database.get_first_row( "SELECT * FROM revisions WHERE id = ?", [ database.last_insert_row_id ] )
				)
			end
		end

		# Lists revisions for a delivery in ascending order.
		def revisions_for_delivery( delivery_id: )
			with_database do |database|
				database.execute(
					"SELECT * FROM revisions WHERE delivery_id = ? ORDER BY number ASC, id ASC",
					[ delivery_id ]
				).map { |row| build_revision( row: row ) }
			end
		end

	private

		def with_database
			database = SQLite3::Database.new( path )
			database.results_as_hash = true
			database.busy_timeout = 5_000
			database.execute( "PRAGMA journal_mode = WAL" )
			yield database
		ensure
			database&.close
		end

		def fetch_delivery( database:, id:, repository: nil )
			row = database.get_first_row( "SELECT * FROM deliveries WHERE id = ?", [ id ] )
			build_delivery( row: row, repository: repository )
		end

		def build_delivery( row:, repository: nil )
			return nil unless row

			repository ||= Repository.new(
				path: row.fetch( "repo_path" ),
				authority: row.fetch( "authority" ),
				runtime: nil
			)

			Delivery.new(
				id: row.fetch( "id" ),
				repository: repository,
				branch: row.fetch( "branch_name" ),
				head: row.fetch( "head" ),
				worktree_path: row.fetch( "worktree_path" ),
				authority: row.fetch( "authority" ),
				status: row.fetch( "status" ),
				pull_request_number: row.fetch( "pr_number" ),
				pull_request_url: row.fetch( "pr_url" ),
				revision_count: row.fetch( "revision_count" ).to_i,
				cause: row.fetch( "cause" ),
				summary: row.fetch( "summary" ),
				created_at: row.fetch( "created_at" ),
				updated_at: row.fetch( "updated_at" ),
				integrated_at: row.fetch( "integrated_at" ),
				superseded_at: row.fetch( "superseded_at" )
			)
		end

		def build_revision( row: )
			return nil unless row

			Revision.new(
				id: row.fetch( "id" ),
				delivery_id: row.fetch( "delivery_id" ),
				number: row.fetch( "number" ).to_i,
				cause: row.fetch( "cause" ),
				provider: row.fetch( "provider" ),
				status: row.fetch( "status" ),
				started_at: row.fetch( "started_at" ),
				finished_at: row.fetch( "finished_at" ),
				summary: row.fetch( "summary" )
			)
		end

		def supersede_branch!( database:, repository:, branch_name:, timestamp: )
			database.execute(
				<<~SQL,
					UPDATE deliveries
					   SET status = ?, superseded_at = ?, updated_at = ?
					 WHERE repo_path = ? AND branch_name = ? AND status IN ( #{active_state_placeholders} )
				SQL
				[ "superseded", timestamp, timestamp, repository.path, branch_name, *ACTIVE_DELIVERY_STATES ]
			)
		end

		def active_state_placeholders
			ACTIVE_DELIVERY_STATES.map { "?" }.join( ", " )
		end

		def now_utc
			Time.now.utc.iso8601
		end
	end
end
