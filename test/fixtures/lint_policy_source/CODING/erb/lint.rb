require "erb"

files = ARGV.select { |path| File.file?( path ) }
exit 0 if files.empty?

failed = false
files.each do |path|
	begin
		ERB.new( File.read( path ) )
	rescue StandardError => e
		failed = true
		warn "#{path}: #{e.message}"
	end
end

exit( failed ? 1 : 0 )
