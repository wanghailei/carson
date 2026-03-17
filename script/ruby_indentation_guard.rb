#!/usr/bin/env ruby
require "ripper"

module Carson
	module RubyIndentationGuard
	module_function

		POLICY = "tabs"
		ACCESS_MODIFIERS = %w[private protected public].freeze
		IGNORED_TOKEN_TYPES = %i[
			on_sp
			on_comment
			on_nl
			on_ignored_nl
			on_tstring_content
			on_tstring_beg
			on_tstring_end
			on_heredoc_beg
			on_heredoc_end
		].freeze

		def run!
			repo_root = File.expand_path( "..", __dir__ )
			policy = POLICY
			violations = ruby_files( repo_root: repo_root ).flat_map do |path|
				file_violations( path: path, repo_root: repo_root, policy: policy )
			end
			if violations.empty?
				puts "OK: ruby indentation policy #{policy}."
				exit 0
			end

			violations.each { |entry| warn entry }
			exit 1
		end

		def ruby_files( repo_root: )
			roots = %w[lib exe script .github test]
			patterns = roots.map { |root| File.join( repo_root, root, "**", "*.rb" ) }
			Dir.glob( patterns, File::FNM_DOTMATCH ).select { |path| File.file?( path ) }.sort
		end

		def file_violations( path:, repo_root:, policy: )
			source = File.read( path )
			lines = source.lines( chomp: true )
			tokens_by_line = Ripper.lex( source ).group_by { |( position, _, _, _ )| position[ 0 ] - 1 }
			lines.each_with_index.each_with_object( [] ) do |( line, index ), entries|
				significant_tokens = significant_tokens_for_line( tokens_by_line: tokens_by_line, index: index )
				next if significant_tokens.empty?

				match = line.match( /^(?<indent>[ \t]+)\S/ )
				relative = path.sub( "#{repo_root}/", "" )
				unless match.nil?
					indent = match[ :indent ]
					has_tabs = indent.include?( "\t" )
					has_spaces = indent.include?( " " )
					if indentation_violation?( policy: policy, has_tabs: has_tabs, has_spaces: has_spaces )
						entries << "#{relative}:#{index + 1}: #{indentation_message( policy: policy )}"
					end
				end

				next unless access_modifier_violation?( lines: lines, tokens_by_line: tokens_by_line, index: index )

				entries << "#{relative}:#{index + 1}: #{access_modifier_message}"
			end
		end

		def access_modifier_violation?( lines:, tokens_by_line:, index: )
			return false unless access_modifier_line?( tokens: significant_tokens_for_line( tokens_by_line: tokens_by_line, index: index ) )

			next_index = next_member_index( tokens_by_line: tokens_by_line, start: index + 1 )
			return false if next_index.nil?

			leading_indent( lines[ next_index ] ).length <= leading_indent( lines[ index ] ).length
		end

		def access_modifier_line?( tokens: )
			return false unless tokens.length == 1

			type, text = tokens.first
			[ :on_ident, :on_kw ].include?( type ) && ACCESS_MODIFIERS.include?( text )
		end

		def next_member_index( tokens_by_line:, start: )
			(tokens_by_line.keys.max || -1).then do |last_index|
				(start..last_index).find do |index|
					tokens = significant_tokens_for_line( tokens_by_line: tokens_by_line, index: index )
					next false if tokens.empty?
					next false if access_modifier_line?( tokens: tokens )
					next false if end_only_line?( tokens: tokens )

					true
				end
			end
		end

		def leading_indent( line )
			line[ /^[ \t]*/ ] || ""
		end

		def significant_tokens_for_line( tokens_by_line:, index: )
			Array( tokens_by_line[ index ] ).each_with_object( [] ) do |( _position, type, text, _state ), entries|
				next if IGNORED_TOKEN_TYPES.include?( type )

				entries << [ type, text ]
			end
		end

		def end_only_line?( tokens: )
			tokens.length == 1 && tokens.first == [ :on_kw, "end" ]
		end

		def indentation_violation?( policy:, has_tabs:, has_spaces: )
			case policy
			when "tabs"
				has_spaces
			when "spaces"
				has_tabs
			when "either"
				has_tabs && has_spaces
			else
				true
			end
		end

		def indentation_message( policy: )
			case policy
			when "tabs"
				"space-based indentation detected in Ruby source; use hard tabs"
			when "spaces"
				"tab-based indentation detected in Ruby source; use spaces"
			when "either"
				"mixed tab/space indentation detected in Ruby source"
			else
				"invalid ruby indentation policy"
			end
		end

		def access_modifier_message
			"indented access modifier detected in Ruby source; outdent private/protected/public one level below the surrounding scope"
		end
	end
end

Carson::RubyIndentationGuard.run! if __FILE__ == $PROGRAM_NAME
