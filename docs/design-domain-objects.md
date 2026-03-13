# Design: Core Git Domain Objects

Approved 2026-03-11. Tracks issue #246.

## Problem

`Carson::Runtime` is a god object. It includes ~10 modules that share `@repo_root`, `@config`, `@git_adapter`, `@github_adapter` — 30 domain concepts, only 5 extracted as objects. Noun-prefix methods (`create_pr!`, `find_existing_pr`, `push_branch!`) are symptoms of missing domain objects. The methods operate on implicit state that should belong to first-class objects.

## Blueprint

`Carson::Worktree` is the one correctly extracted domain object. The extraction follows its pattern:

- **Class-side:** factory methods and lookups (`create!`, `remove!`, `list`, `find`)
- **Instance-side:** state and actions (`@path`, `@branch`)
- **Infrastructure:** `runtime` passed as dependency — the object uses `runtime.git_run`, `runtime.gh_run`, `runtime.config` without owning them

## Extraction: Remote, PullRequest, Branch

Sequence: Remote first (unblocks owner/repo for PullRequest API calls), PullRequest second (depends on Remote), Branch third (independent).

### Carson::Remote

Wraps `repository_coordinates` (currently in review/data_access.rb:226, consumed by review, audit, govern, and prune) and push operations.

```ruby
class Carson::Remote
  class Error < StandardError
    attr_reader :recovery

    def initialize( message, recovery: nil )
      super( message )
      @recovery = recovery
    end
  end

  attr_reader :name, :owner, :repo

  def initialize( name:, runtime: )
    # Parses git remote get-url <name> into owner/repo.
  end

  def push!( branch: )
    # Returns self. Raises Remote::Error on failure.
  end

  def force_push_with_lease!( branch: )
    # Returns self. Raises Remote::Error on failure.
  end
end
```

**Replaces:**

| Method | Current location |
|--------|-----------------|
| `repository_coordinates` | review/data_access.rb:226 |
| `push_branch!` | deliver.rb:140 |
| `force_push_with_lease!` | deliver.rb:161 |

### Carson::PullRequest

Lifecycle only (deliver.rb + gate_support.rb) and evidence lookup (prune.rb). Govern/status portfolio-level PR consumers stay as-is — second pass.

```ruby
class Carson::PullRequest
  class Error < StandardError
    attr_reader :recovery

    def initialize( message, recovery: nil )
      super( message )
      @recovery = recovery
    end
  end

  attr_reader :number, :url, :state

  # --- Class methods: factories and lookups ---

  def self.find_open( branch:, runtime: )
    # Returns instance or nil. gh pr view --json number,url,state, gate on OPEN.
  end

  def self.create!( branch:, title:, body_file:, runtime: )
    # Returns instance. Raises PullRequest::Error on failure.
  end

  def self.for_branch( branch:, runtime: )
    # Returns instance or nil. Used by gate_support.
  end

  def self.merged_for_branch( branch:, branch_tip_sha:, runtime: )
    # Returns instance or nil. Paginated REST API. Used by prune, housekeep.
  end

  def self.open_for_branch?( branch:, runtime: )
    # Returns boolean. Fast path per_page=1. Used by prune.
  end

  # --- Instance methods: actions on an existing PR ---

  def merge!( method: )
    # Returns self. Raises PullRequest::Error on failure.
  end

  def ci_status
    # Returns :pass, :fail, :pending, or :none.
  end

  def review_decision
    # Returns :approved, :changes_requested, :review_required, or :none.
  end
end
```

**Replaces:**

| Method | Current location |
|--------|-----------------|
| `find_existing_pr` | deliver.rb:198 |
| `create_pr!` | deliver.rb:214 |
| `merge_pr!` | deliver.rb:290 |
| `check_pr_ci` | deliver.rb:251 |
| `check_pr_review` | deliver.rb:269 |
| `current_pull_request_for_branch` | gate_support.rb:54 |
| `merged_pr_for_branch` | prune.rb:435 |
| `branch_has_open_pr?` | prune.rb:320 |

**Not in scope (second pass):**

| Method | Location | Reason |
|--------|----------|--------|
| `list_open_prs` | govern.rb:136 | Portfolio triage, different field set |
| `gather_pr_info` | status.rb:175 | Status reporting, different field set |
| `pull_request_details` | review/data_access.rb:8 | GraphQL pagination, review concern |
| `recent_pull_requests_for_sweep` | review/data_access.rb:149 | Review sweep, time-filtered bulk fetch |

### Carson::Branch

Branch identity and classification. `cwd_worktree_branch` stays in local/worktree.rb — it's a worktree-CWD safety mechanism, not a branch identity concept.

