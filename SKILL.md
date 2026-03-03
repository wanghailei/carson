# Carson Skill

You are working in a repository governed by Carson — a deterministic governance runtime. Carson handles git hooks, lint enforcement, PR triage, agent dispatch, merge, and cleanup. You provide the intelligence; Carson provides the infrastructure.

## When to use Carson commands

| User intent | Command | What happens |
|---|---|---|
| "Check if my code is ready" | `carson audit` | Lint, scope, boundary checks. Exit 0 = clean. Exit 2 = policy block. |
| "Is my PR mergeable?" | `carson review gate` | Polls for unresolved review threads and actionable comments. Blocks until resolved. |
| "What's happening across my repos?" | `carson govern --dry-run` | Classifies every open PR without taking action. Read the summary. |
| "Run governance continuously" | `carson govern --loop 300` | Triage-dispatch-merge cycle every 300 seconds. Ctrl-C to stop. |
| "Merge ready PRs and dispatch fixes" | `carson govern` | Full autonomous cycle: merge, dispatch agents, escalate, housekeep. |
| "Set up Carson for a repo" | `carson onboard /path/to/repo` | Installs hooks, syncs templates, runs first audit. |
| "Refresh after upgrading Carson" | `carson refresh` | Re-applies hooks and templates for the current version. |
| "Update my local main" | `carson sync` | Fast-forward local main from remote. Blocks if tree is dirty. |
| "Clean up stale branches" | `carson prune` | Removes local branches whose upstream is gone. |
| "Check template drift" | `carson template check` then `carson template apply` | Detect and fix .github/* drift. |
| "Remove Carson from a repo" | `carson offboard /path/to/repo` | Removes hooks and managed files. |
| "What version?" | `carson version` | Prints installed version with ⧓ badge. |
| "Verify hook installation" | `carson inspect` | Checks hooks path, file existence, permissions. |

## Exit codes

- `0` — success, all clear.
- `1` — runtime or configuration error. Read the error message.
- `2` — policy block. Something must be fixed before proceeding (lint violation, unresolved review, boundary breach).

When you see exit 2, do NOT bypass it. Read the output, fix the root cause, and re-run.

## Interpreting audit output

Carson audit output is structured as labelled key-value lines prefixed with ⧓. Key sections:

- **Working Tree** — staged/unstaged status.
- **Main Sync Status** — whether local main matches remote. If ahead, reset drift before committing.
- **Scope Integrity Guard** — checks that commits stay within a single business intent and scope group.
- **Audit Result** — final verdict: `status: ok` (clean), `status: attention` (advisory, not blocking), `status: block` (must fix).

## Interpreting govern output

`carson govern --dry-run` classifies each PR:

- **ready** → would merge. All gates pass.
- **ci_failing** → would dispatch agent to fix CI.
- **review_blocked** → would dispatch agent to address review comments.
- **pending** → skip. Checks still running (within check_wait window).
- **needs_attention** → escalate. Needs human judgement.

The summary line: `govern_summary: repos=N prs=N ready=N blocked=N`

## Configuration

Single config file: `~/.carson/config.json`. Key settings:

```json
{
  "govern": {
    "repos": ["~/Dev/repo-a", "~/Dev/repo-b"],
    "merge": { "method": "rebase" },
    "agent": { "provider": "auto" }
  },
  "review": {
    "bot_usernames": ["gemini-code-assist"]
  }
}
```

- `govern.merge.method` — must match GitHub branch protection. Use `rebase` if linear history is required.
- `govern.repos` — list of repo paths for portfolio-level governance. Empty = current repo only.
- `govern.agent.provider` — `auto` (tries codex then claude), `codex`, or `claude`.
- `review.bot_usernames` — bot logins to ignore in review gate. Use GraphQL login format (no `[bot]` suffix).

Environment overrides take precedence over config file. Common ones:
- `CARSON_GOVERN_MERGE_METHOD`
- `CARSON_REVIEW_BOT_USERNAMES`
- `CARSON_GOVERN_CHECK_WAIT`

## Common scenarios

**Commit blocked by audit:**
Run `carson audit`, read the block reason, fix it, then `git add` and `git commit` again. Do not skip the hook.

**Review gate blocked:**
Run `carson review gate` to see which comments need disposition. Respond to each with the required prefix (default: `Disposition:`), then re-run.

**Local main drifted ahead of remote:**
This means a commit was made to main that couldn't be pushed (branch protection). Reset: `git checkout main && git reset --hard github/main`.

**Hooks out of date after upgrade:**
Run `carson prepare` to write new hook versions, then `carson inspect` to verify.

**Govern merge fails:**
Check that `govern.merge.method` in config matches what GitHub allows. If the repo enforces linear history, only `rebase` works.

## Boundaries

- Carson never lives inside governed repositories. No `.carson.yml`, no `bin/carson`, no `.tools/carson/`.
- Carson-managed files in repos are limited to `.github/*` templates.
- Carson's hooks live at `~/.carson/hooks/<version>/`, never in `.git/hooks/`.
- Lint policy is distributed via `carson lint policy --source <policy-repo>` into each repo's `.github/linters/`.
