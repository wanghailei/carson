# frozen_string_literal: true

require_relative "lib/carson/version"

Gem::Specification.new do |spec|
	spec.name = "carson"
	spec.version = Carson::VERSION
	spec.authors = [ "Hailei Wang" ]
	spec.email = [ "noreply@example.com" ]
	spec.summary = "Outsider governance runtime for repository hygiene and merge readiness."
	spec.description = "Carson runs outside host repositories and applies governance checks, review gates, and managed GitHub-native files."
	spec.homepage = "https://github.com/wanghailei/carson"
	spec.license = "MIT"
	spec.required_ruby_version = ">= 4.0"
	spec.metadata = {
		"source_code_uri" => "https://github.com/wanghailei/carson",
		"changelog_uri" => "https://github.com/wanghailei/carson/blob/main/RELEASE.md"
	}

	spec.bindir = "exe"
	spec.executables = [ "carson" ]
	spec.require_paths = [ "lib" ]
	spec.files = Dir.glob( "{lib,exe,templates,assets,script,docs,.github}/**/*", File::FNM_DOTMATCH ).select { |path| File.file?( path ) } + [ "README.md", "MANUAL.md", "API.md", "RELEASE.md", "VERSION", "carson.gemspec" ]
end
