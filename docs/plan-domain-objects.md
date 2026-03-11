# Domain Object Extraction Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract Carson::Remote, Carson::PullRequest, and Carson::Branch from the Runtime god object so domain concepts have proper first-class representations.

**Architecture:** Each domain object follows the Carson::Worktree blueprint — class-side factories, instance-side state/actions, `runtime` passed as infrastructure dependency. Domain actions raise on failure (new pattern), Runtime delegates catch and translate to exit codes. Sequence: Remote → PullRequest → Branch.

**Tech Stack:** Ruby, Minitest, Carson CLI framework

**Spec:** `docs/design-domain-objects.md`

---

## Chunk 1: Carson::Remote

### Task 1: Remote — initialise with owner/repo parsing

**Files:**
- Create: `lib/carson/remote.rb`
- Create: `test/remote_test.rb`

- [ ] **Step 1: Write the failing test for SSH URL parsing**

```ruby
# test/remote_test.rb
require_relative "test_helper"

class RemoteTest < Minitest::Test
	include CarsonTestSupport

	def test_parses_ssh_remote_url
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "git@github.com:wanghailei/carson.git", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "origin", remote.name
		assert_equal "wanghailei", remote.owner
		assert_equal "carson", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_parses_https_remote_url
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "https://github.com/wanghailei/carson.git", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "wanghailei", remote.owner
		assert_equal "carson", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_parses_https_without_dot_git
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		system( "git", "-C", repo_root, "remote", "set-url", "origin", "https://github.com/owner/repo", out: File::NULL, err: File::NULL )

		remote = Carson::Remote.new( name: "origin", runtime: runtime )

		assert_equal "owner", remote.owner
		assert_equal "repo", remote.repo
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "remote", "add", "origin", "git@github.com:test/test.git", out: File::NULL, err: File::NULL )
	end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/remote_test.rb`
Expected: FAIL — `uninitialized constant Carson::Remote`

- [ ] **Step 3: Write minimal Remote implementation**

```ruby
# lib/carson/remote.rb
module Carson
	class Remote
		class Error < StandardError
			attr_reader :recovery

			def initialize( message, recovery: nil )
				super( message )
				@recovery = recovery
			end
		end

		URL_PATTERN = %r{\A(?:git@|https?://|ssh://git@)?[^/:]+[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?\z}.freeze

		attr_reader :name, :owner, :repo

		def initialize( name:, runtime: )
			@name = name
			@runtime = runtime
			@owner, @repo = parse_remote_url
		end

	private

		attr_reader :runtime

		def parse_remote_url
			remote_url = runtime.git_capture!( "config", "--get", "remote.#{name}.url" ).strip
			match = remote_url.match( URL_PATTERN )
			return [ match[ :owner ], match[ :repo ] ] if match

			# Fallback: ask gh for nameWithOwner.
			stdout_text, = runtime.gh_capture_soft( "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" )
			name_with_owner = stdout_text.to_s.strip
			if name_with_owner.include?( "/" )
				owner, repo = name_with_owner.split( "/", 2 )
				return [ owner, repo ] unless owner.to_s.empty? || repo.to_s.empty?
			end

			repo_name = File.basename( remote_url ).sub( /\.git\z/, "" )
			return [ "local", repo_name ] unless repo_name.empty?
			raise Error.new( "unable to parse owner/repo from remote URL #{remote_url}" )
		end
	end
end
```

- [ ] **Step 4: Require remote.rb from lib/carson.rb or runtime.rb**

Find where `require_relative "worktree"` is and add `require_relative "remote"` alongside it.

- [ ] **Step 5: Run test to verify it passes**

Run: `ruby -Ilib -Itest test/remote_test.rb`
Expected: 3 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/carson/remote.rb test/remote_test.rb
# Also add the require line change
git commit -m "feat: add Carson::Remote with owner/repo parsing"
```

### Task 2: Remote — push and force_push_with_lease

**Files:**
- Modify: `lib/carson/remote.rb`
- Modify: `test/remote_test.rb`

- [ ] **Step 1: Write the failing test for push**

```ruby
def test_push_succeeds
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo_with_bare_remote( repo_root )
	create_feature_branch( repo_root, "test-push" )

	remote = Carson::Remote.new( name: "origin", runtime: runtime )
	result = remote.push!( branch: "test-push" )

	assert_equal remote, result
	destroy_runtime_repo( repo_root: repo_root )
end

def test_push_raises_on_failure
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo( repo_root )
	# No bare remote — push will fail.
	system( "git", "-C", repo_root, "checkout", "-b", "fail-push", out: File::NULL, err: File::NULL )
	File.write( File.join( repo_root, "f.txt" ), "x" )
	system( "git", "-C", repo_root, "add", "f.txt", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "x", out: File::NULL, err: File::NULL )

	remote = Carson::Remote.new( name: "origin", runtime: runtime )
	error = assert_raises( Carson::Remote::Error ) { remote.push!( branch: "fail-push" ) }

	assert_match( /push failed|Could not read|does not appear/, error.message )
	destroy_runtime_repo( repo_root: repo_root )
end

