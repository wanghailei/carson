Carson 5 is a rewrite in Go of the git tool for coding agents that work in the same repositories at once. Each task starts from the latest `main` in a worktree of its own, and reaches `main` only as a finished task landing by fast-forward, so `main` only ever moves forward.

**Commands**

- `carson start <task>` starts a task from the latest `main`, in its own worktree under `~/.worktrees`, owned by the agent's session.
- `carson status` shows `main` against GitHub's, the main working tree, every task with its owner and whether that owner is still live, and abandoned work.
- `carson land <task>` lands a finished task: brought up to the latest `main`, checked with the repository's `bin/check`, fast-forwarded, and pushed.
- `carson remove <task>` removes a landed task's worktree and branch, keeping its ignored files.
- `carson abandon <task>` keeps an unfinished task's work, uncommitted files committed, on a branch `abandoned/<task>`, and removes its worktree.
- `carson adopt <task>` makes a task yours: an ended agent's task, abandoned work, or a branch left without a worktree.

**What it keeps to**

- It runs only when called and keeps no state of its own beyond one owner record per worktree.
- Every check comes before any change, and nothing is ever destroyed: ignored files and abandoned work are kept.
- Only a task's owner lands, removes or abandons it; an ended owner's task is adopted openly, never taken by guess.
- It says what it observed, "unknown" when it cannot tell, and what to do next.

**Install**

`brew install wanghailei/tap/carson`, or download the build for your system below.

Carson 4, the Ruby gem, is kept at the tag `ruby-final`.
