# Guard: story language must not leak into user-facing output.
# Carson speaks two languages (spec.oo.md § Two Languages):
#   Story language — source code, class names, method names, comments.
#   Technical language — CLI output, error text, recovery instructions.
# This test enforces the boundary mechanically.

require_relative "test_helper"

class StoryLanguageGuardTest < Minitest::Test
	# Story-language nouns that must not appear in user-facing output strings.
	# Clients know git/GitHub terms, not Carson's internal metaphor.
	FORBIDDEN_TERMS = %w[ workbench warehouse parcel courier bureau waybill vault ].freeze

	# Patterns that identify lines producing user-facing output.
	# These are the surfaces where technical language is required.
	OUTPUT_PATTERNS = [
		/output\.puts/,
		/error\.puts/,
		/parser\.separator/,
		/parser\.banner/,
		/\berror:\s*"/,
		/\brecovery:\s*"/,
	].freeze

	# Verify each forbidden term is caught individually.
	def test_catches_story_terms_in_output_and_help
		# These patterns represent the kind of leaks the integration test catches.
		samples = [
			'output.puts "#{BADGE} Workbench ready: #{result[ :name ]}"',
			'parser.separator "Release a workbench when safe."',
			'error: "workbench is sealed",',
		]
		samples.each do |line|
			assert_match( /workbench/i, line, "should detect story language in: #{line}" )
		end
	end

	def test_catches_story_terms_in_error_hashes
		line = 'error: "workbench is sealed",'
		assert_match( /workbench/, line.downcase )
	end

	def test_ignores_interpolated_variable_names
		# Interpolation expressions are source code — variable names like
		# workbench.path and @bureau_address use story language correctly.
		# The rendered output shows values, not the variable names.
		content = 'recovery: "git -C #{workbench.path} push #{@bureau_address}"'
		literal = content.gsub( /\#\{[^}]*\}/, "" )
		FORBIDDEN_TERMS.each do |term|
			refute literal.downcase.include?( term ),
				"interpolation should be stripped — '#{term}' should not be flagged"
		end
	end

	def test_no_story_language_in_output_strings
		violations = []
		lib_root = File.join( repo_root, "lib" )
		lib_files = Dir.glob( File.join( lib_root, "**", "*.rb" ) )

		lib_files.each do |file|
			relative = file.sub( "#{repo_root}/", "" )
			File.readlines( file ).each_with_index do |line, index|
				next unless OUTPUT_PATTERNS.any? { |pattern| line.match?( pattern ) }

				# Extract string content — text between quotes, with interpolation stripped.
				# #{variable.method} is source code (story language OK there).
				# Only the literal text around interpolation reaches the user.
				strings = line.scan( /"([^"]*)"/ ).flatten + line.scan( /'([^']*)'/ ).flatten
				strings.each do |content|
					literal_text = content.gsub( /\#\{[^}]*\}/, "" )
					FORBIDDEN_TERMS.each do |term|
						if literal_text.downcase.include?( term )
							violations << "#{relative}:#{index + 1} — '#{term}' in output: #{line.strip}"
						end
					end
				end
			end
		end

		assert_empty violations,
			"Story language leaked into user-facing output:\n#{violations.join( "\n" )}"
	end

private

	def repo_root
		File.expand_path( "..", __dir__ )
	end
end
