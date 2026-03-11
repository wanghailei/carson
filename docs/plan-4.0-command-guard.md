# Carson 4.0 — Total Command Governance

Carson becomes the sole interface for all mutating git and GitHub operations in governed repositories. Agents observe; Carson acts.

---

## Part 1: The Good Parts of Git and GH

A complete classification of every git and gh command by mutation risk, and a gap analysis of Carson's current coverage.

### Strategy

1. **Ban all mutating git/gh commands** for coding agents in governed repositories. This builds a safe baseline.
2. **Carson provides safe versions** of every mutating operation agents legitimately need — safe by nature, with strategy and guards.
3. **Force all agents to delegate** upward (push, PR, merge, release) and downward (staging, branching, rebasing) mutating work to Carson.

Carson represents security and strategy. Agents represent creativity and implementation. The boundary is: agents read and write files; Carson moves code through the pipeline.

### Enforcement model

**Allowlist, not blocklist.** The command guard permits a short list of read-only git/gh commands. Everything not on the list is blocked with a redirect message naming the Carson equivalent. Fail-closed — new commands, aliases, creative invocations are all blocked by default.

---

### 1.1 Git Commands — Full Classification

#### Read-only (safe — the allowlist)

| Command | Purpose |
|---|---|
| `git status` | Working tree state |
| `git log` | Commit history |
| `git diff` | Show changes |
| `git show` | Show objects |
| `git blame` / `git annotate` | Line-level authorship |
| `git grep` | Search content |
| `git branch` (no flags, or `--list`) | List branches |
| `git branch --show-current` | Current branch name |
| `git tag` (no args, or `-l`) | List tags |
| `git worktree list` | List worktrees |
| `git rev-parse` | Parse revisions/paths |
| `git ls-files` | List tracked files |
| `git ls-tree` | List tree contents |
| `git remote -v` / `git remote show` | Inspect remotes |
| `git config --get` / `--list` | Read config |
| `git describe` | Human-readable object names |
| `git range-diff` | Compare commit ranges |
| `git shortlog` | Summarise log |
| `git show-branch` | Show branches and commits |
| `git verify-commit` / `git verify-tag` | GPG verification |
| `git version` / `git help` | Meta |
| `git cat-file` | Inspect objects |
| `git cherry` | Find unapplied commits |
| `git diff-files` / `git diff-index` / `git diff-tree` | Low-level diffs |
| `git for-each-ref` | Iterate refs |
| `git fsck` | Verify database |
| `git merge-base` | Common ancestor |
| `git name-rev` / `git rev-list` | Revision info |
| `git reflog show` | View reflog |
| `git count-objects` | Object stats |
| `git whatchanged` | Logs with diffs |
| `git check-attr` / `check-ignore` / `check-ref-format` | Attribute/ignore queries |
| `git merge-tree` | Dry-run merge (no index/worktree mutation) |

#### Mutating (blocked — everything else)

| Command | Category | Carson equivalent |
|---|---|---|
| `git add` | Staging | `carson deliver` (internal) |
| `git commit` | Recording | `carson deliver` |
| `git push` | Remote sync | `carson deliver` |
| `git pull` / `git fetch` | Remote sync | `carson sync` |
| `git merge` | Integration | `carson deliver --merge` |
| `git rebase` | Integration | **GAP — needs `carson rebase`** |
| `git checkout` / `git switch` | Branch switching | `carson worktree create` (use worktrees, not switching) |
| `git branch -d/-D/-m/-c` | Branch mutation | `carson prune` / `carson housekeep` |
| `git worktree add` | Worktree creation | `carson worktree create` |
| `git worktree remove` | Worktree removal | `carson worktree remove` |
| `git cherry-pick` | Commit application | **GAP** |
| `git revert` | Rollback | **GAP — needs `carson revert`** |
| `git reset` | HEAD manipulation | **BANNED** (destructive) |
| `git restore` | File restoration | **GAP** |
| `git stash` | Temp storage | **BANNED** (use worktrees) |
| `git clean` | File destruction | **BANNED** (destructive) |
| `git rm` / `git mv` | File manipulation | **GAP** |
| `git tag` (create/delete) | Tagging | **GAP — needs `carson tag`** |
| `git notes` | Annotation | Rarely needed |
| `git remote add/remove/rename` | Remote config | **GAP** |
| `git config --set/--unset` | Config mutation | **BANNED for agents** |
| `git submodule` | Submodule mgmt | Rarely needed |
| `git am` / `git apply` | Patch application | Rarely needed |
| `git filter-branch` | History rewrite | **BANNED** |
| `git reflog delete/expire` | Reflog mutation | **BANNED** |
| `git init` / `git clone` | Repo creation | Out of scope |
| `git gc` / `git prune` / `git repack` / `git pack-refs` | Maintenance | `carson housekeep` |
| `git sparse-checkout` | Worktree reduction | Rarely needed |