def test_force_push_with_lease_succeeds_after_rebase
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo_with_bare_remote( repo_root )
	create_feature_branch( repo_root, "test-fwl" )
	# Push once to establish tracking.
	system( "git", "-C", repo_root, "push", "-u", "origin", "test-fwl", out: File::NULL, err: File::NULL )
	# Amend to create non-fast-forward condition.
	system( "git", "-C", repo_root, "commit", "--amend", "-m", "amended", out: File::NULL, err: File::NULL )

	remote = Carson::Remote.new( name: "origin", runtime: runtime )
	result = remote.force_push_with_lease!( branch: "test-fwl" )

	assert_equal remote, result
	destroy_runtime_repo( repo_root: repo_root )
end
```

Add the helpers:

```ruby
def init_git_repo_with_bare_remote( repo_root )
	remote_path = File.join( File.dirname( repo_root ), "remote-#{File.basename( repo_root )}.git" )
	system( "git", "init", "--bare", "-b", "main", remote_path, out: File::NULL, err: File::NULL )
	init_git_repo( repo_root )
	system( "git", "-C", repo_root, "remote", "set-url", "origin", remote_path, out: File::NULL, err: File::NULL )
	File.write( File.join( repo_root, "README.md" ), "# Test" )
	system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "push", "-u", "origin", "main", out: File::NULL, err: File::NULL )
end

def create_feature_branch( repo_root, branch_name )
	system( "git", "-C", repo_root, "checkout", "-b", branch_name, out: File::NULL, err: File::NULL )
	File.write( File.join( repo_root, "feature.txt" ), "feature work" )
	system( "git", "-C", repo_root, "add", "feature.txt", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "add feature", out: File::NULL, err: File::NULL )
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/remote_test.rb`
Expected: FAIL — `undefined method 'push!'`

- [ ] **Step 3: Implement push! and force_push_with_lease!**

Add to `lib/carson/remote.rb` inside the class, before `private`:

```ruby
# Pushes the branch with tracking. Uses --no-verify to bypass the pre-push
# hook that Carson itself installed (Carson is the one doing the push).
# Returns self on success. Raises Remote::Error on failure.
def push!( branch: )
	_, stderr, success, = runtime.git_run( "push", "--no-verify", "-u", name, branch )
	raise Error.new(
		stderr.to_s.strip.then { it.empty? ? "push failed" : it },
	) unless success
	self
end

# Force-pushes with lease protection. The lease check compares the local
# tracking ref against the remote — if another actor pushed since the last
# fetch, the push is refused ("stale info"). Returns self on success.
# Raises Remote::Error on failure.
def force_push_with_lease!( branch: )
	_, stderr, success, = runtime.git_run( "push", "--no-verify", "--force-with-lease", "-u", name, branch )
	raise Error.new(
		stderr.to_s.strip.then { it.empty? ? "push failed (force-with-lease)" : it },
		recovery: stderr.to_s.include?( "stale info" ) ? "git fetch #{name} #{branch} && carson deliver" : nil
	) unless success
	self
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/remote_test.rb`
Expected: 6 tests, 0 failures

- [ ] **Step 5: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass (no regressions)

- [ ] **Step 6: Commit**

```bash
git add lib/carson/remote.rb test/remote_test.rb
git commit -m "feat: add push! and force_push_with_lease! to Carson::Remote"
```

### Task 3: Wire Remote into deliver.rb

**Files:**
- Modify: `lib/carson/runtime/deliver.rb` — replace `push_branch!` and `force_push_with_lease!` with Remote calls
- Modify: `test/runtime_deliver_test.rb` — verify existing tests still pass

- [ ] **Step 1: Replace push_branch! in deliver!**

In `deliver.rb`, replace the push step (lines 25-27) with:

```ruby
# Step 1: push the branch.
remote_obj = Remote.new( name: remote, runtime: self )
begin
	remote_obj.push!( branch: branch )
rescue Remote::Error => e
	if e.message.include?( "non-fast-forward" )
		begin
			puts_verbose "push rejected (non-fast-forward), retrying with --force-with-lease"
			remote_obj.force_push_with_lease!( branch: branch )
		rescue Remote::Error => e2
			result[ :error ] = e2.message
			result[ :recovery ] = e2.recovery
			return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
		end
	else
		result[ :error ] = e.message
		return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
	end
end
puts_verbose "pushed #{branch} to #{remote}"
```

- [ ] **Step 2: Remove old push_branch! and force_push_with_lease! methods**

Delete the `push_branch!` method (lines 134-155) and `force_push_with_lease!` method (lines 157-180) from deliver.rb.

- [ ] **Step 3: Run deliver tests**

Run: `ruby -Ilib -Itest test/runtime_deliver_test.rb`
Expected: All 24 deliver tests pass

- [ ] **Step 4: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/carson/runtime/deliver.rb
git commit -m "refactor: wire deliver.rb to use Carson::Remote for push"
```

### Task 4: Wire Remote into repository_coordinates callers

**Files:**
- Modify: `lib/carson/runtime/review/data_access.rb` — replace `repository_coordinates` with Remote
- Modify: `lib/carson/runtime/review.rb` — use Remote for owner/repo
- Modify: `lib/carson/runtime/audit.rb` — use Remote for owner/repo
- Modify: `lib/carson/runtime/govern.rb` — use Remote for owner/repo
- Modify: `lib/carson/runtime/local/prune.rb` — use Remote for owner/repo

- [ ] **Step 1: Add a convenience method on Remote or use directly**

