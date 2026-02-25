require "open3"

files = ARGV.select { |path| File.file?( path ) }
exit 0 if files.empty?

failed = false
files.each do |path|
	_stdout, stderr, status = Open3.capture3( "ruby", "-c", path )
	next if status.success?

	failed = true
	warn "#{path}: #{stderr}".strip
end

exit( failed ? 1 : 0 )
