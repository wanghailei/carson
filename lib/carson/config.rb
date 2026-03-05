require "json"

module Carson
	class ConfigError < StandardError
	end

	# Config is built-in only for outsider mode; host repositories do not carry Carson config files.
	class Config
		attr_accessor :git_remote
		attr_reader :main_branch, :protected_branches, :hooks_path, :managed_hooks,
			:template_managed_files, :template_canonical,
			:review_wait_seconds, :review_poll_seconds, :review_max_polls, :review_sweep_window_days,
			:review_sweep_states, :review_disposition, :review_risk_keywords,
			:review_tracking_issue_title, :review_tracking_issue_label, :review_bot_usernames,
			:audit_advisory_check_names,
			:workflow_style,
			:govern_repos, :govern_auto_merge, :govern_merge_method,
			:govern_agent_provider, :govern_dispatch_state_path,
			:govern_check_wait

		def self.load( repo_root: )
			base_data = default_data
			merged_data = deep_merge( base: base_data, overlay: load_global_config_data( repo_root: repo_root ) )
			data = apply_env_overrides( data: merged_data )
			new( data: data )
		end

		def self.default_data
			{
				"git" => {
					"remote" => "origin",
					"main_branch" => "main",
					"protected_branches" => [ "main", "master" ]
				},
				"hooks" => {
					"path" => "~/.carson/hooks",
					"managed" => [ "pre-commit", "prepare-commit-msg", "pre-merge-commit", "pre-push" ]
				},
				"template" => {
					"managed_files" => [ ".github/carson.md", ".github/copilot-instructions.md", ".github/CLAUDE.md", ".github/AGENTS.md", ".github/pull_request_template.md" ],
					"canonical" => nil
				},
				"workflow" => {
					"style" => "branch"
				},
				"review" => {
					"bot_usernames" => [ "gemini-code-assist[bot]", "github-actions[bot]", "dependabot[bot]" ],
					"wait_seconds" => 10,
					"poll_seconds" => 15,
					"max_polls" => 20,
					"disposition" => "Disposition:",
					"risk_keywords" => [ "bug", "security", "incorrect", "block", "fail", "regression" ],
					"sweep" => {
						"window_days" => 3,
						"states" => [ "open", "closed" ]
					},
					"tracking_issue" => {
						"title" => "Carson review sweep findings",
						"label" => "carson-review-sweep"
					}
				},
				"audit" => {
					"advisory_check_names" => [ "Scheduled review sweep", "Carson governance", "Tag, release, publish" ]
				},
				"govern" => {
					"repos" => [],
					"auto_merge" => true,
					"merge_method" => "squash",
					"agent" => {
						"provider" => "auto",
						"codex" => {},
						"claude" => {}
					},
					"dispatch_state_path" => "~/.carson/govern/dispatch_state.json",
					"check_wait" => 30
				}
			}
			end

		def self.load_global_config_data( repo_root: )
			path = global_config_path( repo_root: repo_root )
			return {} if path.empty? || !File.file?( path )

			raw = File.read( path )
			parsed = JSON.parse( raw )
			raise ConfigError, "global config must be a JSON object at #{path}" unless parsed.is_a?( Hash )
			parsed
		rescue JSON::ParserError => e
			raise ConfigError, "invalid global config JSON at #{path} (#{e.message})"
		end

		def self.global_config_path( repo_root: )
			override = ENV.fetch( "CARSON_CONFIG_FILE", "" ).to_s.strip
			return File.expand_path( override ) unless override.empty?

			home = ENV.fetch( "HOME", "" ).to_s.strip
			return "" unless home.start_with?( "/" )

			File.join( home, ".carson", "config.json" )
		end

		def self.deep_merge( base:, overlay: )
			return deep_dup_value( value: base ) unless overlay.is_a?( Hash )

			base.each_with_object( {} ) { |( key, value ), copy| copy[ key ] = deep_dup_value( value: value ) }.tap do |merged|
				overlay.each do |key, value|
					if merged[ key ].is_a?( Hash ) && value.is_a?( Hash )
						merged[ key ] = deep_merge( base: merged[ key ], overlay: value )
					else
						merged[ key ] = deep_dup_value( value: value )
					end
				end
			end
		end

		def self.deep_dup_value( value: )
			case value
			when Hash
				value.each_with_object( {} ) { |( key, entry ), copy| copy[ key ] = deep_dup_value( value: entry ) }
			when Array
				value.map { |entry| deep_dup_value( value: entry ) }
			else
				value
			end
		end

		def self.apply_env_overrides( data: )
			copy = deep_dup_value( value: data )
			hooks = fetch_hash_section( data: copy, key: "hooks" )
			hooks_path = ENV.fetch( "CARSON_HOOKS_PATH", "" ).to_s.strip
			hooks[ "path" ] = hooks_path unless hooks_path.empty?
			workflow = fetch_hash_section( data: copy, key: "workflow" )
			workflow_style = ENV.fetch( "CARSON_WORKFLOW_STYLE", "" ).to_s.strip
			workflow[ "style" ] = workflow_style unless workflow_style.empty?
			review = fetch_hash_section( data: copy, key: "review" )
			review[ "wait_seconds" ] = env_integer( key: "CARSON_REVIEW_WAIT_SECONDS", fallback: review.fetch( "wait_seconds" ) )
			review[ "poll_seconds" ] = env_integer( key: "CARSON_REVIEW_POLL_SECONDS", fallback: review.fetch( "poll_seconds" ) )
			review[ "max_polls" ] = env_integer( key: "CARSON_REVIEW_MAX_POLLS", fallback: review.fetch( "max_polls" ) )
			disposition = ENV.fetch( "CARSON_REVIEW_DISPOSITION", "" ).to_s.strip
			review[ "disposition" ] = disposition unless disposition.empty?
			sweep = fetch_hash_section( data: review, key: "sweep" )
			sweep[ "window_days" ] = env_integer( key: "CARSON_REVIEW_SWEEP_WINDOW_DAYS", fallback: sweep.fetch( "window_days" ) )
			states = env_string_array( key: "CARSON_REVIEW_SWEEP_STATES" )
			sweep[ "states" ] = states unless states.empty?
			bot_usernames = env_string_array( key: "CARSON_REVIEW_BOT_USERNAMES" )
			review[ "bot_usernames" ] = bot_usernames unless bot_usernames.empty?
			audit = fetch_hash_section( data: copy, key: "audit" )
			advisory_names = env_string_array( key: "CARSON_AUDIT_ADVISORY_CHECK_NAMES" )
			audit[ "advisory_check_names" ] = advisory_names unless advisory_names.empty?
			govern = fetch_hash_section( data: copy, key: "govern" )
			govern_repos = env_string_array( key: "CARSON_GOVERN_REPOS" )
			govern[ "repos" ] = govern_repos unless govern_repos.empty?
			govern_auto_merge = ENV.fetch( "CARSON_GOVERN_AUTO_MERGE", "" ).to_s.strip
			govern[ "auto_merge" ] = ( govern_auto_merge == "true" ) unless govern_auto_merge.empty?
			govern_method = ENV.fetch( "CARSON_GOVERN_MERGE_METHOD", "" ).to_s.strip
			govern[ "merge_method" ] = govern_method unless govern_method.empty?
			agent = fetch_hash_section( data: govern, key: "agent" )
			govern_provider = ENV.fetch( "CARSON_GOVERN_AGENT_PROVIDER", "" ).to_s.strip
			agent[ "provider" ] = govern_provider unless govern_provider.empty?
			govern[ "check_wait" ] = env_integer( key: "CARSON_GOVERN_CHECK_WAIT", fallback: govern.fetch( "check_wait" ) )
			copy
		end

		def self.fetch_hash_section( data:, key: )
			value = data[ key ]
			raise ConfigError, "missing config section #{key}" if value.nil?
			raise ConfigError, "config section #{key} must be an object" unless value.is_a?( Hash )
			value
		end

		def self.env_integer( key:, fallback: )
			text = ENV.fetch( key, "" ).to_s.strip
			return fallback if text.empty?
			Integer( text )
		rescue ArgumentError, TypeError
			fallback
		end

		def self.env_string_array( key: )
			ENV.fetch( key, "" ).split( "," ).map( &:strip ).reject( &:empty? )
		end

		def initialize( data: )
			@git_remote = fetch_string( hash: fetch_hash( hash: data, key: "git" ), key: "remote" )
			@main_branch = fetch_string( hash: fetch_hash( hash: data, key: "git" ), key: "main_branch" )
			@protected_branches = fetch_string_array( hash: fetch_hash( hash: data, key: "git" ), key: "protected_branches" )

			@hooks_path = fetch_string( hash: fetch_hash( hash: data, key: "hooks" ), key: "path" )
			@managed_hooks = fetch_string_array( hash: fetch_hash( hash: data, key: "hooks" ), key: "managed" )

			@template_managed_files = fetch_string_array( hash: fetch_hash( hash: data, key: "template" ), key: "managed_files" )
			@template_canonical = fetch_optional_path( hash: fetch_hash( hash: data, key: "template" ), key: "canonical" )
			resolve_canonical_files!

			workflow_hash = fetch_hash( hash: data, key: "workflow" )
			@workflow_style = fetch_string( hash: workflow_hash, key: "style" ).downcase

			review_hash = fetch_hash( hash: data, key: "review" )
			@review_wait_seconds = fetch_non_negative_integer( hash: review_hash, key: "wait_seconds" )
			@review_poll_seconds = fetch_non_negative_integer( hash: review_hash, key: "poll_seconds" )
			@review_max_polls = fetch_positive_integer( hash: review_hash, key: "max_polls" )
			@review_disposition = fetch_string( hash: review_hash, key: "disposition" )
			@review_risk_keywords = fetch_string_array( hash: review_hash, key: "risk_keywords" )
			sweep_hash = fetch_hash( hash: review_hash, key: "sweep" )
			@review_sweep_window_days = fetch_positive_integer( hash: sweep_hash, key: "window_days" )
			@review_sweep_states = fetch_string_array( hash: sweep_hash, key: "states" ).map( &:downcase )
			tracking_issue_hash = fetch_hash( hash: review_hash, key: "tracking_issue" )
			@review_tracking_issue_title = fetch_string( hash: tracking_issue_hash, key: "title" )
			@review_tracking_issue_label = fetch_string( hash: tracking_issue_hash, key: "label" )
			@review_bot_usernames = fetch_optional_string_array( hash: review_hash, key: "bot_usernames" )
			audit_hash = fetch_hash( hash: data, key: "audit" )
			@audit_advisory_check_names = fetch_optional_string_array( hash: audit_hash, key: "advisory_check_names" )

			govern_hash = fetch_hash( hash: data, key: "govern" )
			@govern_repos = fetch_optional_string_array( hash: govern_hash, key: "repos" ).map { |p| safe_expand_path( p ) }
			@govern_auto_merge = fetch_optional_boolean( hash: govern_hash, key: "auto_merge", default: true, key_path: "govern.auto_merge" )
			@govern_merge_method = fetch_string( hash: govern_hash, key: "merge_method" ).downcase
			govern_agent_hash = fetch_hash( hash: govern_hash, key: "agent" )
			@govern_agent_provider = fetch_string( hash: govern_agent_hash, key: "provider" ).downcase
			dispatch_path = govern_hash.fetch( "dispatch_state_path" ).to_s
			@govern_dispatch_state_path = safe_expand_path( dispatch_path )
			@govern_check_wait = fetch_non_negative_integer( hash: govern_hash, key: "check_wait" )

			validate!
		end

	private

			def validate!
				raise ConfigError, "git.remote cannot be empty" if git_remote.empty?
				raise ConfigError, "git.main_branch cannot be empty" if main_branch.empty?
				raise ConfigError, "git.protected_branches must include #{main_branch}" unless protected_branches.include?( main_branch )
				raise ConfigError, "hooks.path cannot be empty" if hooks_path.empty?
				raise ConfigError, "hooks.managed cannot be empty" if managed_hooks.empty?
				raise ConfigError, "review.disposition cannot be empty" if review_disposition.empty?
				raise ConfigError, "review.risk_keywords cannot be empty" if review_risk_keywords.empty?
				raise ConfigError, "review.sweep.states must contain one or both of open, closed" if ( review_sweep_states - [ "open", "closed" ] ).any? || review_sweep_states.empty?
				raise ConfigError, "review.sweep.states cannot contain duplicates" unless review_sweep_states.uniq.length == review_sweep_states.length
				raise ConfigError, "review.tracking_issue.title cannot be empty" if review_tracking_issue_title.empty?
				raise ConfigError, "review.tracking_issue.label cannot be empty" if review_tracking_issue_label.empty?
				raise ConfigError, "workflow.style must be one of trunk, branch" unless [ "trunk", "branch" ].include?( workflow_style )
				raise ConfigError, "govern.merge.method must be one of merge, squash, rebase" unless [ "merge", "squash", "rebase" ].include?( govern_merge_method )
				raise ConfigError, "govern.agent.provider must be one of auto, codex, claude" unless [ "auto", "codex", "claude" ].include?( govern_agent_provider )
			end

			def fetch_hash( hash:, key: )
				value = hash[ key ]
				raise ConfigError, "missing config key #{key}" unless value.is_a?( Hash )
				value
			end

			def fetch_string( hash:, key: )
				value = hash[ key ]
				raise ConfigError, "missing config key #{key}" if value.nil?
				text = value.to_s.strip
				raise ConfigError, "config key #{key} cannot be blank" if text.empty?
				text
			end

			def fetch_string_array( hash:, key: )
				value = hash[ key ]
				raise ConfigError, "missing config key #{key}" unless value.is_a?( Array )
				array = value.map { |entry| entry.to_s.strip }.reject( &:empty? )
				raise ConfigError, "config key #{key} cannot be empty" if array.empty?
				array
			end

			def fetch_optional_string_array( hash:, key: )
				value = hash[ key ]
				return [] if value.nil?
				raise ConfigError, "config key #{key} must be an array" unless value.is_a?( Array )
				value.map { |entry| entry.to_s.strip }.reject( &:empty? )
			end

			def fetch_non_negative_integer( hash:, key: )
				value = fetch_integer( hash: hash, key: key )
				raise ConfigError, "config key #{key} must be >= 0" if value.negative?
				value
			end

			def fetch_positive_integer( hash:, key: )
				value = fetch_integer( hash: hash, key: key )
				raise ConfigError, "config key #{key} must be > 0" unless value.positive?
				value
			end

			def fetch_integer( hash:, key: )
				value = hash[ key ]
				raise ConfigError, "missing config key #{key}" if value.nil?
				Integer( value )
			rescue ArgumentError, TypeError
				raise ConfigError, "config key #{key} must be an integer"
			end
			def fetch_optional_boolean( hash:, key:, default:, key_path: nil )
				value = hash.fetch( key, default )
				return true if value == true
				return false if value == false

				raise ConfigError, "config key #{key_path || key} must be boolean"
			end

			def safe_expand_path( path )
				return path unless path.start_with?( "~" )

				File.expand_path( path )
			rescue ArgumentError
				path
			end

			# Returns an expanded path string, or nil when the value is absent/blank.
			def fetch_optional_path( hash:, key: )
				value = hash[ key ]
				return nil if value.nil?
				text = value.to_s.strip
				return nil if text.empty?
				safe_expand_path( text )
			end

			# Discovers files in the canonical directory and appends them to managed_files.
			# Canonical files mirror the .github/ structure and are synced alongside Carson's own governance files.
			def resolve_canonical_files!
				return if @template_canonical.nil? || @template_canonical.empty?
				return unless Dir.exist?( @template_canonical )

				Dir.glob( File.join( @template_canonical, "**", "*" ) ).sort.each do |absolute_path|
					next unless File.file?( absolute_path )
					relative = absolute_path.delete_prefix( "#{@template_canonical}/" )
					managed_path = ".github/#{relative}"
					@template_managed_files << managed_path unless @template_managed_files.include?( managed_path )
				end
			end
	end
end
