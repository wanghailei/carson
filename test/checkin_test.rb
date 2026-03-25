# Tests for Warehouse#checkin! — agent checks in, warehouse prepares a fresh workbench.
require_relative "test_helper"
require "open3"

class CheckinTest < Minitest::Test
	include CarsonTestSupport

	def setup
		@tmpdir = Dir.mktmpdir( "carson-checkin-test", carson_tmp_root )
		@remote_path = File.join( @tmpdir, "remote.git" )
		@repo_path = File.join( @tmpdir, "repo" )

		# Create a bare remote and clone it.
		system( "git", "init", "--bare", "-b", "main", @remote_path, out: File::NULL, err: File::NULL )
		system( "git", "clone", @remote_path, @repo_path, out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( @repo_path, "README.md" ), "# Test" )
		system( "git", "-C", @repo_path, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "initial commit", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )

		@warehouse = Carson::Warehouse.new( path: @repo_path, bureau_address: "origin" )
	end

	def teardown
		if Dir.exist?( @repo_path )
			stdout, = Open3.capture3( "git", "-C", @repo_path, "worktree", "list", "--porcelain" )
			stdout.lines.each do |line|
				next unless line.start_with?( "worktree " )
				wt_path = line.sub( "worktree ", "" ).strip
				next if wt_path == @repo_path
				Open3.capture3( "git", "-C", @repo_path, "worktree", "remove", "--force", wt_path ) rescue nil
			end
		end
		FileUtils.rm_rf( @tmpdir )
	end

	# --- checkin! ---

	def test_checkin_creates_workbench
		result = @warehouse.checkin!( name: "feature-x" )

		assert_equal "ok", result[ :status ]
		assert_equal "feature-x", result[ :name ]
		assert_equal "feature-x", result[ :branch ]
		assert Dir.exist?( result[ :path ] ), "workbench directory should exist"
	end

	def test_checkin_result_command_is_checkin
		result = @warehouse.checkin!( name: "cmd-test" )

		assert_equal "checkin", result[ :command ]
	end

	def test_checkin_error_when_name_exists
		@warehouse.checkin!( name: "duplicate" )
		result = @warehouse.checkin!( name: "duplicate" )

		assert_equal "error", result[ :status ]
		assert_includes result[ :error ], "already exists"
	end
end
