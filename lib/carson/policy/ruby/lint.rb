#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_BLOCK = 2

def rubocop_config_path
	File.expand_path( "~/.carson/lint/rubocop.yml" )
end

def print_stream( io, text )
	content = text.to_s
	return if content.empty?
	io.print( content )
end

def run_rubocop( files: )
	stdout_text, stderr_text, status = Open3.capture3(
		"rubocop", "--config", rubocop_config_path, *files
	)
	print_stream( $stdout, stdout_text )
	print_stream( $stderr, stderr_text )
	{ status: :completed, exit_code: status.exitstatus.to_i }
rescue Errno::ENOENT
	$stderr.puts "ERROR: RuboCop executable `rubocop` is unavailable in PATH. Install the pinned RuboCop gem before running carson audit."
	{ status: :unavailable, exit_code: nil }
rescue StandardError => e
	$stderr.puts "ERROR: RuboCop execution failed (#{e.message})"
	{ status: :runtime_error, exit_code: nil }
end

def lint_exit_code( result: )
	case result.fetch( :status )
	when :unavailable
		EXIT_BLOCK
	when :runtime_error
		EXIT_ERROR
	else
		case result.fetch( :exit_code )
		when 0
			EXIT_OK
		when 1
			EXIT_BLOCK
		else
			EXIT_ERROR
		end
	end
end

files = ARGV.map( &:to_s ).map( &:strip ).reject( &:empty? )
config_path = rubocop_config_path
unless File.file?( config_path )
	$stderr.puts "ERROR: RuboCop config not found at #{config_path}. Run `carson lint setup --source <path-or-git-url>`."
	exit EXIT_ERROR
end

result = run_rubocop( files: files )
exit lint_exit_code( result: result )