Each caller currently does `owner, repo = repository_coordinates`. Replace with:

```ruby
remote_obj = Remote.new( name: config.git_remote, runtime: self )
owner, repo = remote_obj.owner, remote_obj.repo
```

Or for callers that use it once, inline: `Remote.new( name: config.git_remote, runtime: self )` and call `.owner` / `.repo`.

- [ ] **Step 2: Update review.rb (2 call sites: lines 31, 147)**

Replace `owner, repo = repository_coordinates` with:
```ruby
remote_obj = Remote.new( name: config.git_remote, runtime: self )
```
Then use `remote_obj.owner` and `remote_obj.repo` where `owner` and `repo` were used.

- [ ] **Step 3: Update audit.rb (1 call site: line 313)**

Same pattern as review.rb.

- [ ] **Step 4: Update govern.rb (1 call site: line 468)**

Note: This uses `scoped_runtime.send( :repository_coordinates )` because it's on a different runtime instance. Replace with:
```ruby
remote_obj = Remote.new( name: scoped_runtime.send( :config ).git_remote, runtime: scoped_runtime )
```

- [ ] **Step 5: Update prune.rb (2 call sites: lines 321, 436)**

Replace `owner, repo = repository_coordinates` with Remote construction.

- [ ] **Step 6: Remove repository_coordinates from data_access.rb**

Delete the `repository_coordinates` method (lines 226-241) from `review/data_access.rb`.

- [ ] **Step 7: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add lib/carson/runtime/review/data_access.rb lib/carson/runtime/review.rb \
  lib/carson/runtime/audit.rb lib/carson/runtime/govern.rb lib/carson/runtime/local/prune.rb
git commit -m "refactor: replace repository_coordinates with Carson::Remote"
```

---

## Chunk 2: Carson::PullRequest

### Task 5: PullRequest — lookups (find_open, for_branch, open_for_branch?)

**Files:**
- Create: `lib/carson/pull_request.rb`
- Create: `test/pull_request_test.rb`

- [ ] **Step 1: Write failing tests for find_open**

```ruby
# test/pull_request_test.rb
require_relative "test_helper"

class PullRequestTest < Minitest::Test
	include CarsonTestSupport

	def test_find_open_returns_instance_for_open_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "open_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_instance_of Carson::PullRequest, pr
		assert_equal 42, pr.number
		assert_equal "OPEN", pr.state
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_find_open_returns_nil_for_merged_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "merged_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_nil pr
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_find_open_returns_nil_when_no_pr
		runtime, repo_root = build_runtime_with_mock_gh( scenario: "no_pr" )
		init_git_repo( repo_root )

		pr = Carson::PullRequest.find_open( branch: "feature", runtime: runtime )

		assert_nil pr
		destroy_runtime_repo( repo_root: repo_root )
	end
end
```

Mock gh scenarios for this test (add to private helpers):

```ruby
def mock_gh_script( scenario: )
	<<~BASH
		#!/usr/bin/env bash
		if [[ "${1:-}" == "--version" ]]; then echo "gh version mock"; exit 0; fi

		case "#{scenario}" in
		open_pr)
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				echo '{"number":42,"url":"https://github.com/test/test/pull/42","state":"OPEN"}'
				exit 0
			fi
			;;
		merged_pr)
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				echo '{"number":42,"url":"https://github.com/test/test/pull/42","state":"MERGED"}'
				exit 0
			fi
			;;
		no_pr)
			if [[ "$1" == "pr" && "$2" == "view" ]]; then
				echo "no pull requests found" >&2
				exit 1
			fi
			;;
		esac
		exit 1
	BASH
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: FAIL — `uninitialized constant Carson::PullRequest`

- [ ] **Step 3: Write PullRequest with find_open**

```ruby
# lib/carson/pull_request.rb
module Carson
	class PullRequest
		class Error < StandardError
			attr_reader :recovery

			def initialize( message, recovery: nil )
				super( message )
				@recovery = recovery
			end
		end

		attr_reader :number, :url, :state

		def initialize( number:, url: nil, state: nil, runtime: )
			@number = number
			@url = url.to_s
			@state = state.to_s
			@runtime = runtime
		end

		# Finds an open PR for the given branch. Returns instance or nil.
		# Filters on OPEN state — merged/closed PRs are treated as absent.
		def self.find_open( branch:, runtime: )
			stdout, _, success, = runtime.gh_run( "pr", "view", branch, "--json", "number,url,state" )
			return nil unless success

			data = JSON.parse( stdout ) rescue nil
			return nil unless data && data[ "number" ] && data[ "state" ] == "OPEN"

			new( number: data[ "number" ], url: data[ "url" ], state: data[ "state" ], runtime: runtime )
		end

		# Finds any PR (any state) for a branch. Returns instance or nil.
		# Used by gate_support for review gate.
		def self.for_branch( branch:, runtime: )
			stdout, _, success, = runtime.gh_run( "pr", "view", "--", branch, "--json", "number,title,url,state" )
			return nil unless success

			data = JSON.parse( stdout ) rescue nil
			return nil unless data && data[ "number" ]

			new( number: data[ "number" ], url: data[ "url" ], state: data[ "state" ], runtime: runtime )
		end

		# Fast check: does this branch have any open PR? Returns boolean.
		# Uses REST API with per_page=1 for speed. Used by prune.
		def self.open_for_branch?( branch:, runtime: )
			remote = Remote.new( name: runtime.config.git_remote, runtime: runtime )
			stdout, _, success, = runtime.gh_run(
				"api", "repos/#{remote.owner}/#{remote.repo}/pulls",
				"--method", "GET",
				"-f", "state=open",
				"-f", "head=#{remote.owner}:#{branch}",
				"-f", "per_page=1"
			)
			return true unless success

			results = Array( JSON.parse( stdout ) )
			!results.empty?
		rescue StandardError
			true
		end

	private

		attr_reader :runtime
	end
end
```

