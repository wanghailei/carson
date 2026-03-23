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
			diagnosis, *recovery_steps = translate_hold( result[ :hold_reason ], remote_main: remote_main )
			output.puts "#{BADGE} #{diagnosis}"
			recovery_steps.each do |step|
				output.puts "  \u2192 #{step}"
			end
		when "rejected"
			output.puts "#{BADGE} PR closed externally."
		when "filed"
			output.puts "#{BADGE} Bureau hasn't responded yet. Run carson status to check back."
		end
	end

	# Translate internal hold reasons to agent-actionable output.
	# Returns [ diagnosis, *recovery_steps ]. The diagnosis says what
	# happened. Each recovery step is a command the agent can execute.
	def self.translate_hold( reason, remote_main: "origin/main" )
		case reason
		when "draft"
			[ "PR is still a draft." ]
		when "pending_at_registry"
			[ "Waiting for CI checks.", "carson status" ]
		when "failed_at_registry"
			[ "CI checks failed.", "carson deliver" ]
		when "error_at_registry"
			[ "Unable to assess CI checks.", "carson status" ]
		when "merge_conflict"
			[ "Merge conflict with #{remote_main}.", "git rebase #{remote_main}", "carson deliver" ]
		when "behind_registry"
			[ "Branch is behind #{remote_main}.", "carson deliver" ]
		when "policy_block"
			[ "Blocked by branch protection rules." ]
		when "mergeability_pending"
			[ "GitHub is calculating mergeability.", "carson status" ]
		else
			[ "Waiting for merge readiness.", "carson status" ]
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
