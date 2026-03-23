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

	# Human-readable delivery report — technical language for agents and humans.
	# Story language is internal (source code). Output speaks the client's language.
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
			output.puts "#{BADGE} Merged."
			output.puts "#{BADGE} Local main synced." if result[ :synced ]
		when "held"
			output.puts "#{BADGE} #{translate_hold( result[ :hold_reason ] )}"
		when "rejected"
			output.puts "#{BADGE} PR closed externally."
		when "deferred"
			output.puts "#{BADGE} Merge deferred \u2014 still waiting."
			output.puts "  \u2192 carson deliver"
		end
	end

	# Translate internal hold reasons to technical language agents understand.
	def self.translate_hold( reason )
		case reason
		when "draft" then "PR is still a draft."
		when "inspector_pending" then "Waiting for CI checks."
		when "inspector_failed" then "CI checks failed."
		when "inspector_error" then "Unable to assess CI checks."
		when "merge_conflict" then "Merge conflict with main."
		when "behind_registry" then "Branch is behind main."
		when "policy_block" then "Blocked by branch protection rules."
		when "mergeability_pending" then "GitHub is calculating mergeability."
		else "Waiting for merge readiness."
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
