require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../lib/butler"

module ButlerTestSupport
	def butler_tmp_root
		candidate = File.join( Dir.home, ".cache", "butler-test" )
		FileUtils.mkdir_p( candidate )
		candidate
	rescue StandardError
		"/tmp"
	end

	def build_runtime
		repo_root = Dir.mktmpdir( "butler-runtime-test", butler_tmp_root )
		out = StringIO.new
		err = StringIO.new
		runtime = Butler::Runtime.new( repo_root: repo_root, tool_root: repo_root, out: out, err: err )
		[ runtime, repo_root ]
	end

	def destroy_runtime_repo( repo_root: )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end
end
