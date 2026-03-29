#!/usr/bin/env ruby
# Generates a Mermaid class diagram from the Carson source code.
#
# Usage:
#   ruby script/diagram.rb                    # print to stdout
#   ruby script/diagram.rb > docs/class-diagram.mmd  # write to file
#
# Parses lib/carson/**/*.rb and lib/cli.rb. Extracts classes, modules,
# public methods, attributes, and relationships. Skips runtime/ (being
# dissolved) and adapters/ (infrastructure, not domain).

module Carson
	module Diagram
	module_function

		# Files to parse — domain objects only.
		SOURCES = -> ( root ) {
			files = Dir.glob( File.join( root, "lib", "carson", "*.rb" ) )
			files += Dir.glob( File.join( root, "lib", "carson", "warehouse", "*.rb" ) )
			files << File.join( root, "lib", "cli.rb" )
			files.select { |f| File.exist?( f ) }
				.reject { |f| f.include?( "/runtime" ) || f.include?( "/adapters" ) }
		}

		# Stereotypes for known classes.
		STEREOTYPES = {
			"CLI" => "company",
			"Worktree" => "passive",
			"Parcel" => "value",
			"Waybill" => "value",
			"Delivery" => "record",
			"Revision" => "value",
			"Seal" => "module",
			"Bureau" => "module",
			"Workbench" => "module",
		}.freeze

		# Parse a single Ruby file. Returns an array of class/module descriptors.
		# Uses indentation-based detection to avoid the `end` tracking problem
		# where method `end`s corrupt class/module depth counting.
		def parse_file( path )
			source = File.read( path )
			descriptors = []
			current = nil
			visibility = :public
			in_method = false

			source.each_line do |line|
				stripped = line.strip
				next if stripped.empty? || stripped.start_with?( "#" )

				# Track method boundaries — skip `end` inside methods.
				if stripped.match?( /^def\s/ )
					in_method = true
				elsif stripped == "end" && in_method
					in_method = false
					next
				elsif stripped == "end"
					# Class or module end — reset current if we're closing a class.
					if current
						current = nil
						visibility = :public
					end
					next
				end

				# Skip lines inside method bodies.
				next if in_method && !stripped.match?( /^def\s/ )

				# Class definition — the one we want to describe.
				if stripped.match?( /^class\s+\w+/ )
					match = stripped.match( /^class\s+(\w+)(?:\s*<\s*(\S+))?/ )
					name = match[ 1 ]
					parent = match[ 2 ]

					current = {
						name: name,
						full_name: name,
						parent: parent,
						methods: [],
						class_methods: [],
						attributes: [],
						includes: [],
						file: path
					}
					visibility = :public
					descriptors << current
					next
				end

				next unless current

				# Visibility switch.
				case stripped
				when "private", "protected"
					visibility = stripped.to_sym
					next
				when "public"
					visibility = :public
					next
				end

				# Include.
				if stripped.match?( /^include\s+\w+/ )
					mod = stripped.match( /^include\s+(\w+)/ )[ 1 ]
					current[ :includes ] << mod
					next
				end

				# Attributes.
				if stripped.match?( /^attr_(reader|accessor)\s+/ ) && visibility == :public
					attrs = stripped.scan( /:(\w+)/ ).flatten
					current[ :attributes ].concat( attrs )
					next
				end

				# Class method.
				if stripped.match?( /^def\s+self\.(\w+[!?=]?)/ )
					method_name = stripped.match( /^def\s+self\.(\w+[!?=]?)/ )[ 1 ]
					current[ :class_methods ] << method_name
					in_method = true
					next
				end

				# Instance method.
				if stripped.match?( /^def\s+(?!self\.)(\w+[!?=]?)/ ) && visibility == :public
					method_name = stripped.match( /^def\s+(\w+[!?=]?)/ )[ 1 ]
					params = ""
					if stripped.include?( "(" )
						raw = stripped.match( /\(([^)]*)\)/ )&.[]( 1 ).to_s.strip
						params = raw.split( "," ).map { |p|
							p.strip.sub( /\s*[:=].*/, "" ).sub( /^\*\*/, "" ).sub( /^\*/, "" )
						}.reject( &:empty? ).join( ", " )
					end
					current[ :methods ] << { name: method_name, params: params }
					in_method = true
					next
				end
			end

			descriptors
		end

		# Generate the Mermaid diagram from parsed descriptors.
		def generate( descriptors )
			lines = []
			lines << "---"
			lines << "title: Carson — Class Diagram"
			lines << "---"
			lines << "classDiagram"
			lines << "\tdirection TB"
			lines << ""

			descriptors.each do |desc|
				lines << "\tclass #{desc[ :name ]} {"
				stereotype = STEREOTYPES[ desc[ :name ] ]
				lines << "\t\t<<#{stereotype}>>" if stereotype
				desc[ :attributes ].each do |attr|
					lines << "\t\t+#{attr}"
				end
				desc[ :class_methods ].each do |m|
					lines << "\t\t+#{m}()$"
				end
				desc[ :methods ].each do |m|
					sig = m[ :params ].empty? ? "#{m[ :name ]}()" : "#{m[ :name ]}( #{m[ :params ]} )"
					lines << "\t\t+#{sig}"
				end
				lines << "\t}"
				lines << ""
			end

			# Relationships from includes.
			lines << "\t%% === Relationships ==="
			lines << ""
			descriptors.each do |desc|
				desc[ :includes ].each do |mod|
					lines << "\t#{desc[ :name ]} ..|> #{mod} : includes"
				end
			end

			# Known ownership and collaboration.
			lines << "\tWarehouse *-- Vault : owns"
			lines << "\tWarehouse --> Worktree : manages"
			lines << "\tWarehouse --> Parcel : packs"
			lines << "\tCourier --> Warehouse : uses"
			lines << "\tCourier --> Parcel : delivers"
			lines << "\tCourier --> Waybill : reads"
			lines << "\tCourier --> Ledger : records to"
			lines << "\tCLI --> Warehouse : builds"
			lines << "\tCLI --> Courier : dispatches"
			lines << "\tVault --> Parcel : accepts"
			lines << ""

			lines.join( "\n" ) + "\n"
		end

		# Merge descriptors with the same class name into one.
		# Modules that reopen a class (Bureau, Seal, Workbench) produce
		# separate descriptors that belong on the same class.
		def merge_descriptors( descriptors )
			merged = {}
			descriptors.each do |desc|
				name = desc[ :name ]
				if merged[ name ]
					merged[ name ][ :methods ].concat( desc[ :methods ] )
					merged[ name ][ :class_methods ].concat( desc[ :class_methods ] )
					merged[ name ][ :attributes ].concat( desc[ :attributes ] )
					merged[ name ][ :includes ].concat( desc[ :includes ] )
				else
					merged[ name ] = desc.dup
					merged[ name ][ :methods ] = desc[ :methods ].dup
					merged[ name ][ :class_methods ] = desc[ :class_methods ].dup
					merged[ name ][ :attributes ] = desc[ :attributes ].dup
					merged[ name ][ :includes ] = desc[ :includes ].dup
				end
			end

			# Deduplicate and remove initialize from public methods.
			merged.each_value do |desc|
				desc[ :methods ].uniq! { |m| m[ :name ] }
				desc[ :methods ].reject! { |m| m[ :name ] == "initialize" }
				desc[ :class_methods ].uniq!
				desc[ :attributes ].uniq!
				desc[ :includes ].uniq!
			end

			merged.values
		end

		# Main entry point.
		def run( root: )
			files = SOURCES.call( root )
			raw = files.flat_map { |f| parse_file( f ) }
			descriptors = merge_descriptors( raw )
			generate( descriptors )
		end
	end
end

if __FILE__ == $0
	root = File.expand_path( "..", __dir__ )
	print Carson::Diagram.run( root: root )
end