---

### 1.2 GH Commands — Full Classification

#### Read-only (safe — the allowlist)

| Command | Purpose |
|---|---|
| `gh pr list` | List PRs |
| `gh pr view` | View PR details |
| `gh pr checks` | CI status |
| `gh pr diff` | View PR diff |
| `gh pr status` | Relevant PR status |
| `gh issue list` | List issues |
| `gh issue view` | View issue details |
| `gh issue status` | Relevant issue status |
| `gh repo view` | View repo details |
| `gh repo list` | List repos |
| `gh run list` | List workflow runs |
| `gh run view` | View run details |
| `gh run watch` | Watch a run |
| `gh workflow list` | List workflows |
| `gh workflow view` | View workflow |
| `gh release list` | List releases |
| `gh release view` | View release |
| `gh release download` | Download assets |
| `gh label list` | List labels |
| `gh search *` | All search subcommands |
| `gh status` | Cross-repo activity |
| `gh browse` | Open in browser |
| `gh ruleset list/view/check` | View rulesets |
| `gh api` (GET) | Read-only API calls |
| `gh auth status` / `gh auth token` | Auth inspection |
| `gh config get` / `gh config list` | Config inspection |
| `gh attestation *` | Verify attestations |
| `gh project list` / `gh project view` / `gh project field-list` / `gh project item-list` | Read project data |
| `gh variable get` / `gh variable list` | Read variables |
| `gh secret list` | List secrets (not values) |
| `gh cache list` | List caches |
| `gh ssh-key list` / `gh gpg-key list` | List keys |
| `gh repo gitignore list/view` / `gh repo license list/view` | View templates |
| `gh codespace list` / `gh codespace view` | List codespaces |

#### Mutating (blocked — everything else)

| Command | Category | Carson equivalent |
|---|---|---|
| `gh pr create` | PR creation | `carson deliver` |
| `gh pr merge` | PR merge | `carson deliver --merge` |
| `gh pr close` / `gh pr reopen` | PR lifecycle | **GAP** |
| `gh pr edit` | PR modification | **GAP** |
| `gh pr comment` | PR commenting | **GAP — needs `carson comment`** |
| `gh pr review` | PR review | `carson review` (partially) |
| `gh pr checkout` | Branch switching | **Block** (use worktrees) |
| `gh pr lock/unlock` | Conversation control | **GAP** |
| `gh pr ready` | Draft→ready | **GAP** |
| `gh pr revert` | PR revert | **GAP** |
| `gh pr update-branch` | Branch update | **GAP** |
| `gh issue create` | Issue creation | **GAP — needs `carson issue`** |
| `gh issue close` / `gh issue reopen` | Issue lifecycle | **GAP** |
| `gh issue edit` | Issue modification | **GAP** |
| `gh issue comment` | Issue commenting | **GAP** |
| `gh issue delete` | Issue deletion | **GAP** |
| `gh issue pin/unpin` | Issue pinning | **GAP** |
| `gh issue transfer` | Issue transfer | **GAP** |
| `gh issue lock/unlock` | Conversation control | **GAP** |
| `gh issue develop` | Link branches | **GAP** |
| `gh release create` | Release creation | **GAP — needs `carson release`** |
| `gh release edit/delete` | Release mgmt | **GAP** |
| `gh repo create/delete/edit/fork/rename` | Repo mgmt | **Out of scope** |
| `gh label create/edit/delete` | Label mgmt | **GAP** |
| `gh run cancel/delete/rerun` | Run mgmt | Rarely needed |
| `gh workflow enable/disable/run` | Workflow mgmt | Rarely needed |
| `gh secret set/delete` | Secret mgmt | **BANNED for agents** |
| `gh variable set/delete` | Variable mgmt | **BANNED for agents** |
| `gh api` (POST/PUT/PATCH/DELETE) | Mutating API | **GAP** |
| `gh config set` | Config mutation | **BANNED for agents** |
| `gh cache delete` | Cache mgmt | Rarely needed |
| `gh project create/edit/delete/close/...` | Project mgmt | Out of scope |
| `gh ssh-key/gpg-key add/delete` | Key mgmt | **BANNED for agents** |
| `gh auth login/logout/refresh` | Auth mutation | **BANNED for agents** |

