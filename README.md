# Carson ⧓

Named after the butler of Downton Abbey, Carson keeps order among the coding agents working in one repository.

Several agents in one repository, each on its own task, need one discipline: every task starts from the latest `main`, is done in a worktree of its own, and reaches `main` only when it is finished, so `main` only ever moves forward. Carson is that discipline as six commands. The agents bring the intelligence; Carson brings the order.

Carson was built in real work, with more than ten agents across many projects at once. Version 5 is a rewrite in Go, shaped by the 162 distinct failures catalogued from the version before it.

## The Problem

Plain git leaves too much to habit when agents share a repository. Tasks start from stale bases and waste their work in conflicts. Commits land on `main` by whatever route an agent finds, or are made on it directly. One agent removes another's worktree because it looked finished, or lands another session's branch. Old worktrees linger until nobody knows which work is live.

## How a task goes

```
carson start dark-mode    a worktree and branch of its own, from the latest main, owned by this session
      │
      │   the agent works and commits in ~/.worktrees/<repository>/dark-mode
      ▼
carson land dark-mode     checked with bin/check, fast-forwarded onto main, pushed to GitHub
      │
      ▼
carson remove dark-mode   worktree and branch removed; ignored files kept

carson abandon dark-mode  instead of landing: the work kept on abandoned/dark-mode
carson adopt dark-mode    take up abandoned work, or the task of an agent that has ended
carson status             main, the main working tree, every task and whose it is
```

## Principles

- **`main` only moves forward.** A task reaches it only by landing: brought up to the latest `main`, checked, fast-forwarded and pushed.
- **One task, one worktree.** The main working tree holds `main` and nothing else.
- **Only a task's owner lands, removes or abandons it.** Ownership is recorded when a task starts, and whether its owner is still running is always shown. An ended agent's task is adopted openly, never taken by guess.
- **Nothing is destroyed.** Every check comes before any change; ignored files and abandoned work are kept.
- **Carson runs only when called,** and keeps no state beyond one owner record per worktree.
- **Every message says what happened and what to do next,** and "unknown" when Carson cannot tell. Each line Carson writes starts with ⧓, so its words stand out in an agent's conversation.

## Quickstart

Download the build for your system — macOS or Linux, arm64 or amd64 — from the [releases](https://github.com/wanghailei/carson/releases), unpack it, and put `carson` on your PATH, for example in `~/.local/bin`. Carson needs `git`; a GitHub remote and a `bin/check` in the repository are used when they are there.

```
$ carson start dark-mode
⧓ Started dark-mode from local main at 4d4d3e0 in ~/.worktrees/code/notes/dark-mode, owned by Claude session 4e7a91d2-b1c0 on studio.

$ cd ~/.worktrees/code/notes/dark-mode      # work, test, commit

$ carson land dark-mode
⧓ Landed dark-mode on main by fast-forward at 5dbc817 (1 commit) and pushed; GitHub's main is 5dbc817. Checks: bin/check passed. Remove it with: carson remove dark-mode (from outside its worktree).

$ cd ~/code/notes && carson remove dark-mode
⧓ Removed dark-mode: its worktree at ~/.worktrees/code/notes/dark-mode, and its branch, landed on main at 5dbc817. It was owned by Claude session 4e7a91d2-b1c0 on studio.
```

## Commands

| Command | Does |
|---|---|
| `carson start <task>` | Starts a task from the latest `main`, in its own worktree, owned by the session running it. |
| `carson status` | Shows `main` against GitHub's, the main working tree, every task with its owner, and abandoned work. Changes nothing. |
| `carson land <task>` | Lands a finished task on `main`, checked and pushed. Runs from anywhere in the repository. |
| `carson remove <task>` | Removes a landed task's worktree and branch. Runs from outside the worktree. |
| `carson abandon <task>` | Keeps an unfinished task's work, uncommitted files committed, on `abandoned/<task>`, and removes its worktree. |
| `carson adopt <task>` | Makes a task yours: abandoned work, a branch left without a worktree, or the task of an agent that has ended. |
| `carson --version` | Says which version this is. |

Exit codes: 0 done, as reported; 1 could not finish, and the message says what state things are left in; 2 refused.

## Building from source

Go comes from [mise](https://mise.jdx.dev), pinned in `mise.toml`:

    mise install
    mise exec -- go build ./cmd/carson

`bin/check` runs the formatting check, vet and the tests, which work on real git repositories in temporary folders; `carson land` runs it before a task lands.

## Releasing

With the version set in `internal/carson/carson.go` and its notes in `docs/release-<version>.md`, both landed on `main`, run `bin/release <version>` from the main working tree (`--dry-run` first). It builds the four downloads, tags `v<version>`, and publishes the GitHub release with their checksums.

## Licence

MIT; see `LICENSE`.

## History

Carson 4 was a Ruby gem that governed repositories through hooks and pull requests. It is kept at the tag `ruby-final`.
