require "open3"
require "json"

module Carson
	module Adapters
		class Codex
			def initialize( repo_root:, config: {} )
				@repo_root = repo_root
				@config = config
			end

			def dispatch( work_order: )
				prompt = build_prompt( work_order: work_order )
				stdout_text, stderr_text, status = Open3.capture3(
					"codex", "--quiet", "--approval-mode", "full-auto",
					prompt,
					chdir: repo_root
				)
				parse_result( stdout_text: stdout_text, stderr_text: stderr_text, success: status.success? )
			rescue Errno::ENOENT
				Agent::Result.new(
					status: "failed",
					summary: "codex CLI not found in PATH",
					evidence: nil,
					commit_sha: nil
				)
			end

		private

			attr_reader :repo_root, :config

			def build_prompt( work_order: )
				parts = []
				parts << "Repository: #{work_order.repo}"
				parts << "Branch: #{work_order.branch}"
				parts << "PR: ##{work_order.pr_number}"
				parts << "Objective: #{work_order.objective}"
				parts << "Context:\n#{work_order.context}"
				parts << "Acceptance checks: #{work_order.acceptance_checks}" if work_order.acceptance_checks
				parts.join( "\n\n" )
			end

			def parse_result( stdout_text:, stderr_text:, success: )
				Agent::Result.new(
					status: success ? "done" : "failed",
					summary: success ? stdout_text.to_s.strip : stderr_text.to_s.strip,
					evidence: stdout_text.to_s.strip,
					commit_sha: nil
				)
			end
		end
	end
end
