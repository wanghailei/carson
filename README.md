# Carson

Carson is a git tool for coding agents that work in the same repositories at once. Each task starts from the latest `main`, in a worktree of its own, and reaches `main` only as a finished task landing by fast-forward, so `main` only ever moves forward. Carson keeps no state of its own beyond one owner record per worktree, runs only when called, and says what it observed, "unknown" when it cannot tell.

## Commands

| Command | What it does |
|---|---|
| `carson start <task>` | Starts a task from the latest `main`, in its own worktree under `~/.worktrees`, owned by the session that runs it. |
| `carson status` | Shows `main` against GitHub's, the main working tree, every task with its owner, and the branches of abandoned tasks. Changes nothing. |
| `carson land <task>` | Lands a finished task on `main`, run from anywhere in the repository: brought up to the latest `main`, checked with `bin/check` if the repository has one, fast-forwarded, and pushed. |
| `carson remove <task>` | Removes a landed task's worktree and branch, by its owner, from outside the worktree. Its ignored files are kept in `~/.cache/deleted`. |
| `carson abandon <task>` | Keeps what an unfinished task holds, uncommitted work committed, on a branch `abandoned/<task>`, and removes its worktree, from outside it. |
| `carson adopt <task>` | Makes a task yours: the task of an agent seen to have ended, in its worktree as it was left; or abandoned work, or a branch left without a worktree, in a new worktree. The adoption is recorded. |

Exit codes: 0 done, as reported; 1 could not finish, and the message says the state things are left in; 2 refused, because a rule forbids it.

## State

Carson 5 is written in Go, with its six commands built. Not built yet: the first task of a repository with no `main`.

## Installing

On macOS or Linux, with Homebrew:

    brew install wanghailei/tap/carson

Or download the build for your system from the [releases](https://github.com/wanghailei/carson/releases), unpack it, and put `carson` on your PATH. `carson --version` says which version you have; `brew upgrade carson` brings the latest.

## Building and testing

Go comes from mise, pinned in `mise.toml`.

    mise install
    mise exec -- go test ./...
    mise exec -- go build ./cmd/carson

`bin/check` runs the formatting check, vet and the tests; `carson land` runs it before a task lands.

The tests run against real git repositories in temporary folders.

## Releasing

Releasing any version is the master's decision. With the version set in `internal/carson/carson.go` and its notes in `docs/release-<version>.md`, both landed on `main`, run from the main working tree:

    bin/release <version> --dry-run
    bin/release <version>

It builds carson for macOS and Linux on arm64 and amd64, tags `v<version>`, publishes the GitHub release with the downloads and their checksums, and points the Homebrew formula in `wanghailei/homebrew-tap` at them.

## Licence

MIT; see `LICENSE`.

## The Ruby Carson

Carson 4 was a Ruby gem. Its last version is kept at the tag `ruby-final`: `git checkout ruby-final`.
