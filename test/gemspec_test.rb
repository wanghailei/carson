require_relative "test_helper"

class GemspecTest < Minitest::Test
	def setup
		@gemspec_path = File.expand_path( "../carson.gemspec", __dir__ )
		@spec = Gem::Specification.load( @gemspec_path )
	end

	def test_gemspec_loads
		refute_nil @spec
		assert_equal "carson", @spec.name
	end

	def test_gemspec_contact_metadata_is_release_ready
		assert_equal [ "wanghailei@users.noreply.github.com" ], @spec.email
		assert_equal "https://github.com/wanghailei/carson/issues", @spec.metadata.fetch( "bug_tracker_uri" )
		assert_equal "https://github.com/wanghailei/carson/blob/main/MANUAL.md", @spec.metadata.fetch( "documentation_uri" )
	end

	def test_gemspec_files_include_license_and_exclude_dev_only_paths
		assert_includes @spec.files, "LICENSE"
		refute @spec.files.any? { |path| path.start_with?( "docs/" ) }
		refute @spec.files.any? { |path| path.start_with?( "script/" ) }
	end

	def test_gemspec_only_includes_approved_dot_github_files
		approved = [
			".github/copilot-instructions.md",
			".github/pull_request_template.md",
			".github/workflows/carson_policy.yml"
		]
		dot_github_files = @spec.files.select { |path| path.start_with?( ".github/" ) }
		assert_equal approved.sort, dot_github_files.sort
	end
end
