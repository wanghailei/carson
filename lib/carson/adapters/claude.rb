require "open3"
require "json"

module Carson
	module Adapters
		class Claude
			include Prompt

			def initialize( repo_root:, config: {} )
				@repo_root = repo_root
				@config = config
			end

			def dispatch( work_order: )
				prompt = build_prompt( work_order: work_order )
				stdout_text, stderr_text, status = Open3.capture3(
					"claude", "-p", "--output-format", "text",
					prompt,
					chdir: repo_root
				)
				parse_result( stdout_text: stdout_text, stderr_text: stderr_text, success: status.success? )
			rescue Errno::ENOENT
				Agent::Result.new(
					status: "failed",
					summary: "claude CLI not found in PATH",
					evidence: nil,
					commit_sha: nil
				)
			end

		private

			attr_reader :repo_root, :config

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