- [ ] **Step 4: Require pull_request.rb alongside remote.rb**

- [ ] **Step 5: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: 3 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/carson/pull_request.rb test/pull_request_test.rb
git commit -m "feat: add Carson::PullRequest with lookup methods"
```

### Task 6: PullRequest — create!

**Files:**
- Modify: `lib/carson/pull_request.rb`
- Modify: `test/pull_request_test.rb`

- [ ] **Step 1: Write failing test for create!**

```ruby
def test_create_returns_instance
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "create_pr" )
	init_git_repo( repo_root )

	pr = Carson::PullRequest.create!( branch: "feature", title: "My PR", body_file: nil, runtime: runtime )

	assert_instance_of Carson::PullRequest, pr
	assert_equal 99, pr.number
	destroy_runtime_repo( repo_root: repo_root )
end

def test_create_raises_on_failure
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "create_pr_fail" )
	init_git_repo( repo_root )

	error = assert_raises( Carson::PullRequest::Error ) do
		Carson::PullRequest.create!( branch: "feature", title: "My PR", body_file: nil, runtime: runtime )
	end

	assert_match( /pr create failed/, error.message )
	assert error.recovery
	destroy_runtime_repo( repo_root: repo_root )
end
```

Add mock scenarios:

```ruby
# In mock_gh_script, add:
# create_pr)
#   if [[ "$1" == "pr" && "$2" == "create" ]]; then
#     echo "https://github.com/test/test/pull/99"
#     exit 0
#   fi
# create_pr_fail)
#   if [[ "$1" == "pr" && "$2" == "create" ]]; then
#     echo "pr create failed" >&2
#     exit 1
#   fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: FAIL — `undefined method 'create!'`

- [ ] **Step 3: Implement create!**

Add to `lib/carson/pull_request.rb`:

```ruby
# Creates a PR via gh. Title defaults to branch name humanised.
# Returns instance. Raises PullRequest::Error on failure.
def self.create!( branch:, title: nil, body_file: nil, runtime: )
	pr_title = title || default_title( branch: branch )
	args = [ "pr", "create", "--title", pr_title, "--head", branch ]
	if body_file && File.exist?( body_file )
		args.push( "--body-file", body_file )
	else
		args.push( "--body", "" )
	end

	stdout, stderr, success, = runtime.gh_run( *args )
	unless success
		error_text = stderr.to_s.strip
		error_text = "pr create failed" if error_text.empty?
		raise Error.new( error_text, recovery: "gh pr create --title '#{pr_title}' --head #{branch}" )
	end

	# gh pr create prints the URL on success. Parse number from it.
	pr_url = stdout.to_s.strip
	pr_number = pr_url.split( "/" ).last.to_i
	if pr_number > 0
		new( number: pr_number, url: pr_url, state: "OPEN", runtime: runtime )
	else
		# Fallback: query the just-created PR.
		find_open( branch: branch, runtime: runtime ) ||
			raise( Error.new( "created PR but could not retrieve it" ) )
	end
end

# Generates a default PR title from the branch name.
def self.default_title( branch: )
	branch.tr( "-", " " ).gsub( "/", ": " ).sub( /\A\w/ ) { it.upcase }
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: 5 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add lib/carson/pull_request.rb test/pull_request_test.rb
git commit -m "feat: add PullRequest.create! with error contract"
```

### Task 7: PullRequest — instance actions (merge!, ci_status, review_decision)

**Files:**
- Modify: `lib/carson/pull_request.rb`
- Modify: `test/pull_request_test.rb`

- [ ] **Step 1: Write failing tests for merge!, ci_status, review_decision**

```ruby
def test_merge_returns_self
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "merge_ok" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	result = pr.merge!( method: "squash" )

	assert_equal pr, result
	destroy_runtime_repo( repo_root: repo_root )
end

def test_merge_raises_on_failure
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "merge_fail" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	error = assert_raises( Carson::PullRequest::Error ) { pr.merge!( method: "squash" ) }

	assert_match( /merge failed/, error.message )
	assert_equal "gh pr merge 42 --squash", error.recovery
	destroy_runtime_repo( repo_root: repo_root )
end

def test_ci_status_pass
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_pass" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	assert_equal :pass, pr.ci_status
	destroy_runtime_repo( repo_root: repo_root )
end

def test_ci_status_fail
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_fail" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	assert_equal :fail, pr.ci_status
	destroy_runtime_repo( repo_root: repo_root )
end

def test_ci_status_none_when_no_checks
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "ci_none" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	assert_equal :none, pr.ci_status
	destroy_runtime_repo( repo_root: repo_root )
end

def test_review_decision_approved
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "review_approved" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	assert_equal :approved, pr.review_decision
	destroy_runtime_repo( repo_root: repo_root )
end

def test_review_decision_changes_requested
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "review_changes" )
	init_git_repo( repo_root )
	pr = Carson::PullRequest.new( number: 42, runtime: runtime )

	assert_equal :changes_requested, pr.review_decision
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: FAIL — undefined methods

- [ ] **Step 3: Implement instance methods**

Add to `lib/carson/pull_request.rb` (public instance methods):

```ruby
# Merges the PR. Returns self. Raises PullRequest::Error on failure.
def merge!( method: )
	_, stderr, success, = runtime.gh_run( "pr", "merge", number.to_s, "--#{method}" )
	raise Error.new(
		stderr.to_s.strip.then { it.empty? ? "merge failed" : it },
		recovery: "gh pr merge #{number} --#{method}"
	) unless success
	self