```ruby
class Carson::Branch
  attr_reader :name

  def self.current( runtime: )
    # Returns instance or nil (nil for detached HEAD).
  end

  def self.exists?( name:, runtime: )
    # Returns boolean.
  end

  def self.stale( runtime: )
    # Returns array of Branch instances. Gone upstream.
  end

  def self.orphaned( runtime: )
    # Returns array of Branch instances. No upstream, not main.
  end

  def self.absorbed( runtime: )
    # Returns array of Branch instances. Fully merged into main.
  end
end
```

**Replaces:**

| Method | Current location |
|--------|-----------------|
| `current_branch` | runtime.rb:72 |
| `branch_exists?` | runtime.rb:78 |
| `stale_local_branches` | prune.rb |
| `orphan_local_branches` | prune.rb |
| `absorbed_local_branches` | prune.rb |

**Stays where it is:**

| Method | Location | Reason |
|--------|----------|--------|
| `cwd_worktree_branch` | local/worktree.rb:33 | Worktree-CWD safety guard, not branch identity |

## Error contract

Domain objects raise on failure, return domain values on success. Runtime delegates catch and translate to exit codes + result hashes.

| Outcome | Domain object | Runtime delegate |
|---------|---------------|-----------------|
| Success | Returns self/instance | Maps to `EXIT_OK` |
| Absence | Returns nil | Checks nil, sets `result[:error]` |
| Failure | Raises `Error` with message + recovery | Catches, maps to `EXIT_ERROR`/`EXIT_BLOCK` |

Factory/lookup methods return nil for "not found" — absence is a normal result, not an error. Action methods (`merge!`, `push!`, `create!`) raise `Error` on failure.

## Wiring pattern

Runtime modules become thin delegates. Example for deliver:

```ruby
module Deliver
  def deliver!( merge: false, title: nil, body_file: nil, json_output: false )
    branch = Branch.current( runtime: self )
    remote = Remote.new( name: config.git_remote, runtime: self )
    result = { command: "deliver", branch: branch.name }

    # Step 1: push
    begin
      remote.push!( branch: branch.name )
    rescue Remote::Error => e
      if e.message.include?( "non-fast-forward" )
        begin
          remote.force_push_with_lease!( branch: branch.name )
        rescue Remote::Error => e2
          result[ :error ] = e2.message
          result[ :recovery ] = e2.recovery
          return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
        end
      else
        result[ :error ] = e.message
        result[ :recovery ] = e.recovery
        return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
      end
    end

    # Step 2: find or create PR
    pr = PullRequest.find_open( branch: branch.name, runtime: self )
    unless pr
      begin
        pr = PullRequest.create!( branch: branch.name, title: title, body_file: body_file, runtime: self )
      rescue PullRequest::Error => e
        result[ :error ] = e.message
        result[ :recovery ] = e.recovery
        return deliver_finish( result: result, exit_code: EXIT_ERROR, json_output: json_output )
      end
    end

    result[ :pr_number ] = pr.number
    result[ :pr_url ] = pr.url
    # ... CI check via pr.ci_status
    # ... review gate via pr.review_decision
    # ... merge via pr.merge!( method: config.govern_merge_method )
  end
end
```

## Regression test: template sync through --no-verify

`carson deliver` uses `--no-verify` to bypass the pre-push hook. The pre-push hook runs `carson template apply --push-prep` (template.rb:96, hook line 56). With `--no-verify`, templates are never synced on push.

The fix: call `template_apply!( push_prep: true )` inside deliver before the push step. The regression test must verify the **remote** branch has canonical content — not the local working tree.

```ruby
def test_deliver_pushes_canonical_templates_to_remote
  # Setup: repo with drifted .github/carson.md on a feature branch.
  # Act: deliver!
  # Assert: git show on the bare remote (@remote_path) has canonical content.
  remote_content, = Open3.capture2(
    "git", "-C", @remote_path,
    "show", "fix/template-drift:.github/carson.md"
  )
  assert_equal canonical_content, normalize_text( text: remote_content ),
    "remote branch must have canonical .github/carson.md"
end
```

This catches all failure modes: `template_apply!` never ran, push preceded sync commit, or force-push lost the sync commit.

## What stays on Runtime

- `deliver!` orchestration (7-step flow with exit codes and result hashing)
- `deliver_finish` / `print_deliver_human` (CLI output formatting)
- `cwd_worktree_branch` (worktree-CWD safety)
- Govern/status PR list calls (portfolio-level, second pass)
- Review graph pagination (second concern, second swing)
- `default_pr_title` (trivial helper, moves to PullRequest if convenient)
