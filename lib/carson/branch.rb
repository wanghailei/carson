# Represents a local Git branch with identity and classification helpers.
module Carson
	class Branch
		attr_reader :name

		def initialize( name: )
			@name = name
		end

		# Returns Branch instance for the current checkout, or nil for detached HEAD.
		def self.current( runtime: )
			raw = runtime.git_capture!( "rev-parse", "--abbrev-ref", "HEAD" ).strip
			return nil if raw == "HEAD"
			new( name: raw )
		end

		# Returns true if a local branch with this name exists.
		def self.exists?( name:, runtime: )
			_, _, success, = runtime.git_run( "show-ref", "--verify", "--quiet", "refs/heads/#{name}" )
			success
		end

		# Returns branches whose upstream is gone (remote tracking branch deleted).
		def self.stale( remote_name:, runtime: )
			runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" )
				.lines.filter_map do |line|
				branch, upstream, track = line.strip.split( "\t", 3 )
				next if branch.to_s.empty? || upstream.to_s.empty?
				next unless upstream.start_with?( "#{remote_name}/" ) && track.to_s.include?( "gone" )
				new( name: branch )
			end
		end

		# Returns branches with no upstream, excluding protected and active.
		def self.orphaned( active_branch: nil, cwd_branch: nil, protected_branches: [], runtime: )
			runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads" )
				.lines.filter_map do |line|
				branch, upstream = line.strip.split( "\t", 2 )
				branch = branch.to_s.strip
				next if branch.empty?
				next unless upstream.to_s.strip.empty?
				next if protected_branches.include?( branch )
				next if branch == active_branch
				next if cwd_branch && branch == cwd_branch
				new( name: branch )
			end
		end

		# Returns branches fully merged into main.
		def self.absorbed( active_branch: nil, cwd_branch: nil, protected_branches: [], main_branch:, runtime: )
			runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" )
				.lines.filter_map do |line|
				branch, upstream, track = line.strip.split( "\t", 3 )
				branch = branch.to_s.strip
				next if branch.empty? || upstream.to_s.strip.empty?
				next if track.to_s.include?( "gone" )
				next if protected_branches.include?( branch )
				next if branch == active_branch
				next if cwd_branch && branch == cwd_branch
				next unless absorbed_into_main?( branch: branch, main_branch: main_branch, runtime: runtime )
				new( name: branch )
			end
		end

		# Checks if every change on the branch is already present on main.
		def self.absorbed_into_main?( branch:, main_branch:, runtime: )
			_, _, is_ancestor, = runtime.git_run( "merge-base", "--is-ancestor", branch, main_branch )
			return true if is_ancestor

			merge_base_text, _, mb_success, = runtime.git_run( "merge-base", main_branch, branch )
			return false unless mb_success
			merge_base = merge_base_text.to_s.strip
			return false if merge_base.empty?

			changed_text, _, changed_success, = runtime.git_run( "diff", "--name-only", merge_base, branch )
			return false unless changed_success
			changed_files = changed_text.to_s.strip.lines.map( &:strip ).reject( &:empty? )
			return true if changed_files.empty?

			_, _, identical, = runtime.git_run( "diff", "--quiet", branch, main_branch, "--", *changed_files )
			identical
		end
	end
end