end

# Checks CI status. Returns :pass, :fail, :pending, or :none.
def ci_status
	stdout, _, success, = runtime.gh_run( "pr", "checks", number.to_s, "--json", "name,bucket" )
	return :none unless success

	checks = JSON.parse( stdout ) rescue []
	return :none if checks.empty?

	buckets = checks.map { it[ "bucket" ].to_s.downcase }
	return :fail if buckets.include?( "fail" )
	return :pending if buckets.include?( "pending" )
	:pass
end

# Checks review decision. Returns :approved, :changes_requested, :review_required, or :none.
def review_decision
	stdout, _, success, = runtime.gh_run( "pr", "view", number.to_s, "--json", "reviewDecision" )
	return :none unless success

	data = JSON.parse( stdout ) rescue {}
	decision = data[ "reviewDecision" ].to_s.strip.upcase
	case decision
	when "APPROVED" then :approved
	when "CHANGES_REQUESTED" then :changes_requested
	when "REVIEW_REQUIRED" then :review_required
	else :none
	end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/pull_request_test.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/carson/pull_request.rb test/pull_request_test.rb
git commit -m "feat: add PullRequest merge!, ci_status, review_decision"
```

### Task 8: PullRequest — merged_for_branch (prune evidence)

**Files:**
- Modify: `lib/carson/pull_request.rb`
- Modify: `test/pull_request_test.rb`

- [ ] **Step 1: Write failing test**

```ruby
def test_merged_for_branch_returns_instance
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "merged_evidence" )
	init_git_repo( repo_root )

	pr = Carson::PullRequest.merged_for_branch( branch: "old-feature", branch_tip_sha: "abc123", runtime: runtime )

	assert_instance_of Carson::PullRequest, pr
	assert_equal 10, pr.number
	destroy_runtime_repo( repo_root: repo_root )
end

def test_merged_for_branch_returns_nil_when_no_match
	runtime, repo_root = build_runtime_with_mock_gh( scenario: "no_merged_evidence" )
	init_git_repo( repo_root )

	pr = Carson::PullRequest.merged_for_branch( branch: "old-feature", branch_tip_sha: "abc123", runtime: runtime )

	assert_nil pr
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement merged_for_branch**

This is the most complex method — paginated REST API search for merged PRs matching exact SHA. Port the logic from `prune.rb:435-504` but return a PullRequest instance (or nil) instead of `[hash, error_string]`.

```ruby
# Finds a merged PR whose head SHA matches branch_tip_sha.
# Returns instance or nil. Used by prune and housekeep for evidence-based deletion.
def self.merged_for_branch( branch:, branch_tip_sha:, runtime: )
	remote = Remote.new( name: runtime.config.git_remote, runtime: runtime )
	main = runtime.config.main_branch
	results = []
	page = 1
	max_pages = 50

	loop do
		stdout, _, success, = runtime.gh_run(
			"api", "repos/#{remote.owner}/#{remote.repo}/pulls",
			"--method", "GET",
			"-f", "state=closed",
			"-f", "base=#{main}",
			"-f", "head=#{remote.owner}:#{branch}",
			"-f", "sort=updated",
			"-f", "direction=desc",
			"-f", "per_page=100",
			"-f", "page=#{page}"
		)
		return nil unless success

		page_nodes = Array( JSON.parse( stdout ) )
		break if page_nodes.empty?

		page_nodes.each do |entry|
			next unless entry.dig( "head", "ref" ).to_s == branch.to_s
			next unless entry.dig( "base", "ref" ).to_s == main
			next unless entry.dig( "head", "sha" ).to_s == branch_tip_sha
			next if entry[ "merged_at" ].nil?

			results << {
				number: entry[ "number" ],
				url: entry[ "html_url" ].to_s,
				merged_at: entry[ "merged_at" ]
			}
		end

		break if page >= max_pages
		page += 1
	end

	latest = results.max_by { it.fetch( :merged_at ) }
	return nil if latest.nil?

	new( number: latest[ :number ], url: latest[ :url ], state: "MERGED", runtime: runtime )
rescue StandardError
	nil
end
```

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add lib/carson/pull_request.rb test/pull_request_test.rb
git commit -m "feat: add PullRequest.merged_for_branch for prune evidence"
```

### Task 9: Wire PullRequest into deliver.rb

**Files:**
- Modify: `lib/carson/runtime/deliver.rb`

- [ ] **Step 1: Replace find_or_create_pr! with PullRequest calls**

In `deliver!`, replace the PR find/create step (lines 29-35) with:

```ruby
# Step 2: find or create the PR.
pr = PullRequest.find_open( branch: branch, runtime: self )
unless pr
	begin
		pr = PullRequest.create!( branch: branch, title: title, body_file: body_file, runtime: self )
	rescue PullRequest::Error => e
		result[ :error ] = e.message
		result[ :recovery ] = e.recovery
		return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
	end
