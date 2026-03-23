# Loads all Carson modules and defines the top-level namespace.
require_relative "carson/version"

module Carson
	BADGE = "\u29D3".freeze # ⧓ BLACK BOWTIE (U+29D3)

	# The company renders results for whoever is listening.
	# JSON is the primary format (agents consume it). Human-readable is secondary.
	# Domain objects return result hashes — Carson decides how to present them.
	def self.report( result, format: :json, output: $stdout )
		case format
		when :json
			require "json"
			output.puts JSON.pretty_generate( result )
		when :human
			report_human( result, output: output )
		end
	end

	# Human-readable delivery report — the secondary format.
	def self.report_human( result, output: $stdout )
		if result[ :error ]
			output.puts "#{BADGE} #{result[ :error ]}"
			output.puts "  \u2192 #{result[ :recovery ]}" if result[ :recovery ]
			return
		end

		output.puts "#{BADGE} Delivery: #{result[ :label ]}" if result[ :label ]
		output.puts "#{BADGE} PR ##{result[ :tracking_number ]}  #{result[ :url ]}" if result[ :tracking_number ]

		case result[ :outcome ]
		when "delivered"
			output.puts "#{BADGE} Delivered."
			output.puts "#{BADGE} Warehouse updated to latest standard." if result[ :synced ]
		when "held"
			output.puts "#{BADGE} Held \u2014 #{result[ :hold_summary ]}."
		when "rejected"
			output.puts "#{BADGE} Rejected \u2014 waybill closed externally."
		when "deferred"
			output.puts "#{BADGE} Deferred \u2014 watch window expired."
			output.puts "  \u2192 carson deliver"
		end
	end

	private_class_method :report_human
end

require_relative "carson/repository"
require_relative "carson/branch"
require_relative "carson/delivery"
require_relative "carson/revision"
require_relative "carson/ledger"
require_relative "carson/parcel"
require_relative "carson/warehouse"
require_relative "carson/waybill"
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
