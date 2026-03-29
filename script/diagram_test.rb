# Tests for the Mermaid class diagram generator.
require "tempfile"
require "minitest/autorun"
require_relative "diagram"

class DiagramTest < Minitest::Test
	def test_parse_extracts_class_and_methods
		source = <<~RUBY
			module Carson
				class Parcel
					attr_reader :label, :head

					def on_main?( main_label )
						label == main_label
					end

				private

					def internal
					end
				end
			end
		RUBY

		file = Tempfile.new( [ "parcel", ".rb" ] )
		file.write( source )
		file.close

		descriptors = Carson::Diagram.parse_file( file.path )
		assert_equal 1, descriptors.size

		parcel = descriptors.first
		assert_equal "Parcel", parcel[ :name ]
		assert_includes parcel[ :attributes ], "label"
		assert_includes parcel[ :attributes ], "head"
		assert_equal 1, parcel[ :methods ].size
		assert_equal "on_main?", parcel[ :methods ].first[ :name ]
	ensure
		file&.unlink
	end

	def test_generate_produces_valid_mermaid
		root = File.expand_path( "..", __dir__ )
		output = Carson::Diagram.run( root: root )

		assert output.include?( "classDiagram" )
		assert output.include?( "class Warehouse" )
		assert output.include?( "class Vault" )
		assert output.include?( "class Parcel" )
		assert output.include?( "accept!" )
		assert output.include?( "Warehouse *-- Vault : owns" )
	end
end
