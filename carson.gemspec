# frozen_string_literal: true

require_relative "lib/carson/version"

Gem::Specification.new do |spec|
	spec.name = "carson"
	spec.version = Carson::VERSION
	spec.authors = [ "Hailei Wang", "Codex", "Claude Code" ]
	spec.email = [ "wanghailei@users.noreply.github.com" ]
	spec.summary = "Autonomous git strategist and repositories governor — you write the code, Carson manages everything else."
	spec.description = "Carson is an autonomous git strategist and repositories governor that lives outside the repositories it governs — no Carson-owned artefacts in your repo. As strategist, Carson knows when to branch, how to isolate concurrent work, and how to recover from failures. As governor, it enforces review gates, manages templates, and triages every open PR across your portfolio: merge what's ready, dispatch coding agents to fix what's failing, escalate what needs human judgement. One command, all your projects, unmanned."
	spec.homepage = "https://github.com/wanghailei/carson"
	spec.license = "PolyForm-Shield-1.0.0"
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
	spec.add_dependency "sqlite3", ">= 1.3", "< 3"
	spec.files = Dir.glob( "{lib,exe,templates,hooks}/**/*", File::FNM_DOTMATCH ).select { |path| File.file?( path ) } + [
		".github/workflows/carson_policy.yml",
		"README.md",
		"MANUAL.md",
		"API.md",
		"RELEASE.md",
		"VERSION",
		"LICENSE",
		"icon.svg",
		"carson.gemspec"
	]
end
