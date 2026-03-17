require_relative "test_helper"
require_relative "../script/ruby_indentation_guard"

class RubyIndentationGuardTest < Minitest::Test
	def test_valid_tab_indentation
		violations = check_content( "def foo\n\tbar\nend\n" )
		assert_empty violations
	end

	def test_space_indentation_violation
		violations = check_content( "def foo\n  bar\nend\n" )
		assert_equal 1, violations.size
		assert_match( /space-based indentation/, violations.first )
	end

	def test_mixed_indentation_flags_spaces
		violations = check_content( "def foo\n\t bar\nend\n" )
		assert_equal 1, violations.size
		assert_match( /space-based indentation/, violations.first )
	end

	def test_blank_lines_ignored
		violations = check_content( "def foo\n\n\tbar\nend\n" )
		assert_empty violations
	end

	def test_no_indentation_passes
		violations = check_content( "FOO = 1\nBAR = 2\n" )
		assert_empty violations
	end

	def test_outdented_private_passes
		violations = check_content( <<~RUBY )
			class Example
			private
				def helper
					:ok
				end
			end
		RUBY
		assert_empty violations
	end

	def test_nested_outdented_private_passes
		violations = check_content( <<~RUBY )
			module Outer
				class Example
				private
					def helper
						:ok
					end
				end
			end
		RUBY
		assert_empty violations
	end

	def test_indented_private_violation
		violations = check_content( <<~RUBY )
			class Example
				private
				def helper
					:ok
				end
			end
		RUBY
		assert_equal 1, violations.size
		assert_match( /indented access modifier/, violations.first )
	end

	def test_indented_protected_violation
		violations = check_content( <<~RUBY )
			class Example
				protected
				def helper
					:ok
				end
			end
		RUBY
		assert_equal 1, violations.size
		assert_match( /indented access modifier/, violations.first )
	end

	def test_access_modifier_without_following_member_passes
		violations = check_content( <<~RUBY )
			class Example
			private
			end
		RUBY
		assert_empty violations
	end

	def test_access_modifier_text_inside_heredoc_ignored
		violations = check_content( <<~RUBY )
			SAMPLE = <<~CODE
				class Example
					private
					def helper
						:ok
					end
				end
			CODE
		RUBY
		assert_empty violations
	end

private

	def check_content( content )
		Dir.mktmpdir( "guard-test" ) do |dir|
			path = File.join( dir, "lib", "test_file.rb" )
			FileUtils.mkdir_p( File.dirname( path ) )
			File.write( path, content )
			Carson::RubyIndentationGuard.file_violations(
				path: path,
				repo_root: dir,
				policy: "tabs"
			)
		end
	end
end
