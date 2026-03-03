# Carson Govern — Autonomous Portfolio Governance

## Document Status
- Purpose: architecture and delivery record for `carson govern`.
- Scope: portfolio-level PR triage, merge, housekeep, and agent dispatch.

## Intent

Carson becomes the autonomous brain for a portfolio of repositories. It watches repos, triages PRs, dispatches coding agents to fix problems, merges when ready, and housekeeps — unmanned. The user only intervenes for genuine risk decisions.

## Principles

1. Deterministic gates over heuristic convenience.
2. Source-of-truth from GitHub/CI, not agent self-reports.
3. Provider-agnostic agent contract (Codex/Claude behind one interface).
4. Explainability (decision trace per PR).
5. Escalation as notification, not decision.
6. Outsider boundary preserved: Carson remains external to governed repos.

## Architecture

### Core idea

`carson govern` is a **portfolio-level triage loop** that runs on a schedule. Each cycle: scan repos, list open PRs, classify each PR, take the right action, report.

### Components

```
┌─────────────────────────────────────────────┐
│              carson govern                   │
│                                              │
│  1. Portfolio Scanner                        │
│     Read repo list from config               │
│     For each repo: list open PRs via gh      │
│                                              │
│  2. PR Triage Engine                         │
│     For each PR: check CI + review + audit   │
│     Classify: ready | ci_failing |           │
│       review_blocked | needs_attention       │
│                                              │
│  3. Action Dispatcher                        │
│     ready → merge + housekeep                │
│     ci_failing → dispatch agent to fix       │
│     review_blocked → dispatch agent to fix   │
│     needs_attention → escalate (notify user) │
│                                              │
│  4. Agent Adapters                           │
│     Codex adapter: shell out to codex CLI    │
│     Claude adapter: shell out to claude CLI  │
│     Both via Open3, same as git/gh adapters  │
│     Both return: success/failure + evidence  │
│                                              │
│  5. Report Writer                            │
│     Per-cycle JSON + Markdown summary        │
│     What happened, what's blocked, why       │
└─────────────────────────────────────────────┘
```

### How it runs

- **Primary**: `launchd` plist on Mac, runs `carson govern` every N minutes.
- **Alternative**: GitHub Actions workflow on `schedule` + `workflow_dispatch`.
- **Manual**: `carson govern --dry-run` for a single cycle.
- NOT a daemon. Not an event loop. A scheduled job.

### Decision tree

For each open PR in each governed repo:

```
1. Are CI checks green?
   NO  → Has an agent already been dispatched for this failure?
         YES → Is it still running? Skip. Did it fail? Escalate.
         NO  → Dispatch agent to fix CI. Record dispatch.

2. Does review gate pass?
   NO  → Are there unresolved review comments / changes requested?
         YES → Has an agent been dispatched to address them?
               YES → Skip/escalate as above.
               NO  → Dispatch agent to address review comments.
         NO  → Other block reason → escalate.

3. Does audit pass?
   NO  → Classify failure. Dispatch agent or escalate.

4. All three pass?
   YES → Merge (if authority enabled). Then housekeep (sync + prune).
```

## CLI

```
carson govern [--dry-run] [--json] [--loop SECONDS]
carson housekeep
```

- `govern` defaults to one cycle (not continuous).
- `--dry-run`: run all checks, report what WOULD happen, don't merge or dispatch.
- `--json`: machine-readable output.
- `--loop SECONDS`: run continuously, sleeping SECONDS between cycles. Errors are isolated per cycle. `Ctrl-C` exits cleanly with a cycle count summary.
- `housekeep`: standalone sync + prune.
- `refresh --all`: refreshes hooks, templates, and audit across all `govern.repos`.

### Exit contract

- `0` — success
- `1` — runtime/configuration error
- `2` — policy block

## File Structure

```
lib/carson/runtime/govern.rb       # Portfolio triage loop + merge + housekeep
lib/carson/adapters/agent.rb       # WorkOrder / Result data contracts
lib/carson/adapters/codex.rb       # Codex CLI adapter via Open3
lib/carson/adapters/claude.rb      # Claude CLI adapter via Open3
lib/carson/adapters/prompt.rb      # Interactive prompt adapter
test/runtime_govern_test.rb        # Unit tests (52 tests)
test/runtime_refresh_all_test.rb   # Refresh --all tests
```

Modified: `lib/carson.rb`, `lib/carson/cli.rb`, `lib/carson/config.rb`, `lib/carson/runtime.rb`, `script/ci_smoke.sh`.

## Agent Contract

### Work order

```ruby
WorkOrder = Data.define(:repo, :branch, :pr_number, :objective, :context, :acceptance_checks)
# objective: "fix_ci" | "address_review" | "fix_audit"
```

### Result

```ruby
Result = Data.define(:status, :summary, :evidence, :commit_sha)
# status: "done" | "failed" | "timeout"
```

Both adapters follow the existing adapter pattern: zero new dependencies, just `Open3.capture3`.

## Dispatch State Tracking

Simple state file at `~/.carson/govern/dispatch_state.json`:

```json
{
  "repo#42": {
    "objective": "fix_ci",
    "provider": "codex",
    "dispatched_at": "2026-03-02T10:00:00Z",
    "status": "running"
  }
}
```

Read at cycle start, updated after dispatch, cleared after merge or escalation.

## Configuration

```json
{
  "govern": {
    "repos": ["~/Dev/project-a", "~/Dev/project-b"],
    "merge": {
      "authority": false,
      "method": "merge"
    },
    "agent": {
      "provider": "auto",
      "codex": {},
      "claude": {}
    },
    "dispatch_state_path": "~/.carson/govern/dispatch_state.json"
  }
}
```

- `repos`: list of local repo paths to govern (empty = current repo only).
- `merge.authority`: default false — Carson doesn't merge until told to.
- `merge.method`: merge / squash / rebase.
- `agent.provider`: "auto" / "codex" / "claude".

Environment overrides: `CARSON_GOVERN_REPOS`, `CARSON_GOVERN_MERGE_AUTHORITY`, `CARSON_GOVERN_MERGE_METHOD`, `CARSON_GOVERN_AGENT_PROVIDER`.

## Delivery Status

| Phase | Capability | Status |
|-------|-----------|--------|
| 1 | Single-repo govern + housekeep, dry-run | Done |
| 2 | Merge authority with config guard | Done |
| 3 | Multi-repo portfolio scan | Done |
| 4 | Agent dispatch (codex/claude) + state tracking | Done |
| 5 | Scheduled execution (launchd / GitHub Actions) | `--loop` implemented; launchd/Actions deferred |

## Verification

- 52 unit tests in `test/runtime_govern_test.rb`.
- 4 govern smoke tests in `script/ci_smoke.sh`.
- All 137 unit tests pass (0 regressions).
- All 57 smoke tests pass.

## Decisions Made (vs. original Codex plan)

| Codex proposed | Implemented | Rationale |
|---------------|-------------|-----------|
| Always-on daemon / event loop | Scheduled job (one cycle) | No hosting model needed; cron IS the event loop |
| AI Planner with work graphs | Deterministic decision tree | PR states map to actions deterministically |
| 8-state state machine | PR state read fresh from GitHub each cycle | No local state machine needed |
| Staging deploy / rollback / SLO | Excluded | Deployment is a separate concern |
| Policy learning / adaptive parallelism | Excluded | Premature for v1 |
| Custom event intake | gh CLI as event source | GitHub Actions / cron provides the schedule |
| Housekeep excluded as non-goal | Included as `carson housekeep` | User explicitly asked for it |
