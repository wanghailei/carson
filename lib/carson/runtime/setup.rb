require "set"
require "uri"

module Carson
	class Runtime
		module Setup
			WELL_KNOWN_REMOTES = %w[origin github upstream].freeze

			def setup!
				puts_verbose ""
				puts_verbose "[Setup]"

				unless inside_git_work_tree?
					puts_line "WARN: not a git repository. Skipping remote and branch detection."
					return write_setup_config( choices: {} )
				end

				if self.in.respond_to?( :tty? ) && self.in.tty?
					interactive_setup!
				else
					silent_setup!
				end
			end

		private

			def interactive_setup!
				choices = {}

				remote_choice = prompt_remote
				choices[ "git.remote" ] = remote_choice unless remote_choice.nil?

				branch_choice = prompt_main_branch
				choices[ "git.main_branch" ] = branch_choice unless branch_choice.nil?

				workflow_choice = prompt_workflow_style
				choices[ "workflow.style" ] = workflow_choice unless workflow_choice.nil?

				merge_choice = prompt_merge_method
				choices[ "govern.merge.method" ] = merge_choice unless merge_choice.nil?


				write_setup_config( choices: choices )
			end

			def silent_setup!
				detected = detect_git_remote
				choices = {}
				if detected && detected != config.git_remote
					choices[ "git.remote" ] = detected
					puts_verbose "detected_remote: #{detected}"
				elsif detected
					puts_verbose "detected_remote: #{detected}"
				else
					puts_verbose "detected_remote: none"
				end

				remotes = list_git_remotes
				duplicates = duplicate_remote_groups( remotes: remotes )
				unless duplicates.empty?
					duplicates.each_value do |group|
						names = group.map { it.fetch( :name ) }.join( " and " )
						puts_verbose "duplicate_remotes: #{names} share the same URL"
					end
				end

				branch = detect_main_branch
				if branch && branch != config.main_branch
					choices[ "git.main_branch" ] = branch
					puts_verbose "detected_main_branch: #{branch}"
				elsif branch
					puts_verbose "detected_main_branch: #{branch}"
				end

				write_setup_config( choices: choices )
			end

			def prompt_remote
				remotes = list_git_remotes
				if remotes.empty?
					puts_line "No remotes found. Carson will operate in local-only mode."
					return nil
				end

				duplicates = duplicate_remote_groups( remotes: remotes )
				duplicate_names = duplicates.values.flatten.map { it.fetch( :name ) }.to_set
				unless duplicates.empty?
					duplicates.each_value do |group|
						names = group.map { it.fetch( :name ) }.join( " and " )
						puts_line "Remotes #{names} share the same URL. Consider removing the duplicate."
					end
				end

				puts_line ""
				puts_line "Git remote"
				options = build_remote_options( remotes: remotes, duplicate_names: duplicate_names )
				options << { label: "Other (enter name)", value: :other }

				default_index = 0
				choice = prompt_choice( options: options, default: default_index )

				if choice == :other
					prompt_custom_value( label: "Remote name" )
				else
					choice
				end
			end

			def prompt_main_branch
				puts_line ""
				puts_line "Main branch"
				options = build_main_branch_options
				options << { label: "Other (enter name)", value: :other }

				default_index = 0
				choice = prompt_choice( options: options, default: default_index )

				if choice == :other
					prompt_custom_value( label: "Branch name" )
				else
					choice
				end
			end

			def prompt_workflow_style
				puts_line ""
				puts_line "Workflow style"
				options = [
					{ label: "branch — enforce PR-only merges (default)", value: "branch" },
					{ label: "trunk — commit directly to main", value: "trunk" }
				]
				prompt_choice( options: options, default: 0 )
			end

			def prompt_merge_method
				puts_line ""
				puts_line "Merge method"
				options = [
					{ label: "squash — one commit per PR (recommended)", value: "squash" },
					{ label: "rebase — linear history, individual commits", value: "rebase" },
					{ label: "merge — merge commits", value: "merge" }
				]
				prompt_choice( options: options, default: 0 )
			end

			def prompt_choice( options:, default: )
				options.each_with_index do |option, index|
					puts_line "  #{index + 1}) #{option.fetch( :label )}"
				end
				out.print "#{BADGE} Choice [#{default + 1}]: "
				out.flush
				raw = self.in.gets
				return options[ default ].fetch( :value ) if raw.nil?

				input = raw.to_s.strip
				return options[ default ].fetch( :value ) if input.empty?

				index = Integer( input ) - 1
				return options[ default ].fetch( :value ) if index < 0 || index >= options.length

				options[ index ].fetch( :value )
			rescue ArgumentError
				options[ default ].fetch( :value )
			end

			def prompt_custom_value( label: )
				out.print "#{BADGE} #{label}: "
				out.flush
				raw = self.in.gets
				return nil if raw.nil?

				value = raw.to_s.strip
				value.empty? ? nil : value
			end

			def build_remote_options( remotes:, duplicate_names: Set.new )
				sorted = sort_remotes( remotes: remotes )
				sorted.map do |entry|
					name = entry.fetch( :name )
					url = entry.fetch( :url )
					tag = duplicate_names.include?( name ) ? " [duplicate]" : ""
					{ label: "#{name} (#{url})#{tag}", value: name }
				end
			end

			def sort_remotes( remotes: )
				well_known = []
				others = []
				remotes.each do |entry|
					if WELL_KNOWN_REMOTES.include?( entry.fetch( :name ) )
						well_known << entry
					else
						others << entry
					end
				end
				well_known.sort_by { |e| WELL_KNOWN_REMOTES.index( e.fetch( :name ) ) || 999 } + others.sort_by { |e| e.fetch( :name ) }
			end

			# Normalises a remote URL so SSH and HTTPS variants of the same host/path compare equal.
			# Strips trailing .git, lowercases, converts git@host:path to https://host/path.
			def normalise_remote_url( url: )
				text = url.to_s.strip
				return "" if text.empty?

				# Convert SSH shorthand (git@host:owner/repo) to HTTPS form.
				if text.match?( /\A[\w.-]+@[\w.-]+:/ )
					text = text.sub( /\A[\w.-]+@([\w.-]+):/, 'https://\1/' )
				end

				text = text.delete_suffix( ".git" )
				text = text.chomp( "/" )
				text.downcase
			end

			# Groups remotes that share the same normalised URL. Returns a hash of
			# normalised_url => [remote entries] for groups with more than one member.
			def duplicate_remote_groups( remotes: )
				by_url = {}
				remotes.each do |entry|
					key = normalise_remote_url( url: entry.fetch( :url ) )
					next if key.empty?

					( by_url[ key ] ||= [] ) << entry
				end
				by_url.select { |_url, entries| entries.length > 1 }
			end

			def build_main_branch_options
				options = []
				main_exists = branch_exists_locally_or_remote?( branch: "main" )
				master_exists = branch_exists_locally_or_remote?( branch: "master" )

				if main_exists
					options << { label: "main", value: "main" }
					options << { label: "master", value: "master" } if master_exists
				elsif master_exists
					options << { label: "master", value: "master" }
					options << { label: "main", value: "main" }
				else
					options << { label: "main", value: "main" }
					options << { label: "master", value: "master" }
				end
				options
			end

			def branch_exists_locally_or_remote?( branch: )
				return true if branch_exists?( branch_name: branch )

				remote = config.git_remote
				_, _, success, = git_run( "rev-parse", "--verify", "#{remote}/#{branch}" )
				success
			end

			def list_git_remotes
				stdout_text, _, success, = git_run( "remote", "-v" )
				return [] unless success

				remotes = {}
				stdout_text.lines.each do |line|
					parts = line.strip.split( /\s+/ )
					next if parts.length < 2

					name = parts[ 0 ]
					url = parts[ 1 ]
					remotes[ name ] ||= url
				end
				remotes.map { |name, url| { name: name, url: url } }
			end

			def detect_git_remote
				remotes = list_git_remotes
				remote_names = remotes.map { |entry| entry.fetch( :name ) }
				return nil if remote_names.empty?

				return config.git_remote if remote_names.include?( config.git_remote )
				return remote_names.first if remote_names.length == 1

				candidate = WELL_KNOWN_REMOTES.find { |name| remote_names.include?( name ) }
				return candidate unless candidate.nil?

				remote_names.first
			end

			def detect_main_branch
				return "main" if branch_exists_locally_or_remote?( branch: "main" )
				return "master" if branch_exists_locally_or_remote?( branch: "master" )

				nil
			end

			def write_setup_config( choices: )
				config_data = build_config_data_from_choices( choices: choices )

				config_path = Config.global_config_path( repo_root: repo_root )
				if config_path.empty?
					puts_line "WARN: unable to determine config path; skipping config write."
					return EXIT_OK
				end

				existing_data = load_existing_config( path: config_path )
				merged = Config.deep_merge( base: existing_data, overlay: config_data )

				FileUtils.mkdir_p( File.dirname( config_path ) )
				File.write( config_path, JSON.pretty_generate( merged ) )
				puts_line ""
				puts_line "Config saved to #{config_path}"

				reload_config_after_setup!
				EXIT_OK
			end

			def build_config_data_from_choices( choices: )
				data = {}
				choices.each do |key, value|
					next if value.nil?

					parts = key.split( "." )
					current = data
					parts[ 0..-2 ].each do |part|
						current[ part ] ||= {}
						current = current[ part ]
					end
					current[ parts.last ] = value
				end
				data
			end

			def load_existing_config( path: )
				return {} unless File.file?( path )

				JSON.parse( File.read( path ) )
			rescue JSON::ParserError
				{}
			end

			def reload_config_after_setup!
				@config = Config.load( repo_root: repo_root )
			end

			def global_config_exists?
				path = Config.global_config_path( repo_root: repo_root )
				!path.empty? && File.file?( path )
			end

			# After onboard succeeds, offer to register the repo for portfolio governance.
			def prompt_govern_registration!
				expanded = File.expand_path( repo_root )
				if config.govern_repos.include?( expanded )
					puts_verbose "govern_registration: already registered #{expanded}"
					return
				end

				puts_line ""
				puts_line "Portfolio governance"
				puts_line "  Register this repo so carson refresh --all and carson govern include it?"
				accepted = prompt_yes_no( default: true )
				if accepted
					append_govern_repo!( repo_path: expanded )
					puts_line "Registered. Run carson refresh --all to keep all repos in sync."
				else
					puts_line "Skipped. Run carson onboard here again to register later."
				end
			end

			# Reusable Y/n prompt following existing prompt_choice conventions.
			def prompt_yes_no( default: true )
				hint = default ? "Y/n" : "y/N"
				out.print "#{BADGE} [#{hint}]: "
				out.flush
				raw = self.in.gets
				return default if raw.nil?

				input = raw.to_s.strip.downcase
				return default if input.empty?

				input.start_with?( "y" )
			end

			# Appends a repo path to govern.repos without replacing the array via deep_merge.
			def append_govern_repo!( repo_path: )
				config_path = Config.global_config_path( repo_root: repo_root )
				return if config_path.empty?

				existing_data = load_existing_config( path: config_path )
				existing_data[ "govern" ] ||= {}
				repos = Array( existing_data[ "govern" ][ "repos" ] )
				repos << repo_path
				existing_data[ "govern" ][ "repos" ] = repos.uniq

				FileUtils.mkdir_p( File.dirname( config_path ) )
				File.write( config_path, JSON.pretty_generate( existing_data ) )
				reload_config_after_setup!
			end
		end

		include Setup
	end
end
