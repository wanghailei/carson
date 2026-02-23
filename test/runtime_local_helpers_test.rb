require_relative "test_helper"

class RuntimeLocalHelpersTest < Minitest::Test
	include ButlerTestSupport

	def test_normalise_porcelain_path_decodes_quoted_paths
		runtime, repo_root = build_runtime
		assert_equal "a b.txt", runtime.send( :normalise_porcelain_path, path_text: "\"a b.txt\"" )
		assert_equal "quote\"name.txt", runtime.send( :normalise_porcelain_path, path_text: "\"quote\\\"name.txt\"" )
	ensure
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_normalise_porcelain_path_leaves_plain_paths
		runtime, repo_root = build_runtime
		assert_equal "lib/foo.rb", runtime.send( :normalise_porcelain_path, path_text: "lib/foo.rb" )
		assert_equal "docs/guide.md", runtime.send( :normalise_porcelain_path, path_text: "docs/guide.md" )
	ensure
		destroy_runtime_repo( repo_root: repo_root )
	end
end
