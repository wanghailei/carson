# frozen_string_literal: true

require_relative "lib/carson/version"

Gem::Specification.new do |spec|
	spec.name = "carson"
	spec.version = Carson::VERSION
	spec.authors = [ "Hailei Wang" ]
	spec.email = [ "wanghailei@users.noreply.github.com" ]
	spec.summary = "Autonomous governance runtime — lint, review gates, PR triage, and merge across repositories."
	spec.description = "Carson lives outside the repositories it governs. On every commit it enforces centralised lint policy and scope checks. On PRs it gates merge on unresolved reviewer feedback, dispatches coding agents to fix CI failures, merges passing PRs, and housekeeps branches. Runs locally and in GitHub Actions."
	spec.homepage = "https://github.com/wanghailei/carson"
	spec.license = "MIT"
	spec.required_ruby_version = ">= 3.4"
	spec.metadata = {
		"source_code_uri" => "https://github.com/wanghailei/carson",
		"changelog_uri" => "https://github.com/wanghailei/carson/blob/main/RELEASE.md",
		"bug_tracker_uri" => "https://github.com/wanghailei/carson/issues",
		"documentation_uri" => "https://github.com/wanghailei/carson/blob/main/MANUAL.md"
	}

	spec.post_install_message = <<~MSG
		\u29D3 Carson at your service.
		  Step into your project directory and run: carson onboard
		  I'll walk you through everything from there.
	MSG

	spec.bindir = "exe"
	spec.executables = [ "carson" ]
	spec.require_paths = [ "lib" ]
	spec.files = Dir.glob( "{lib,exe,templates,hooks}/**/*", File::FNM_DOTMATCH ).select { |path| File.file?( path ) } + [
		".github/copilot-instructions.md",
		".github/pull_request_template.md",
		".github/workflows/carson_policy.yml",
		"README.md",
		"MANUAL.md",
		"API.md",
		"RELEASE.md",
		"VERSION",
		"LICENSE",
		"SKILL.md",
		"icon.svg",
		"carson.gemspec"
	]
end
