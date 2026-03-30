# Tests for Carson::Parcel#empty? — does the parcel carry anything?
require "minitest/autorun"
require_relative "../../lib/carson/parcel"

class ParcelEmptyTest < Minitest::Test
	def test_empty_when_head_equals_origin
		parcel = Carson::Parcel.new( label: "feature/noop", head: "abc123", origin: "abc123" )
		assert parcel.empty?
	end

	def test_not_empty_when_head_differs_from_origin
		parcel = Carson::Parcel.new( label: "feature/work", head: "def456", origin: "abc123" )
		refute parcel.empty?
	end

	def test_not_empty_when_origin_not_set
		parcel = Carson::Parcel.new( label: "feature/unknown", head: "abc123" )
		refute parcel.empty?
	end

	def test_origin_defaults_to_nil
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_nil parcel.origin
	end

	def test_knows_its_origin
		parcel = Carson::Parcel.new( label: "feature/login", head: "def456", origin: "abc123" )
		assert_equal "abc123", parcel.origin
	end
end
