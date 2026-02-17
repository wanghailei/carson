# frozen_string_literal: true

module Butler
	version_path = File.expand_path( "../../VERSION", __dir__ )
	VERSION = File.file?( version_path ) ? File.read( version_path ).strip : "0.0.0"
end
