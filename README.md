# Carson

Carson is the git tool for the master's agents. Each task starts from the latest `main`, in a worktree of its own, and reaches `main` only as a finished task landing by fast-forward, so `main` only ever moves forward. Carson keeps no state of its own beyond one owner record per worktree, runs only when called, and says what it observed, "unknown" when it cannot tell.

## Commands

| Command | What it does |
|---|---|
| `carson start <task>` | Starts a task from the latest `main`, in its own worktree under `~/.worktrees`, owned by the session that runs it. |
| `carson status` | Shows `main` against GitHub's, the main working tree, and every task with its owner. Changes nothing. |
| `carson merge` | Merges the task you are in into `main`: rebased onto the latest `main`, checked with `bin/check` if the repository has one, fast-forwarded, and pushed. |
| `carson remove <task>` | Removes a task's worktree and branch. |

Exit codes: 0 done, as reported; 1 could not finish, and the message says the state things are left in; 2 refused, because a rule forbids it.

## State

Carson 5 is being written in Go. `status` and `start` are built; `merge` is in review; `remove` is not built yet. Its design is `~/Documents/AI/design.20260929.carson-and-git.md`.

## Building and testing

Go comes from mise, pinned in `mise.toml`.

    mise install
    mise exec -- go test ./...
    mise exec -- go build ./cmd/carson

The tests run against real git repositories in temporary folders.

## The Ruby Carson

Carson 4 was a Ruby gem. Its last version is kept at the tag `ruby-final`: `git checkout ruby-final`.