end
pr_number = pr.number
pr_url = pr.url
```

- [ ] **Step 2: Replace check_pr_ci and check_pr_review with instance methods**

Replace `ci_status = check_pr_ci( number: pr_number )` with `ci_status = pr.ci_status`.
Replace `review = check_pr_review( number: pr_number )` with `review = pr.review_decision`.

- [ ] **Step 3: Replace merge_pr! with pr.merge!**

Replace the merge step with:

```ruby
# Step 5: merge.
begin
	method = config.govern_merge_method
	result[ :merge_method ] = method
	pr.merge!( method: method )
rescue PullRequest::Error => e
	result[ :error ] = e.message
	result[ :recovery ] = e.recovery
	return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
end
```

- [ ] **Step 4: Remove old private methods**

Delete from deliver.rb: `find_or_create_pr!`, `find_existing_pr`, `create_pr!`, `default_pr_title`, `check_pr_ci`, `check_pr_review`, `merge_pr!`.

- [ ] **Step 5: Run deliver tests**

Run: `ruby -Ilib -Itest test/runtime_deliver_test.rb`
Expected: All 24 tests pass

- [ ] **Step 6: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/carson/runtime/deliver.rb
git commit -m "refactor: wire deliver.rb to use Carson::PullRequest"
```

### Task 10: Wire PullRequest into gate_support.rb and prune.rb

**Files:**
- Modify: `lib/carson/runtime/review/gate_support.rb`
- Modify: `lib/carson/runtime/local/prune.rb`
- Modify: `lib/carson/runtime/housekeep.rb`

- [ ] **Step 1: Replace current_pull_request_for_branch in gate_support.rb**

Replace the method body (lines 54-68) to delegate to PullRequest:

```ruby
def current_pull_request_for_branch( branch_name: )
	pr = PullRequest.for_branch( branch: branch_name, runtime: self )
	return nil unless pr
	{ number: pr.number, title: pr.url, url: pr.url, state: pr.state }
end
```

Note: Keep the return format as a hash for now — `review_gate!` expects a hash, not a PullRequest instance. This is a thin adapter. Full review module refactoring is second pass.

- [ ] **Step 2: Replace branch_has_open_pr? in prune.rb**

Replace the method body (lines 320-335) to delegate:

```ruby
def branch_has_open_pr?( branch: )
	PullRequest.open_for_branch?( branch: branch, runtime: self )
end
```

- [ ] **Step 3: Replace merged_pr_for_branch in prune.rb**

Replace the method body (lines 435-504) to delegate:

```ruby
def merged_pr_for_branch( branch:, branch_tip_sha: )
	pr = PullRequest.merged_for_branch( branch: branch, branch_tip_sha: branch_tip_sha, runtime: self )
	if pr
		[ { number: pr.number, url: pr.url, merged_at: nil, head_sha: branch_tip_sha }, nil ]
	else
		[ nil, "no merged PR evidence for branch tip #{branch_tip_sha} into #{config.main_branch}" ]
	end
end
```

Note: Keep the `[result, error]` return format — prune callers expect this tuple. Thin adapter, same as gate_support.

- [ ] **Step 4: Run prune and review tests**

Run: `ruby -Ilib -Itest test/runtime_prune_test.rb`
Run: `ruby -Ilib -Itest test/runtime_review_test.rb`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/carson/runtime/review/gate_support.rb lib/carson/runtime/local/prune.rb
git commit -m "refactor: wire gate_support and prune to use Carson::PullRequest"
```

---

## Chunk 3: Carson::Branch

### Task 11: Branch — current and exists?

**Files:**
- Create: `lib/carson/branch.rb`
- Create: `test/branch_test.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# test/branch_test.rb
require_relative "test_helper"

class BranchTest < Minitest::Test
	include CarsonTestSupport

	def test_current_returns_branch_instance
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		branch = Carson::Branch.current( runtime: runtime )

		assert_instance_of Carson::Branch, branch
		assert_equal "main", branch.name
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_current_returns_nil_for_detached_head
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )
		# Detach HEAD.
		sha = `git -C #{repo_root} rev-parse HEAD`.strip
		system( "git", "-C", repo_root, "checkout", sha, out: File::NULL, err: File::NULL )

		branch = Carson::Branch.current( runtime: runtime )

		assert_nil branch
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_exists_returns_true_for_existing_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		assert Carson::Branch.exists?( name: "main", runtime: runtime )
		destroy_runtime_repo( repo_root: repo_root )
	end

	def test_exists_returns_false_for_missing_branch
		runtime, repo_root = build_runtime( verbose: false )
		init_git_repo( repo_root )

		refute Carson::Branch.exists?( name: "nonexistent", runtime: runtime )
		destroy_runtime_repo( repo_root: repo_root )
	end