---

### 1.3 Carson Coverage Today (v3.x)

| Carson command | Git/GH operations replaced | Status |
|---|---|---|
| `carson deliver` | `git add` + `git commit` + `git push` + `gh pr create` + `gh pr merge` | **Covered** |
| `carson worktree create` | `git worktree add` (with main sync) | **Covered** |
| `carson worktree remove` | `git worktree remove` (with safety checks) | **Covered** |
| `carson sync` | `git fetch` + fast-forward main | **Covered** |
| `carson prune` | `git branch -d` + remote prune + orphan cleanup | **Covered** |
| `carson housekeep` | sync + worktree reap + prune | **Covered** |
| `carson audit` | Health checks | **Covered** |
| `carson status` | `git status` + `gh pr list` + branch overview | **Covered** |
| `carson review gate` | PR merge-readiness check | **Covered** |
| `carson review sweep` | Review thread resolution | **Covered** |

### 1.4 The Gap — What Carson 4.0 Must Add

Operations agents legitimately need that Carson does not yet cover.

| Priority | Operation | Proposed Carson command | Why agents need it |
|---|---|---|---|
| **P0** | Rebase onto updated main | `carson rebase` | Rebase obligation after every merge to main |
| **P0** | Create issues | `carson issue create` | Agents create backlog items, violation issues, learning events |
| **P0** | Comment on PRs/issues | `carson comment` | Review dispositions, discussion |
| **P1** | Close/reopen PRs | `carson pr close/reopen` | PR lifecycle management |
| **P1** | Edit PRs | `carson pr edit` | Update title/body/labels |
| **P1** | Close/reopen issues | `carson issue close/reopen` | Issue lifecycle |
| **P1** | Edit issues | `carson issue edit` | Update labels, assignees, body |
| **P1** | Mark PR ready | `carson pr ready` | Draft→ready transition |
| **P1** | Create labels | `carson label create` | Repository setup |
| **P2** | Create tags/releases | `carson release` | Delivery workflow |
| **P2** | Revert a PR/commit | `carson revert` | Emergency rollback |
| **P2** | Mutating API calls | `carson api` (proxy with guards) | Edge cases |

#### Not needed (ban outright, no Carson equivalent)

- `git stash`, `git clean`, `git reset --hard`, `git filter-branch` — destructive, already banned.
- `git config --set` — agents must not mutate git config.
- `gh secret/variable set/delete` — agents must never touch secrets.
- `gh auth login/logout` — agents must not mutate auth state.
- `gh repo create/delete/fork` — agents must not create/destroy repositories.
- `gh ssh-key/gpg-key add/delete` — agents must never touch keys.
- `gh config set` — agents must not mutate gh config.

---

## Part 2: Solution Design

_To be added._

## Part 3: Implementation Todos

_To be added._
