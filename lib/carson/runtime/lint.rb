require "fileutils"
require "open3"
require "tmpdir"

module Carson
	class Runtime
		module Lint
			# Prepares canonical lint policy files under ~/AI/CODING from an explicit source.
			def lint_setup!( source:, ref: "main", force: false )
				print_header "Lint Setup"
				source_text = source.to_s.strip
				if source_text.empty?
					puts_line "ERROR: lint setup requires --source <path-or-git-url>."
					return EXIT_ERROR
				end

				ref_text = ref.to_s.strip
				ref_text = "main" if ref_text.empty?
				source_dir, cleanup = lint_setup_source_directory( source: source_text, ref: ref_text )
				begin
					source_coding_dir = File.join( source_dir, "CODING" )
					unless Dir.exist?( source_coding_dir )
						puts_line "ERROR: source CODING directory not found at #{source_coding_dir}."
						return EXIT_ERROR
					end
					target_coding_dir = ai_coding_dir
					copy_result = copy_lint_coding_tree(
						source_coding_dir: source_coding_dir,
						target_coding_dir: target_coding_dir,
						force: force
					)
					puts_line "lint_setup_source: #{source_text}"
					puts_line "lint_setup_ref: #{ref_text}" if lint_source_git_url?( source: source_text )
					puts_line "lint_setup_target: #{target_coding_dir}"
					puts_line "lint_setup_created: #{copy_result.fetch( :created )}"
					puts_line "lint_setup_updated: #{copy_result.fetch( :updated )}"
					puts_line "lint_setup_skipped: #{copy_result.fetch( :skipped )}"

					missing_policy = missing_lint_policy_files
					if missing_policy.empty?
						puts_line "OK: lint policy setup is complete."
						return EXIT_OK
					end

					missing_policy.each do |entry|
						puts_line "missing_lint_policy_file: language=#{entry.fetch( :language )} path=#{entry.fetch( :path )}"
					end
					puts_line "ACTION: update source CODING policy files, rerun carson lint setup, then rerun carson audit."
					EXIT_ERROR
				ensure
					cleanup&.call
				end
			rescue StandardError => e
				puts_line "ERROR: lint setup failed (#{e.message})"
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
					path = File.join( home, ".cache", "carson" )
					return path if FileUtils.mkdir_p( path )
				end
				"/tmp/carson"
			rescue StandardError
				"/tmp/carson"
			end

			def ai_coding_dir
				home = ENV.fetch( "HOME", "" ).to_s.strip
				raise "HOME must be an absolute path for lint setup" unless home.start_with?( "/" )

				File.join( home, "AI", "CODING" )
			end

			def copy_lint_coding_tree( source_coding_dir:, target_coding_dir:, force: )
				FileUtils.mkdir_p( target_coding_dir )
				created = 0
				updated = 0
				skipped = 0
				Dir.glob( "**/*", File::FNM_DOTMATCH, base: source_coding_dir ).sort.each do |relative|
					next if [ ".", ".." ].include?( relative )
					source_path = File.join( source_coding_dir, relative )
					target_path = File.join( target_coding_dir, relative )
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

			def missing_lint_policy_files
				config.lint_languages.each_with_object( [] ) do |( language, entry ), missing|
					next unless entry.fetch( :enabled )

					entry.fetch( :config_files ).each do |path|
						missing << { language: language, path: path } unless File.file?( path )
					end
				end
			end
		end

		include Lint
	end
end
