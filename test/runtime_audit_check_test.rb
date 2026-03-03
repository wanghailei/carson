require_relative "test_helper"

class RuntimeAuditCheckTest < Minitest::Test
	include CarsonTestSupport

	# Build a minimal runtime pointing at a temp dir.
	def build_audit_runtime
		Dir.mktmpdir( "carson-audit-check-test", carson_tmp_root ) do |tmp_dir|
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: tmp_dir,
				tool_root: File.expand_path( "..", __dir__ ),
				out: out,
				err: err
			)
			yield runtime
		end
	end

	def test_check_entry_failing_returns_false_for_pass
		build_audit_runtime do |rt|
			refute rt.send( :check_entry_failing?, entry: { "bucket" => "pass" } )
		end
	end

	def test_check_entry_failing_returns_false_for_pending
		build_audit_runtime do |rt|
			refute rt.send( :check_entry_failing?, entry: { "bucket" => "pending" } )
		end
	end

	def test_check_entry_failing_returns_true_for_fail
		build_audit_runtime do |rt|
			assert rt.send( :check_entry_failing?, entry: { "bucket" => "fail" } )
		end
	end

	def test_check_entry_failing_returns_true_for_cancel
		build_audit_runtime do |rt|
			assert rt.send( :check_entry_failing?, entry: { "bucket" => "cancel" } )
		end
	end

	def test_check_entry_failing_returns_true_for_error
		build_audit_runtime do |rt|
			assert rt.send( :check_entry_failing?, entry: { "bucket" => "error" } )
		end
	end

	def test_check_entry_failing_returns_true_for_empty_bucket
		build_audit_runtime do |rt|
			assert rt.send( :check_entry_failing?, entry: { "bucket" => "" } )
		end
	end

	# Builds a runtime inside a real git repo with no commits (HEAD does not exist).
	def build_no_head_runtime
		Dir.mktmpdir( "carson-audit-no-head-test", carson_tmp_root ) do |tmp_dir|
			system( "git", "init", tmp_dir, out: File::NULL, err: File::NULL )
			out = StringIO.new
			err = StringIO.new
			runtime = Carson::Runtime.new(
				repo_root: tmp_dir,
				tool_root: tmp_dir,
				out: out,
				err: err
			)
			yield runtime, out
		end
	end

	def test_audit_returns_ok_when_head_does_not_exist
		build_no_head_runtime do |rt, out|
			status = rt.audit!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert_match( /No commits yet/, out.string )
		end
	end

	def test_check_returns_ok_when_head_does_not_exist
		build_no_head_runtime do |rt, out|
			status = rt.check!
			assert_equal Carson::Runtime::EXIT_OK, status
			assert_match( /no commits yet/, out.string )
		end
	end
end
