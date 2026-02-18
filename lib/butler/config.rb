require "json"

module Butler
	class ConfigError < StandardError
	end

	# Config is built-in only for outsider mode; host repositories do not carry Butler config files.
	class Config
		attr_reader :git_remote, :main_branch, :protected_branches, :hooks_base_path, :required_hooks,
			:branch_pattern, :branch_regex, :lane_group_map, :path_groups, :report_dir, :template_managed_files,
			:review_wait_seconds, :review_poll_seconds, :review_max_polls, :review_sweep_window_days,
			:review_sweep_states, :review_disposition_prefix, :review_risk_keywords,
			:review_tracking_issue_title, :review_tracking_issue_label

		def self.load( repo_root: )
			data = apply_env_overrides( data: default_data )
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
					"base_path" => "~/.butler/hooks",
					"required_hooks" => [ "prepare-commit-msg", "pre-merge-commit", "pre-push" ]
				},
				"scope" => {
					"branch_pattern" => "^codex/(?<lane>[^/]+)/(?<slug>.+)$",
					"lane_group_map" => {
						"tool" => "tool",
						"ui" => "ui",
						"module" => "domain",
						"feature" => "domain",
						"fix" => "domain",
						"test" => "test"
					},
					"path_groups" => {
						"tool" => [ "exe/**", "bin/**", "lib/**", "script/**", ".github/**", "templates/.github/**", "assets/hooks/**", "README.md", "RELEASE.md", "VERSION", "butler.gemspec" ],
						"ui" => [ "app/views/**", "app/assets/**", "app/javascript/**", "docs/ui_*.md" ],
						"test" => [ "test/**", "spec/**", "features/**" ],
						"domain" => [ "app/**", "db/**", "config/**" ],
						"docs" => [ "docs/**", "*.md" ]
					}
				},
				"reports" => {
					"dir" => "/tmp/butler"
				},
				"template" => {
					"managed_files" => [ ".github/copilot-instructions.md", ".github/pull_request_template.md" ]
				},
				"review" => {
					"wait_seconds" => 60,
					"poll_seconds" => 15,
					"max_polls" => 20,
					"required_disposition_prefix" => "Codex:",
					"risk_keywords" => [ "bug", "security", "incorrect", "block", "fail", "regression" ],
					"sweep" => {
						"window_days" => 3,
						"states" => [ "open", "closed" ]
					},
					"tracking_issue" => {
						"title" => "Butler review sweep findings",
						"label" => "butler-review-sweep"
					}
				}
			}
		end

		def self.apply_env_overrides( data: )
			copy = JSON.parse( JSON.generate( data ) )
			hooks = copy.fetch( "hooks" )
			hooks_path = ENV.fetch( "BUTLER_HOOKS_BASE_PATH", "" ).to_s.strip
			hooks[ "base_path" ] = hooks_path unless hooks_path.empty?
			reports = copy.fetch( "reports" )
			report_dir = ENV.fetch( "BUTLER_REPORT_DIR", "" ).to_s.strip
			reports[ "dir" ] = report_dir unless report_dir.empty?
			review = copy.fetch( "review" )
			review[ "wait_seconds" ] = env_integer( key: "BUTLER_REVIEW_WAIT_SECONDS", fallback: review.fetch( "wait_seconds" ) )
			review[ "poll_seconds" ] = env_integer( key: "BUTLER_REVIEW_POLL_SECONDS", fallback: review.fetch( "poll_seconds" ) )
			review[ "max_polls" ] = env_integer( key: "BUTLER_REVIEW_MAX_POLLS", fallback: review.fetch( "max_polls" ) )
			sweep = review.fetch( "sweep" )
			sweep[ "window_days" ] = env_integer( key: "BUTLER_REVIEW_SWEEP_WINDOW_DAYS", fallback: sweep.fetch( "window_days" ) )
			states = ENV.fetch( "BUTLER_REVIEW_SWEEP_STATES", "" ).split( "," ).map( &:strip ).reject( &:empty? )
			sweep[ "states" ] = states unless states.empty?
			copy
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

			@branch_pattern = fetch_string( hash: fetch_hash( hash: data, key: "scope" ), key: "branch_pattern" )
			@branch_regex = compile_branch_regex( pattern: @branch_pattern )
			@lane_group_map = fetch_hash( hash: fetch_hash( hash: data, key: "scope" ), key: "lane_group_map" ).transform_values { |value| value.to_s }
			@path_groups = fetch_hash( hash: fetch_hash( hash: data, key: "scope" ), key: "path_groups" ).transform_values { |value| normalize_patterns( value: value ) }

			@report_dir = fetch_string( hash: fetch_hash( hash: data, key: "reports" ), key: "dir" )
			@template_managed_files = fetch_string_array( hash: fetch_hash( hash: data, key: "template" ), key: "managed_files" )

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

			validate!
		end

	private

			def validate!
				raise ConfigError, "git.remote cannot be empty" if git_remote.empty?
				raise ConfigError, "git.main_branch cannot be empty" if main_branch.empty?
				raise ConfigError, "git.protected_branches must include #{main_branch}" unless protected_branches.include?( main_branch )
				raise ConfigError, "hooks.base_path cannot be empty" if hooks_base_path.empty?
				raise ConfigError, "hooks.required_hooks cannot be empty" if required_hooks.empty?
				raise ConfigError, "scope.lane_group_map cannot be empty" if lane_group_map.empty?
				raise ConfigError, "scope.path_groups cannot be empty" if path_groups.empty?
				raise ConfigError, "reports.dir cannot be empty" if report_dir.empty?
				raise ConfigError, "review.required_disposition_prefix cannot be empty" if review_disposition_prefix.empty?
				raise ConfigError, "review.risk_keywords cannot be empty" if review_risk_keywords.empty?
				raise ConfigError, "review.sweep.states must contain one or both of open, closed" if ( review_sweep_states - [ "open", "closed" ] ).any? || review_sweep_states.empty?
				raise ConfigError, "review.sweep.states cannot contain duplicates" unless review_sweep_states.uniq.length == review_sweep_states.length
				raise ConfigError, "review.tracking_issue.title cannot be empty" if review_tracking_issue_title.empty?
				raise ConfigError, "review.tracking_issue.label cannot be empty" if review_tracking_issue_label.empty?
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

			def compile_branch_regex( pattern: )
				Regexp.new( pattern )
			rescue RegexpError => e
				raise ConfigError, "invalid scope.branch_pattern (#{e.message})"
			end
	end
end
