require "fileutils"
require "minitest/autorun"
require "stringio"
require "tmpdir"

require_relative "../lib/carson"

module CarsonTestSupport
	def carson_tmp_root
		candidate = File.join( Dir.home, ".cache", "carson-test" )
		FileUtils.mkdir_p( candidate )
		candidate
	rescue StandardError
		"/tmp"
	end

	def build_runtime( tool_root: nil )
		repo_root = Dir.mktmpdir( "carson-runtime-test", carson_tmp_root )
		out = StringIO.new
		err = StringIO.new
		resolved_tool_root = tool_root.nil? ? repo_root : tool_root
		runtime = Carson::Runtime.new( repo_root: repo_root, tool_root: resolved_tool_root, out: out, err: err )
		[ runtime, repo_root ]
	end

	def destroy_runtime_repo( repo_root: )
		FileUtils.remove_entry( repo_root ) if File.directory?( repo_root )
	end

	def with_env( pairs )
		previous = {}
		pairs.each do |key, value|
			previous[ key ] = ENV.key?( key ) ? ENV.fetch( key ) : :__missing__
			ENV[ key ] = value
		end
		yield
	ensure
		pairs.each_key do |key|
			value = previous.fetch( key )
			if value == :__missing__
				ENV.delete( key )
			else
				ENV[ key ] = value
			end
		end
	end
end
