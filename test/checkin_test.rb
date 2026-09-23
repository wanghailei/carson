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

	def test_checkin_error_when_active_workbench_has_same_name
		# Create a workbench with unique work — not absorbed into main.
		@warehouse.build_workbench!( name: "active-work" )
		wb = @warehouse.workbench_named( "active-work" )
		File.write( File.join( wb.path, "work.txt" ), "in progress" )
		system( "git", "-C", wb.path, "add", ".", out: File::NULL, err: File::NULL )
		system( "git", "-C", wb.path, "commit", "-m", "wip", out: File::NULL, err: File::NULL )

		# Checkin with the same name — should error because the workbench has active work.
		result = @warehouse.checkin!( name: "active-work" )

		assert_equal "error", result[ :status ]
		assert_includes result[ :error ], "already exists"
	end

	# --- sweep is the warehouse's autonomous housekeeping ---

	def test_sweep_removes_delivered_workbenches
		# Build a workbench and simulate a delivered parcel:
		# merge its branch into main so absorbed? returns true.
		@warehouse.build_workbench!( name: "old-task" )
		old_wb = @warehouse.workbench_named( "old-task" )
		old_path = old_wb.path

		# Simulate delivery: merge the branch into main.
		system( "git", "-C", @repo_path, "merge", "old-task", out: File::NULL, err: File::NULL )

		# Sweep is autonomous — not tied to checkin.
		@warehouse.sweep!

		refute Dir.exist?( old_path ), "delivered workbench should be swept"
	end

	def test_checkin_branches_from_local_main_not_remote
		# Local main is ahead of origin — workbench must include the local-only commit.
		File.write( File.join( @repo_path, "local.txt" ), "local work" )
		system( "git", "-C", @repo_path, "add", "local.txt", out: File::NULL, err: File::NULL )
		system( "git", "-C", @repo_path, "commit", "-m", "local only", out: File::NULL, err: File::NULL )

		result = @warehouse.checkin!( name: "local-based" )

		assert_equal "ok", result[ :status ]
		assert File.exist?( File.join( result[ :path ], "local.txt" ) ),
			"workbench should be based on local main, not origin/main"
	end

	def test_checkin_does_not_sweep_sealed_workbenches
		# Build and seal a workbench — parcel still in flight.
		@warehouse.build_workbench!( name: "in-flight" )
		wb = @warehouse.workbench_named( "in-flight" )

		seal_wh = Carson::Warehouse.new( path: wb.path )
		seal_wh.seal!( tracking: 77 )
		@seal_markers_to_clean = [ seal_wh.send( :delivering_marker_path ) ]

		# Merge the branch into main (would normally be absorbed).
		system( "git", "-C", @repo_path, "merge", "in-flight", out: File::NULL, err: File::NULL )

		# Sweep should NOT remove sealed workbenches.
		@warehouse.sweep!

		assert Dir.exist?( wb.path ), "sealed workbench should not be swept"

		# Clean up seal.
		@seal_markers_to_clean.each { |m| File.delete( m ) if File.exist?( m ) }
	end

	# --- Agent directory: the calling harness's workbench location ---

	def test_checkin_defaults_to_claude_worktrees
		result = @warehouse.checkin!( name: "default-dir" )

		assert result[ :path ].end_with?( File.join( ".claude", "worktrees", "default-dir" ) ),
			"absent harness markers, the workbench belongs under .claude/worktrees — got #{result[ :path ]}"
		assert Dir.exist?( result[ :path ] )
	end

	def test_checkin_uses_pi_worktrees_when_pi_env_present
		with_env( "PI_CODING_AGENT" => "1" ) do
			result = @warehouse.checkin!( name: "pi-dir" )

			assert result[ :path ].end_with?( File.join( ".pi", "worktrees", "pi-dir" ) ),
				"a Pi session's workbench belongs under .pi/worktrees — got #{result[ :path ]}"
			assert Dir.exist?( result[ :path ] )
		end
	end

	def test_checkin_agent_dir_override_wins_over_detection
		with_env( "PI_CODING_AGENT" => "1", "CARSON_AGENT_DIR" => ".custom" ) do
			result = @warehouse.checkin!( name: "custom-dir" )

			assert result[ :path ].end_with?( File.join( ".custom", "worktrees", "custom-dir" ) ),
				"CARSON_AGENT_DIR overrides detection — got #{result[ :path ]}"
			assert Dir.exist?( result[ :path ] )
		end
	end

	def test_checkin_excludes_the_agent_dir_from_git_status
		with_env( "PI_CODING_AGENT" => "1" ) do
			@warehouse.checkin!( name: "pi-exclude" )
		end

		exclude = File.read( File.join( @repo_path, ".git", "info", "exclude" ) )
		assert_includes exclude.lines.map( &:strip ), ".pi/"
	end

	def test_workbench_named_resolves_pi_workbench_by_bare_name
		with_env( "PI_CODING_AGENT" => "1" ) do
			@warehouse.build_workbench!( name: "pi-named" )
		end
		expected = File.join( ".pi", "worktrees", "pi-named" )

		# Resolves from the same harness…
		with_env( "PI_CODING_AGENT" => "1" ) do
			assert @warehouse.workbench_named( "pi-named" )&.path&.end_with?( expected ),
				"workbench_named should find the current harness's workbench by bare name"
		end
		# …and from another harness via the basename fallback.
		assert @warehouse.workbench_named( "pi-named" )&.path&.end_with?( expected ),
			"workbench_named should find another harness's workbench by bare name"
	end
end
