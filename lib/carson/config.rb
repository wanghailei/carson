require "json"

module Carson
	class ConfigError < StandardError
	end

	# Config is built-in only for outsider mode; host repositories do not carry Carson config files.
	class Config
		attr_reader :git_remote, :main_branch, :protected_branches, :hooks_base_path, :required_hooks,
			:path_groups, :template_managed_files, :lint_languages,
			:review_wait_seconds, :review_poll_seconds, :review_max_polls, :review_sweep_window_days,
			:review_sweep_states, :review_disposition_prefix, :review_risk_keywords,
			:review_tracking_issue_title, :review_tracking_issue_label, :ruby_indentation

		def self.load( repo_root: )
			base_data = default_data
			merged_data = deep_merge( base: base_data, overlay: load_global_config_data( repo_root: repo_root ) )
			data = apply_env_overrides( data: merged_data )
			new( data: data )
		end

		def self.default_data
			{
				"git" => {
					"remote" => "github",
					"main_branch" => "main",
					"protected_branches" => [ "main", "master" ]
				},
				"hooks" => {
					"base_path" => "~/.carson/hooks",
					"required_hooks" => [ "pre-commit", "prepare-commit-msg", "pre-merge-commit", "pre-push" ]
				},
				"scope" => {
					"path_groups" => {
						"tool" => [ "exe/**", "bin/**", "lib/**", "script/**", ".github/**", "templates/.github/**", "assets/hooks/**", "install.sh", "README.md", "RELEASE.md", "VERSION", "carson.gemspec" ],
						"ui" => [ "app/views/**", "app/assets/**", "app/javascript/**", "docs/ui_*.md" ],
						"test" => [ "test/**", "spec/**", "features/**" ],
						"domain" => [ "app/**", "db/**", "config/**" ],
						"docs" => [ "docs/**", "*.md" ]
					}
				},
				"template" => {
					"managed_files" => [ ".github/copilot-instructions.md", ".github/pull_request_template.md" ]
				},
				"lint" => {
					"languages" => default_lint_languages_data
				},
				"review" => {
					"wait_seconds" => 60,
					"poll_seconds" => 15,
					"max_polls" => 20,
					"required_disposition_prefix" => "Disposition:",
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
				"style" => {
					"ruby_indentation" => "tabs"
				}
				}
			end

			def self.default_lint_languages_data
				ruby_runner = File.expand_path( "policy/ruby/lint.rb", __dir__ )
				{
					"ruby" => {
						"enabled" => true,
						"globs" => [ "**/*.rb", "Gemfile", "*.gemspec", "Rakefile" ],
						"command" => [ "ruby", ruby_runner, "{files}" ],
						"config_files" => [ "~/AI/CODING/rubocop.yml" ]
					},
					"javascript" => {
						"enabled" => false,
						"globs" => [ "**/*.js", "**/*.mjs", "**/*.cjs", "**/*.jsx" ],
						"command" => [ "node", "~/AI/CODING/javascript.lint.js", "{files}" ],
						"config_files" => [ "~/AI/CODING/javascript.lint.js" ]
					},
					"css" => {
						"enabled" => false,
						"globs" => [ "**/*.css" ],
						"command" => [ "node", "~/AI/CODING/css.lint.js", "{files}" ],
						"config_files" => [ "~/AI/CODING/css.lint.js" ]
					},
					"html" => {
						"enabled" => false,
						"globs" => [ "**/*.html" ],
						"command" => [ "node", "~/AI/CODING/html.lint.js", "{files}" ],
						"config_files" => [ "~/AI/CODING/html.lint.js" ]
					},
					"erb" => {
						"enabled" => false,
						"globs" => [ "**/*.erb" ],
						"command" => [ "ruby", "~/AI/CODING/erb.lint.rb", "{files}" ],
						"config_files" => [ "~/AI/CODING/erb.lint.rb" ]
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
			hooks_path = ENV.fetch( "CARSON_HOOKS_BASE_PATH", "" ).to_s.strip
			hooks[ "base_path" ] = hooks_path unless hooks_path.empty?
			review = fetch_hash_section( data: copy, key: "review" )
			review[ "wait_seconds" ] = env_integer( key: "CARSON_REVIEW_WAIT_SECONDS", fallback: review.fetch( "wait_seconds" ) )
			review[ "poll_seconds" ] = env_integer( key: "CARSON_REVIEW_POLL_SECONDS", fallback: review.fetch( "poll_seconds" ) )
			review[ "max_polls" ] = env_integer( key: "CARSON_REVIEW_MAX_POLLS", fallback: review.fetch( "max_polls" ) )
			disposition_prefix = ENV.fetch( "CARSON_REVIEW_DISPOSITION_PREFIX", "" ).to_s.strip
			review[ "required_disposition_prefix" ] = disposition_prefix unless disposition_prefix.empty?
			sweep = fetch_hash_section( data: review, key: "sweep" )
			sweep[ "window_days" ] = env_integer( key: "CARSON_REVIEW_SWEEP_WINDOW_DAYS", fallback: sweep.fetch( "window_days" ) )
			states = ENV.fetch( "CARSON_REVIEW_SWEEP_STATES", "" ).split( "," ).map( &:strip ).reject( &:empty? )
			sweep[ "states" ] = states unless states.empty?
			style = fetch_hash_section( data: copy, key: "style" )
			ruby_indentation = ENV.fetch( "CARSON_RUBY_INDENTATION", "" ).to_s.strip
			style[ "ruby_indentation" ] = ruby_indentation unless ruby_indentation.empty?
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

		def initialize( data: )
			@git_remote = fetch_string( hash: fetch_hash( hash: data, key: "git" ), key: "remote" )
			@main_branch = fetch_string( hash: fetch_hash( hash: data, key: "git" ), key: "main_branch" )
			@protected_branches = fetch_string_array( hash: fetch_hash( hash: data, key: "git" ), key: "protected_branches" )

			@hooks_base_path = fetch_string( hash: fetch_hash( hash: data, key: "hooks" ), key: "base_path" )
			@required_hooks = fetch_string_array( hash: fetch_hash( hash: data, key: "hooks" ), key: "required_hooks" )

			@path_groups = fetch_hash( hash: fetch_hash( hash: data, key: "scope" ), key: "path_groups" ).transform_values { |value| normalize_patterns( value: value ) }

			@template_managed_files = fetch_string_array( hash: fetch_hash( hash: data, key: "template" ), key: "managed_files" )
			@lint_languages = normalize_lint_languages(
				languages_hash: fetch_hash( hash: fetch_hash( hash: data, key: "lint" ), key: "languages" )
			)

			review_hash = fetch_hash( hash: data, key: "review" )
			@review_wait_seconds = fetch_non_negative_integer( hash: review_hash, key: "wait_seconds" )
			@review_poll_seconds = fetch_non_negative_integer( hash: review_hash, key: "poll_seconds" )
			@review_max_polls = fetch_positive_integer( hash: review_hash, key: "max_polls" )
			@review_disposition_prefix = fetch_string( hash: review_hash, key: "required_disposition_prefix" )
			@review_risk_keywords = fetch_string_array( hash: review_hash, key: "risk_keywords" )
			sweep_hash = fetch_hash( hash: review_hash, key: "sweep" )
			@review_sweep_window_days = fetch_positive_integer( hash: sweep_hash, key: "window_days" )
			@review_sweep_states = fetch_string_array( hash: sweep_hash, key: "states" ).map( &:downcase )
			tracking_issue_hash = fetch_hash( hash: review_hash, key: "tracking_issue" )
			@review_tracking_issue_title = fetch_string( hash: tracking_issue_hash, key: "title" )
			@review_tracking_issue_label = fetch_string( hash: tracking_issue_hash, key: "label" )
			style_hash = fetch_hash( hash: data, key: "style" )
			@ruby_indentation = fetch_string( hash: style_hash, key: "ruby_indentation" ).downcase

			validate!
		end

	private

			def validate!
				raise ConfigError, "git.remote cannot be empty" if git_remote.empty?
				raise ConfigError, "git.main_branch cannot be empty" if main_branch.empty?
				raise ConfigError, "git.protected_branches must include #{main_branch}" unless protected_branches.include?( main_branch )
				raise ConfigError, "hooks.base_path cannot be empty" if hooks_base_path.empty?
				raise ConfigError, "hooks.required_hooks cannot be empty" if required_hooks.empty?
				raise ConfigError, "scope.path_groups cannot be empty" if path_groups.empty?
				raise ConfigError, "lint.languages cannot be empty" if lint_languages.empty?
				raise ConfigError, "review.required_disposition_prefix cannot be empty" if review_disposition_prefix.empty?
				raise ConfigError, "review.risk_keywords cannot be empty" if review_risk_keywords.empty?
				raise ConfigError, "review.sweep.states must contain one or both of open, closed" if ( review_sweep_states - [ "open", "closed" ] ).any? || review_sweep_states.empty?
				raise ConfigError, "review.sweep.states cannot contain duplicates" unless review_sweep_states.uniq.length == review_sweep_states.length
				raise ConfigError, "review.tracking_issue.title cannot be empty" if review_tracking_issue_title.empty?
				raise ConfigError, "review.tracking_issue.label cannot be empty" if review_tracking_issue_label.empty?
				raise ConfigError, "style.ruby_indentation must be one of tabs, spaces, either" unless [ "tabs", "spaces", "either" ].include?( ruby_indentation )
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

			def normalize_patterns( value: )
				patterns = Array( value ).map { |entry| entry.to_s.strip }.reject( &:empty? )
				raise ConfigError, "scope.path_groups entries must contain at least one glob" if patterns.empty?
				patterns
			end

			def normalize_lint_languages( languages_hash: )
				raise ConfigError, "lint.languages must be an object" unless languages_hash.is_a?( Hash )
				normalised = {}
				languages_hash.each do |language_key, raw_entry|
					language = language_key.to_s.strip.downcase
					raise ConfigError, "lint.languages contains blank language key" if language.empty?
					raise ConfigError, "lint.languages.#{language} must be an object" unless raw_entry.is_a?( Hash )

					normalised[ language ] = normalize_lint_language_entry( language: language, raw_entry: raw_entry )
				end
				normalised
			end

			def normalize_lint_language_entry( language:, raw_entry: )
				{
					enabled: fetch_optional_boolean(
						hash: raw_entry,
						key: "enabled",
						default: true,
						key_path: "lint.languages.#{language}.enabled"
					),
					globs: normalize_lint_globs( language: language, value: raw_entry[ "globs" ] ),
					command: normalize_lint_command( language: language, value: raw_entry[ "command" ] ),
					config_files: normalize_lint_config_files( language: language, value: raw_entry[ "config_files" ] )
				}
			end

			def normalize_lint_globs( language:, value: )
				raise ConfigError, "lint.languages.#{language}.globs must be an array" unless value.is_a?( Array )
				patterns = Array( value ).map { |entry| entry.to_s.strip }.reject( &:empty? )
				raise ConfigError, "lint.languages.#{language}.globs must contain at least one pattern" if patterns.empty?
				patterns
			end

			def normalize_lint_command( language:, value: )
				raise ConfigError, "lint.languages.#{language}.command must be an array" unless value.is_a?( Array )
				command = Array( value ).map { |entry| entry.to_s.strip }.reject( &:empty? )
				raise ConfigError, "lint.languages.#{language}.command must contain at least one argument" if command.empty?
				command
			end

			def normalize_lint_config_files( language:, value: )
				raise ConfigError, "lint.languages.#{language}.config_files must be an array" unless value.is_a?( Array )
				files = Array( value ).map { |entry| entry.to_s.strip }.reject( &:empty? )
				raise ConfigError, "lint.languages.#{language}.config_files must contain at least one path" if files.empty?
				files.map do |path|
					expanded = path.start_with?( "~" ) ? File.expand_path( path ) : path
					raise ConfigError, "lint.languages.#{language}.config_files entries must be absolute paths or ~/ paths" unless expanded.start_with?( "/" )
					expanded
				end
			end

			def fetch_optional_boolean( hash:, key:, default:, key_path: nil )
				value = hash.fetch( key, default )
				return true if value == true
				return false if value == false

				raise ConfigError, "config key #{key_path || key} must be boolean"
			end
	end
end
