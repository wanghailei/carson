#!/usr/bin/env ruby
require_relative "../lib/carson/config"

module Carson
	module RubyIndentationGuard
		module_function

		def run!
			repo_root = File.expand_path( "..", __dir__ )
			config = Carson::Config.load( repo_root: repo_root )
			policy = config.ruby_indentation
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
			roots = %w[lib exe script .github]
			patterns = roots.map { |root| File.join( repo_root, root, "**", "*.rb" ) }
			Dir.glob( patterns, File::FNM_DOTMATCH ).select { |path| File.file?( path ) }.sort
		end

		def file_violations( path:, repo_root:, policy: )
			File.readlines( path, chomp: true ).each_with_index.each_with_object( [] ) do |( line, index ), entries|
				match = line.match( /^(?<indent>[ \t]+)\S/ )
				next if match.nil?
				indent = match[ :indent ]
				has_tabs = indent.include?( "\t" )
				has_spaces = indent.include?( " " )
				next unless indentation_violation?( policy: policy, has_tabs: has_tabs, has_spaces: has_spaces )

				relative = path.sub( "#{repo_root}/", "" )
				entries << "#{relative}:#{index + 1}: #{indentation_message( policy: policy )}"
			end
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
	end
end

Carson::RubyIndentationGuard.run!