private

	def init_git_repo( repo_root )
		system( "git", "-C", repo_root, "init", "-b", "main", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.email", "test@test.com", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "config", "user.name", "Test", out: File::NULL, err: File::NULL )
		File.write( File.join( repo_root, "README.md" ), "# Test" )
		system( "git", "-C", repo_root, "add", "README.md", out: File::NULL, err: File::NULL )
		system( "git", "-C", repo_root, "commit", "-m", "init", out: File::NULL, err: File::NULL )
	end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby -Ilib -Itest test/branch_test.rb`
Expected: FAIL — `uninitialized constant Carson::Branch`

- [ ] **Step 3: Implement Branch**

```ruby
# lib/carson/branch.rb
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
	end
end
```

- [ ] **Step 4: Require branch.rb**

- [ ] **Step 5: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/branch_test.rb`
Expected: 4 tests, 0 failures

- [ ] **Step 6: Commit**

```bash
git add lib/carson/branch.rb test/branch_test.rb
git commit -m "feat: add Carson::Branch with current and exists?"
```

### Task 12: Branch — classification methods (stale, orphaned, absorbed)

**Files:**
- Modify: `lib/carson/branch.rb`
- Modify: `test/branch_test.rb`

- [ ] **Step 1: Write failing tests for stale branches**

```ruby
def test_stale_returns_branches_with_gone_upstream
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo_with_remote( repo_root )
	# Create a branch, push it, then delete the remote tracking ref.
	system( "git", "-C", repo_root, "checkout", "-b", "stale-branch", out: File::NULL, err: File::NULL )
	File.write( File.join( repo_root, "f.txt" ), "x" )
	system( "git", "-C", repo_root, "add", "f.txt", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "x", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "push", "-u", "origin", "stale-branch", out: File::NULL, err: File::NULL )
	# Delete from remote, then fetch --prune to mark gone.
	system( "git", "-C", @remote_path, "branch", "-D", "stale-branch", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "fetch", "--prune", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "checkout", "main", out: File::NULL, err: File::NULL )

	stale = Carson::Branch.stale( runtime: runtime )

	branch_names = stale.map( &:name )
	assert_includes branch_names, "stale-branch"
	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 2: Run test to verify it fails**

- [ ] **Step 3: Implement classification methods**

Add to `lib/carson/branch.rb`:

```ruby
# Returns branches whose upstream is gone (remote tracking branch deleted).
def self.stale( runtime: )
	runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" )
		.lines.filter_map do |line|
		branch, upstream, track = line.strip.split( "\t", 3 )
		next if branch.to_s.empty? || upstream.to_s.empty?
		next unless upstream.start_with?( "#{runtime.config.git_remote}/" ) && track.to_s.include?( "gone" )
		new( name: branch )
	end
end

# Returns branches with no upstream tracking, excluding protected and main.
def self.orphaned( active_branch: nil, cwd_branch: nil, runtime: )
	runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads" )
		.lines.filter_map do |line|
		branch, upstream = line.strip.split( "\t", 2 )
		branch = branch.to_s.strip
		next if branch.empty?
		next unless upstream.to_s.strip.empty?
		next if runtime.config.protected_branches.include?( branch )
		next if branch == active_branch
		next if cwd_branch && branch == cwd_branch
		new( name: branch )
	end
end

# Returns branches fully merged into main (all changes present on main).
def self.absorbed( active_branch: nil, cwd_branch: nil, runtime: )
	runtime.git_capture!( "for-each-ref", "--format=%(refname:short)\t%(upstream:short)\t%(upstream:track)", "refs/heads" )
		.lines.filter_map do |line|
		branch, upstream, track = line.strip.split( "\t", 3 )
		branch = branch.to_s.strip
		next if branch.empty? || upstream.to_s.strip.empty?
		next if track.to_s.include?( "gone" )
		next if runtime.config.protected_branches.include?( branch )
		next if branch == active_branch
		next if cwd_branch && branch == cwd_branch
		next unless absorbed_into_main?( branch: branch, runtime: runtime )
		new( name: branch )
	end
end

# Checks if every change on the branch is already present on main.
def self.absorbed_into_main?( branch:, runtime: )
	main = runtime.config.main_branch
	_, _, is_ancestor, = runtime.git_run( "merge-base", "--is-ancestor", branch, main )
	return true if is_ancestor

	merge_base_text, _, mb_success, = runtime.git_run( "merge-base", main, branch )
	return false unless mb_success
	merge_base = merge_base_text.to_s.strip
	return false if merge_base.empty?

	changed_text, _, changed_success, = runtime.git_run( "diff", "--name-only", merge_base, branch )
	return false unless changed_success
	changed_files = changed_text.to_s.strip.lines.map( &:strip ).reject( &:empty? )
	return true if changed_files.empty?

	_, _, identical, = runtime.git_run( "diff", "--quiet", branch, main, "--", *changed_files )
	identical
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ruby -Ilib -Itest test/branch_test.rb`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/carson/branch.rb test/branch_test.rb
git commit -m "feat: add Branch classification methods (stale, orphaned, absorbed)"
```

### Task 13: Wire Branch into callers

**Files:**
- Modify: `lib/carson/runtime.rb` — keep `current_branch` as thin delegate
- Modify: `lib/carson/runtime/deliver.rb`
- Modify: `lib/carson/runtime/local/prune.rb`

- [ ] **Step 1: Make current_branch delegate to Branch.current**

In `runtime.rb`, replace the `current_branch` method (lines 73-75) with:

```ruby
def current_branch
	branch = Branch.current( runtime: self )
	branch&.name || git_capture!( "rev-parse", "--abbrev-ref", "HEAD" ).strip
end
```

This preserves the existing string return type for all 14 callers. The callers don't need to change — they still get a string. The Branch object is available for callers that want it.

- [ ] **Step 2: Make branch_exists? delegate to Branch.exists?**

In `runtime.rb`, replace `branch_exists?` (lines 78-81) with:

```ruby
def branch_exists?( branch_name: )
	Branch.exists?( name: branch_name, runtime: self )
end
```

- [ ] **Step 3: Make prune.rb classification methods delegate**

In `prune.rb`, replace `stale_local_branches` (lines 205-215) with:

```ruby
def stale_local_branches
	Branch.stale( runtime: self ).map do |branch|
		upstream = git_capture!( "for-each-ref", "--format=%(upstream:short)\t%(upstream:track)", "refs/heads/#{branch.name}" ).strip
		upstream_name, track = upstream.split( "\t", 2 )
		{ branch: branch.name, upstream: upstream_name.to_s, track: track.to_s }
	end
end
```

Replace `orphan_local_branches` (lines 218-232):

```ruby
def orphan_local_branches( active_branch:, cwd_branch: nil )
	Branch.orphaned( active_branch: active_branch, cwd_branch: cwd_branch, runtime: self )
		.map( &:name )
end
```

Replace `absorbed_local_branches` (lines 237-255):

```ruby
def absorbed_local_branches( active_branch:, cwd_branch: nil )
	Branch.absorbed( active_branch: active_branch, cwd_branch: cwd_branch, runtime: self )
		.map do |branch|
		upstream = git_capture!( "for-each-ref", "--format=%(upstream:short)", "refs/heads/#{branch.name}" ).strip
		{ branch: branch.name, upstream: upstream }
	end
end
```

Replace `branch_absorbed_into_main?` (lines 258-281):

```ruby
def branch_absorbed_into_main?( branch: )
	Branch.absorbed_into_main?( branch: branch, runtime: self )
end
```

- [ ] **Step 4: Run prune tests**

Run: `ruby -Ilib -Itest test/runtime_prune_test.rb`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/carson/runtime.rb lib/carson/runtime/local/prune.rb
git commit -m "refactor: wire Branch into runtime and prune delegates"
```

---

## Chunk 4: Template Sync Regression

### Task 14: Add template_apply! to deliver before push

**Files:**
- Modify: `lib/carson/runtime/deliver.rb`

- [ ] **Step 1: Add template sync before push in deliver!**

In `deliver!`, after the main-branch guard and before the push step, add:

```ruby
# Step 0b: sync templates (the pre-push hook does this, but --no-verify skips it).
template_apply!( push_prep: true )
```

This ensures templates are synced before every deliver push, regardless of `--no-verify`.

- [ ] **Step 2: Run deliver tests**

Run: `ruby -Ilib -Itest test/runtime_deliver_test.rb`
Expected: All pass (template_apply! is a no-op when templates are in sync)

- [ ] **Step 3: Commit**

```bash
git add lib/carson/runtime/deliver.rb
git commit -m "fix: sync templates in deliver before push (--no-verify skips hook)"
```

### Task 15: Regression test — verify remote has canonical templates

**Files:**
- Modify: `test/runtime_deliver_test.rb`

- [ ] **Step 1: Write the regression test**

```ruby
def test_deliver_pushes_canonical_templates_to_remote
	runtime, repo_root = build_runtime( verbose: false )
	init_git_repo_with_remote( repo_root )
	create_feature_branch( repo_root, "fix/template-drift" )

	# Write a drifted template.
	github_dir = File.join( repo_root, ".github" )
	FileUtils.mkdir_p( github_dir )
	File.write( File.join( github_dir, "carson.md" ), "stale content\n" )
	system( "git", "-C", repo_root, "add", ".github/carson.md", out: File::NULL, err: File::NULL )
	system( "git", "-C", repo_root, "commit", "-m", "add drifted template", out: File::NULL, err: File::NULL )

	# Act: deliver.
	runtime.deliver!( merge: false )

	# Assert: the remote branch has canonical content.
	remote_content, status = Open3.capture2(
		"git", "-C", @remote_path,
		"show", "fix/template-drift:.github/carson.md"
	)
	# The canonical template is what template_apply! would write.
	# If template sources exist, the remote copy must not be "stale content".
	refute_equal "stale content\n", remote_content.to_s,
		"remote branch must have canonical .github/carson.md — --no-verify must not skip template sync"

	destroy_runtime_repo( repo_root: repo_root )
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `ruby -Ilib -Itest test/runtime_deliver_test.rb -n test_deliver_pushes_canonical_templates_to_remote`
Expected: PASS (because we added template_apply! in Task 14)

- [ ] **Step 3: Run full test suite**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add test/runtime_deliver_test.rb
git commit -m "test: regression — verify remote gets canonical templates via deliver"
```

### Task 16: Final delivery

- [ ] **Step 1: Run full test suite one final time**

Run: `ruby -Ilib -Itest -e "Dir.glob('test/**/*_test.rb').each { |f| require File.expand_path(f) }"`
Expected: All tests pass

- [ ] **Step 2: Deliver**

Run: `carson deliver`
