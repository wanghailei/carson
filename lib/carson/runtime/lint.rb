require "fileutils"
require "open3"
require "tmpdir"

module Carson
	class Runtime
		module Lint
			# Distributes lint policy files from a central source into the governed repository.
			# Target: <repo>/.github/linters/ (MegaLinter auto-discovers here).
			def lint_setup!( source:, ref: "main", force: false, **_ )
				puts_verbose ""
				puts_verbose "[Lint Policy]"
				source_text = source.to_s.strip
				if source_text.empty?
					puts_line "ERROR: lint policy requires --source <path-or-git-url>."
					return EXIT_ERROR
				end

				ref_text = ref.to_s.strip
				ref_text = "main" if ref_text.empty?
				source_dir, cleanup = lint_setup_source_directory( source: source_text, ref: ref_text )
				begin
					target_dir = repo_linters_dir
					copy_result = copy_lint_policy_files(
						source_dir: source_dir,
						target_dir: target_dir,
						force: force
					)
					puts_verbose "lint_policy_source: #{source_text}"
					puts_verbose "lint_policy_ref: #{ref_text}" if lint_source_git_url?( source: source_text )
					puts_verbose "lint_policy_target: #{target_dir}"
					puts_verbose "lint_policy_created: #{copy_result.fetch( :created )}"
					puts_verbose "lint_policy_updated: #{copy_result.fetch( :updated )}"
					puts_verbose "lint_policy_skipped: #{copy_result.fetch( :skipped )}"

					puts_line "OK: lint policy synced to .github/linters/ (#{copy_result.fetch( :created )} created, #{copy_result.fetch( :updated )} updated)."
					EXIT_OK
				ensure
					cleanup&.call
				end
			rescue StandardError => e
				puts_line "ERROR: lint policy failed (#{e.message})"
				EXIT_ERROR
			end

		private
			def lint_setup_source_directory( source:, ref: )
				if lint_source_git_url?( source: source )
					return lint_setup_clone_source( source: source, ref: ref )
				end

				expanded_source = File.expand_path( source )
				raise "source path does not exist: #{expanded_source}" unless Dir.exist?( expanded_source )
				[ expanded_source, nil ]
			end

			def lint_source_git_url?( source: )
				text = source.to_s.strip
				text.start_with?( "https://", "http://", "ssh://", "git@", "file://" )
			end

			def lint_setup_clone_source( source:, ref: )
				cache_root = cache_workspace_root
				FileUtils.mkdir_p( cache_root )
				work_dir = Dir.mktmpdir( "carson-lint-setup-", cache_root )
				checkout_dir = File.join( work_dir, "source" )
				clone_source = authenticated_lint_source( source: source )
				stdout_text, stderr_text, status = Open3.capture3(
					"git", "clone", "--depth", "1", "--branch", ref, clone_source, checkout_dir
				)
				unless status.success?
					error_text = [ stderr_text.to_s.strip, stdout_text.to_s.strip ].reject( &:empty? ).join( " | " )
					error_text = "git clone failed" if error_text.empty?
					raise "unable to clone lint source #{safe_lint_source( source: source )} (#{error_text})"
				end
				[ checkout_dir, -> { FileUtils.rm_rf( work_dir ) } ]
			end

			def authenticated_lint_source( source: )
				token = ENV.fetch( "CARSON_READ_TOKEN", "" ).to_s.strip
				return source if token.empty?

				return source unless source.start_with?( "https://github.com/", "http://github.com/", "git@github.com:" )

				if source.start_with?( "git@github.com:" )
					path = source.sub( "git@github.com:", "" )
					return "https://x-access-token:#{token}@github.com/#{path}"
				end

				source.sub( %r{\Ahttps?://github\.com/}, "https://x-access-token:#{token}@github.com/" )
			end

			def safe_lint_source( source: )
				source.to_s.gsub( %r{https://[^@]+@}, "https://***@" )
			end

			def cache_workspace_root
				home = ENV.fetch( "HOME", "" ).to_s.strip
				if home.start_with?( "/" )
					path = File.join( home, ".carson", "cache" )
					FileUtils.mkdir_p( path )
					return path
				end
				"/tmp/carson"
			rescue StandardError
				"/tmp/carson"
			end

			# Lint configs live inside the governed repository for MegaLinter.
			def repo_linters_dir
				File.join( repo_root, ".github", "linters" )
			end

			def copy_lint_policy_files( source_dir:, target_dir:, force: )
				FileUtils.mkdir_p( target_dir )
				created = 0
				updated = 0
				skipped = 0
				Dir.glob( "**/*", File::FNM_DOTMATCH, base: source_dir ).sort.each do |relative|
					next if [ ".", ".." ].include?( relative )
					next if relative.start_with?( ".git/" ) || relative == ".git"
					source_path = File.join( source_dir, relative )
					target_path = File.join( target_dir, relative )
					if File.directory?( source_path )
						FileUtils.mkdir_p( target_path )
						next
					end
					next unless File.file?( source_path )

					if File.exist?( target_path ) && !force
						skipped += 1
						next
					end
					target_exists = File.exist?( target_path )
					FileUtils.mkdir_p( File.dirname( target_path ) )
					FileUtils.cp( source_path, target_path )
					FileUtils.chmod( File.stat( source_path ).mode & 0o777, target_path )
					if target_exists
						updated += 1
					else
						created += 1
					end
				end
				{
					created: created,
					updated: updated,
					skipped: skipped
				}
			end
		end

		include Lint
	end
end
