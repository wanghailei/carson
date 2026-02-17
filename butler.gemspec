# frozen_string_literal: true

require_relative "lib/butler/version"

Gem::Specification.new do |spec|
	spec.name = "butler-governance"
	spec.version = Butler::VERSION
	spec.authors = [ "Hailei Wang" ]
	spec.email = [ "noreply@example.com" ]
	spec.summary = "Outsider governance runtime for repository hygiene and merge readiness."
	spec.description = "Butler runs outside host repositories and applies governance checks, review gates, and managed GitHub-native files."
	spec.homepage = "https://github.com/wanghailei/butler"
	spec.license = "MIT"
	spec.required_ruby_version = ">= 4.0"
	spec.metadata = {
		"source_code_uri" => "https://github.com/wanghailei/butler",
		"changelog_uri" => "https://github.com/wanghailei/butler/blob/main/RELEASE.md"
	}

	spec.bindir = "exe"
	spec.executables = [ "butler" ]
	spec.require_paths = [ "lib" ]
	spec.files = Dir.glob( "{lib,exe,templates,assets,script,docs,.github}/**/*", File::FNM_DOTMATCH ).select { |path| File.file?( path ) } + [ "README.md", "RELEASE.md", "VERSION", "butler.gemspec" ]
end
