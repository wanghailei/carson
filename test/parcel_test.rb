# Tests for Carson::Parcel — the committed changes being delivered.
require "minitest/autorun"
require_relative "../lib/carson/parcel"

class ParcelTest < Minitest::Test
	def test_knows_its_label
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_equal "feature/login", parcel.label
	end

	def test_knows_its_head
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_equal "abc123", parcel.head
	end

	def test_knows_its_shelf
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123", shelf: "/tmp/worktree" )
		assert_equal "/tmp/worktree", parcel.shelf
	end

	def test_shelf_defaults_to_nil
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		assert_nil parcel.shelf
	end

	def test_on_main_when_label_matches
		parcel = Carson::Parcel.new( label: "main", head: "abc123" )
		assert parcel.on_main?( "main" )
	end

	def test_not_on_main_when_label_differs
		parcel = Carson::Parcel.new( label: "feature/login", head: "abc123" )
		refute parcel.on_main?( "main" )
	end

	def test_on_main_respects_custom_main_label
		parcel = Carson::Parcel.new( label: "master", head: "abc123" )
		assert parcel.on_main?( "master" )
		refute parcel.on_main?( "main" )
	end
end
