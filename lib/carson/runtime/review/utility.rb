module Carson
	class Runtime
		module Review
			module Utility
				private
# Returns matching risk keywords using case-insensitive whole-word matching.
def matched_risk_keywords( text: )
	text_value = text.to_s
	config.review_risk_keywords.select do |keyword|
		text_value.match?( /\b#{Regexp.escape( keyword )}\b/i )
	end
end

# Disposition records always start with configured prefix.
def disposition_prefixed?( text: )
	text.to_s.lstrip.start_with?( config.review_disposition_prefix )
end

# Extracts first matching disposition token from configured acknowledgement body.
def disposition_token( text: )
	DISPOSITION_TOKENS.find { |token| text.to_s.match?( /\b#{token}\b/i ) }
end

# GitHub URL extraction for mapping disposition acknowledgements to finding URLs.
def extract_github_urls( text: )
	text.to_s.scan( %r{https://github\.com/[^\s\)\]]+} ).map { |value| value.sub( /[.,;:]+$/, "" ) }.uniq
end

# Parse RFC3339 timestamps and return nil on blank/invalid values.
def parse_time_or_nil( text: )
	value = text.to_s.strip
	return nil if value.empty?
	Time.parse( value )
rescue ArgumentError
	nil
end

# Removes duplicate finding URLs while preserving first occurrence ordering.
def deduplicate_findings_by_url( items: )
	seen = {}
	Array( items ).each_with_object( [] ) do |entry, result|
		url = entry.fetch( :url ).to_s
		next if url.empty? || seen.key?( url )
		seen[ url ] = true
		result << entry
	end
end
			end
		end
	end
end
