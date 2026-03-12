# Carson 4.0

This document captures concrete Carson 4.0 behaviour changes that tighten repository governance. The first 4.0 contract is worktree-first governance.

## 4.0 worktree-first governance

### Objective

Keep substantive work off `main` in Carson-governed repositories, and require Carson-owned mechanisms for worktree and delivery operations.

### Scope

This spec applies only when the current working directory is inside a Carson-governed repository.

A repository is governed when:
- the current working directory resolves to a git repository root
- that root is registered in Carson governance config

If either check fails, this spec does not apply.

### Responsibility split

- The agent decides when a task leaves read-only mode.
- Carson creates and removes worktrees.
- Carson governs delivery operations.
- Platform adapters and hooks trigger Carson at the correct moment.
- Carson does not decide when code is ready to commit.

### Agent instruction contract

Shared agent instructions for governed repositories must state:
- before the first substantive action, create a worktree with `carson worktree create <name>`
- never begin substantive work on `main`
- never use raw `git worktree add` in a governed repository

### Substantive action

Substantive action includes:
- file edits or file writes
- Edit or Write tool calls
- code generation that writes files
- `git add`
- `git commit`
- `git push`
- `gh pr create`
- `gh pr merge`
- `carson deliver`
- any other mutating repository command

Read-only inspection remains allowed on `main`, including:
- `git status`
- `git diff`
- `git log`
- `gh pr view`
- `gh pr list`
- `gh pr checks`
- `carson sync`

### Rule 1: worktree-first

If all of the following are true, substantive work must not proceed:
- the repository is governed
- the current working directory is the main working tree
- the current branch is `main` or `master`
- the requested action is substantive

Minimum required behaviour:
- block the action
- instruct the caller to create a worktree first

Preferred behaviour:
- auto-run `carson worktree create <name>`
- switch into the returned worktree
- continue the requested action there

Required block message:

`This repo is Carson-governed. Do not work on main. Create a worktree first: carson worktree create <name>.`

### Rule 2: Carson owns worktree operations

In governed repositories, the following raw commands are forbidden:
- `git worktree add`
- `git worktree remove`

Required replacements:
- `carson worktree create <name>`
- `carson worktree remove <name>`

Required block message:

`This repo is Carson-governed. Use Carson worktrees: carson worktree create <name>.`

### Rule 3: Carson owns delivery operations

In governed repositories, the following raw commands are forbidden:
- `git push`
- `gh pr create`
- `gh pr merge`
- `git pull --rebase`

Required replacements:
- `carson deliver`
- `carson sync`

Required block messages:

- `This repo is Carson-governed. Use Carson for delivery: carson deliver.`
- `This repo is Carson-governed. Sync with: carson sync.`

### Rule 4: Carson backstop

`carson deliver` must refuse to run from the main working tree on `main` or `master`.

`carson deliver` must instruct the caller to create a worktree first.

`carson worktree create` is allowed from the main working tree.

`carson sync` is allowed from the main working tree.

### Rule 5: deliver contract

Carson must document whether `carson deliver`:
- requires an existing commit and then handles push, PR creation, and merge
- or accepts staged changes, creates the commit, and then handles push, PR creation, and merge

This behaviour must be explicit and stable.

### Evaluation order

For every intercepted action:

1. Detect whether the repository is governed.
2. If it is not governed, allow normal behaviour.
3. Classify the action as read-only or substantive.
4. If it is read-only, allow it.
5. If it is substantive on the main working tree on `main` or `master`, trigger Rule 1.
6. Otherwise, if it is a raw Carson-owned worktree or delivery operation, trigger Rule 2 or Rule 3.
7. Otherwise, allow it.

### Acceptance tests

Must block:
- editing a file on `main` in a governed repository
- `git add .` on `main` in a governed repository
- `git commit -m ...` on `main` in a governed repository
- `carson deliver` on `main` in a governed repository
- `git worktree add` anywhere in a governed repository
- `git worktree remove` anywhere in a governed repository
- `git push` anywhere in a governed repository
- `gh pr create` anywhere in a governed repository
- `gh pr merge` anywhere in a governed repository

Must allow:
- `carson worktree create <name>` from the main working tree
- editing inside a non-main worktree
- `carson deliver` inside a non-main worktree
- `carson sync` on the main working tree
- read-only inspection on the main working tree

### Platform layer

Claude hooks, Codex execpolicy, and similar guards are optional early-warning layers.

Safety must still hold if a platform hook is absent.

The authoritative model is Carson-governed worktree-first behaviour plus Carson-owned delivery operations.
