# Loads all Carson modules and defines the top-level namespace.
require_relative "carson/version"

module Carson
	BADGE = "\u29D3".freeze # ⧓ BLACK BOWTIE (U+29D3)

	# The company renders results for whoever is listening.
	# JSON is the primary format (agents consume it). Text is secondary.
	# Domain objects return result hashes — Carson decides how to present them.
	def self.report( result, format: :json, output: $stdout )
		case format
		when :json
			require "json"
			output.puts JSON.pretty_generate( result )
		when :text
			report_text( result, output: output )
		end
	end

	# Text delivery report — client language for agents.
	# Story language is internal (source code). Output speaks the client's language.
	def self.report_text( result, output: $stdout )
		if result[ :error ]
			output.puts "#{BADGE} #{result[ :error ]}"
			output.puts "  \u2192 #{result[ :recovery ]}" if result[ :recovery ]
			return
		end

		output.puts "#{BADGE} Delivery: #{result[ :label ]}" if result[ :label ]
		output.puts "#{BADGE} PR ##{result[ :tracking_number ]}  #{result[ :url ]}" if result[ :tracking_number ]

		remote_main = result[ :remote_main ] || "origin/main"

		case result[ :outcome ]
		when "delivered"
			output.puts "#{BADGE} Merged."
			if result[ :synced ]
				output.puts "#{BADGE} Local main synced."
			elsif result.key?( :synced )
				output.puts "#{BADGE} Local main not synced \u2014 run carson sync."
			end
		when "held"
			summary = result[ :hold_summary ] || "Waiting for merge readiness."
			output.puts "#{BADGE} #{summary}"
			recovery_steps_for_hold( result[ :hold_reason ], remote_main: remote_main ).each do |step|
				output.puts "  \u2192 #{step}"
			end
		when "rejected"
			output.puts "#{BADGE} PR closed externally."
		when "filed"
			summary = result[ :hold_summary ] || "Waiting for merge readiness."
			diagnostic = result[ :diagnostic ] ? " (#{result[ :diagnostic ]})" : ""
			output.puts "#{BADGE} #{summary}#{diagnostic}"
			output.puts "  \u2192 carson status"
		end
	end

	# Recovery commands for a held delivery.
	# The report knows what commands to suggest for each situation.
	def self.recovery_steps_for_hold( reason, remote_main: "origin/main" )
		case reason
		when "pending_at_bureau", "mergeability_pending", "error_at_bureau"
			[ "carson status" ]
		when "failed_at_bureau"
			[ "carson deliver" ]
		when "merge_conflict"
			[ "git rebase #{remote_main}", "carson deliver" ]
		when "behind_bureau"
			[ "carson deliver" ]
		else
			[]
		end
	end

	private_class_method :report_text, :recovery_steps_for_hold
end

require_relative "carson/repository"
require_relative "carson/branch"
require_relative "carson/delivery"
require_relative "carson/revision"
require_relative "carson/ledger"
require_relative "carson/parcel"
require_relative "carson/waybill"
require_relative "carson/warehouse"
require_relative "carson/courier"
require_relative "carson/worktree"
require_relative "carson/config"
require_relative "carson/adapters/git"
require_relative "carson/adapters/github"
require_relative "carson/adapters/agent"
require_relative "carson/adapters/prompt"
require_relative "carson/adapters/codex"
require_relative "carson/adapters/claude"
require_relative "carson/runtime"
require_relative "carson/cli"
