# Carson Feature Evaluation — 2026-03-16

A thorough evaluation of Carson at version 3.28.0: what it solves well, where gaps remain, how coding agents experience it, and what solidification looks like.

This review covers 14,493 lines of Ruby source, 10,954 lines of tests, 18 open issues, 40+ releases across the 2.x–3.x series, and three governed repositories (`~/AI`, `~/Dev/carson`, `~/Dev/nexus`). The evaluation draws on deep reading of every command, the full test suite, the TAI instruction set's Carson references, the changelog trajectory, the 3.x retrospective, and the govern pipeline incident analysis.

---

## Part I — What Carson Solves Well

### 1. The delivery gap

**Problem:** A coding agent that finishes work faces a multi-step, error-prone sequence: `git push`, compose a PR body, `gh pr create --body-file`, poll CI, `gh pr merge --rebase`. Each step can fail silently or produce an inconsistent state. Agents routinely forgot steps, used wrong flags, or left PRs orphaned.

**Carson's answer:** `carson deliver` compresses the entire sequence into one command. Push, PR creation, bounded settle window (polling CI and review), merge attempt with retry cap, and explicit handoff if the window expires. The `*_finish` pattern guarantees dual-mode output (human and JSON) with recovery guidance on every failure path.

**Why it works:** Delivery is the single most-executed agent workflow. Every release since 3.2 shipped through `carson deliver`. The command was tested by using it to ship itself — a virtuous recursion that catches regressions in the delivery path before they reach users. The bounded settle loop (introduced conceptually in 3.23, being formalised in the active spec) means agents do not need a second manual `deliver` for the common case of "GitHub needed a few more seconds."

**Verdict: strong.** This is Carson's core value proposition and it delivers.

### 2. Recovery-aware errors

**Problem:** When a git operation fails, the agent wastes context window diagnosing what went wrong and composing the fix command. Multiply this by every error in every session and the cost is enormous.

**Carson's answer:** Every error path in Carson sets two keys: `result[:error]` (what went wrong) and `result[:recovery]` (the exact command to fix it). The 3.x retrospective called this "the single best design decision in the 3.x series."

**Example:**
```
result[:error] = "working tree is dirty"
result[:recovery] = "carson deliver --commit \"describe this delivery\""
```

**Why it works:** Recovery-aware errors compound. Every agent that hits an error gets the fix for free, with zero diagnostic overhead. The pattern was built from scars — every recovery command was written by someone who had been in the position of needing one.

**Verdict: strong.** This is the architectural decision most worth preserving and extending.

### 3. Worktree lifecycle safety

**Problem:** Raw `git worktree add` gives no sync-first guarantee. Raw `git worktree remove` does not check whether the shell CWD is inside the worktree, whether another process holds it, or whether there are unpushed commits. The #1 agent session crash was a worktree directory disappearing while the agent's shell was inside it.

**Carson's answer:** A three-guard safety system:
- `cwd_inside_worktree?` — blocks removal if the current shell is inside the target
- `held_by_other_process?` — uses `lsof -d cwd` to detect other processes with CWD in the worktree
- `branch_unpushed_issue` — content-aware (diff, not SHA) to handle squash merges

Plus: `worktree create` fetches remote main before branching, verifies the creation succeeded (guarding against known git versions that succeed but produce broken state), and writes `.git/info/exclude` to hide `.claude/` from git status.

**Why it works:** Safety as impossibility, not as advice. `EXIT_BLOCK` before destruction, not a warning the agent might ignore under pressure. The CWD guard was the retrospective's top lesson: "This should have been built first, not last."

**Verdict: strong.** The content-aware unpushed check (handling squash/rebase merges where commit SHAs differ) is particularly well-engineered.

### 4. Enforcement through hooks

**Problem:** Rules written in instruction documents are advisory. An agent under pressure — context window filling, complex task, tight loop — will bypass a rule it has merely been told about. The rule must be structural.

**Carson's answer:** Three enforcement layers:
1. **`command-guard` (PreToolUse hook)** — blocks `gh pr create/merge`, `git worktree add/remove`, `git pull --rebase`, and `git add/commit` on main in governed repos. Runs before every Bash tool call in Claude Code.
2. **`pre-push` hook (per-repo)** — blocks raw `git push` to main/master and any raw push in governed repos. Installed by `carson refresh`.
3. **`pre-commit` hook** — runs `carson audit` on every commit, blocking on governance violations.

The `command-guard` auto-installs at CLI startup (`ensure_global_artefacts!` in `cli.rb`), so upgrades self-propagate without requiring manual `carson refresh`.

**Why it works:** The hooks turn rules into walls. An agent cannot accidentally `gh pr create` in a governed repo — the hook exits 2 before the command reaches the shell. The pattern matching is anchored (`(^|&&|\|\||;|\|)\s*git...`) to avoid false positives inside string arguments — a fix born from a real false-positive incident (3.21.1).

**Verdict: strong, with one gap** (see Part II, gap #3).

### 5. The outsider boundary

**Problem:** Governance tools that leave artefacts inside governed repos create coupling. The repo cannot be used without the tool. The tool's state contaminates the repo's state.

**Carson's answer:** Carson lives at `~/.carson/` and never inside the repositories it governs. The only footprint in governed repos is managed `.github/*` files (CI workflows, lint configs) and git hooks. No `.carson.yml`, no `bin/carson`, no runtime dependency. `block_if_outsider_fingerprints!` actively prevents Carson from operating in a repo that contains these markers (which would indicate Carson's own source repo).

**Why it works:** The boundary makes Carson safe to add and remove. `carson offboard` cleanly removes every managed file and hook, returning the repo to its pre-governance state.

**Verdict: strong.** This is a principled architectural decision that prevents the most common failure mode of governance tools.

### 6. Portfolio batch operations

**Problem:** With multiple governed repos, running the same maintenance command in each one is tedious and error-prone. Repos that fail silently get left behind.

**Carson's answer:** Every single-repo command gains cross-repo reach through `--all`: `refresh --all`, `housekeep --all`, `prune --all`, `audit --all`, `sync --all`, `status --all`. Failed repos are tracked in `batch_pending.json` and retried on the next run. `portfolio_repo_safety` checks for active worktrees and uncommitted changes before each batch entry.

**Why it works:** Same operation, wider scope, no new mental model. The pending-tracking system ensures no repo is silently abandoned after a transient failure.

**Verdict: strong.**

### 7. Merge proof system

**Problem:** After squash or rebase merges, commit SHAs differ between the branch and main. `git merge-base --is-ancestor` returns false even though the content is identical. This makes it impossible to determine whether a branch's work has already landed.

**Carson's answer:** Three-tier evidence:
1. `ancestor` — exact SHA ancestry check
2. `no_changes` — branch has no unique files relative to merge-base
3. `content_identical` — `git diff --quiet branch main -- <changed_files>` (covers squash/rebase)

Trust check: verifies local main is in sync with remote before declaring content-identical proofs. `merge_proof_for_remote_ref` works against the remote tracking ref directly for govern's post-merge path, avoiding main worktree mutation.

**Verdict: strong.** This is a genuinely novel capability that no other git tool provides at this level.

---

## Part II — Where the Gaps Are

### Gap 1: Govern state machine is incomplete

**Severity: high.** This is the pipeline incident from 2026-03-15.

Five confirmed defects remain on main:
1. **`format_govern_action` lies** — reports the attempted action ("integrate"), not the actual outcome. The operator sees "integrated" when the merge failed.
2. **Merge-loop** — a conflicted PR oscillates `queued → integrating → gated → queued` indefinitely because `assess_delivery!` checks CI and review but never queries GitHub mergeability.
3. **Head-of-line blocking** — FIFO queue with no escape hatch. A stuck first-ready delivery blocks all later ones.
4. **Post-merge cleanup is incomplete** — `housekeep_repo!` does not call `reap_dead_worktrees!` after sync.
5. **Cleanup coupled to sync success** — housekeep only reaps after a successful sync, making cleanup more fragile than necessary.

**Impact:** Govern cannot be left unattended around merge conflicts. The portfolio layer — Carson's most ambitious capability — is not trustworthy enough for unsupervised operation.

### Gap 2: Squash-only merge method

**Severity: medium.** The config validator enforces `"squash"` as the only valid merge method for governed integration. Repos that require merge commits (preserving individual commit history) or rebase merge (linear history without squash) cannot use `carson govern` or `carson recover`.

This is an intentional design constraint documented in `develop.md`, but it limits adoption to repos that accept squash-only workflows. The constraint is especially sharp for repos with atomic commits where each commit carries semantic meaning.

### Gap 3: Pre-push hook is not globally installed

**Severity: medium.** The `command-guard` (PreToolUse hook) blocks `gh pr create/merge` globally in governed repos. But raw `git push` blocking depends on the per-repo pre-push hook installed by `carson refresh`. If a repo was never refreshed, or hooks were manually removed, raw `git push` works. The command-guard does not block `git push` (only `git add/commit` on main).

There is a gap in the enforcement chain: an agent on a stale governed repo could `git push` directly, bypassing the delivery path.

### Gap 4: TAI documentation lags Carson's actual capabilities

**Severity: medium.** TOOLS.md lists six Carson commands (deliver, worktree create/remove, housekeep, prune, sync). It omits `carson status`, `carson audit`, `carson review`, `carson govern`, `carson abandon`, and `carson recover`. This means TAI-reading agents have no instruction to use:
- `carson status` for session orientation
- `carson govern` for portfolio oversight
- `carson recover` for baseline-red deadlock repair
- `carson abandon` for deliberate discard

Additionally, INTEGRATION.md describes the command-guard as only blocking `gh pr create/merge`, but the actual guard also blocks `git worktree add/remove`, `git pull --rebase`, and `git add/commit` on main.

### Gap 5: Agent policy boundary is unfulfilled

**Severity: medium.** The `docs/carson-agent-policy-boundary.md` spec defines the correct boundary: Carson-owned agent policy belongs under `~/.carson`, not in `~/.claude` or `~/.codex`. Non-governed repos should experience no Carson enforcement.

Current reality: guard hooks live in `~/AI/hooks/` (edit-guard, main-tree-write-guard, bash-write-guard). These fire in every repo, governed or not. The spec's six-phase migration plan has not been executed. The boundary between "Carson governance" and "general agent safety" is unclear in practice.

### Gap 6: Ledger grows unboundedly

**Severity: low.** Terminal deliveries (`integrated`, `failed`, `superseded`) are never pruned from `~/.carson/state.json`. Long-lived portfolios will accumulate historical records indefinitely. There is no `ledger compact` or TTL mechanism.

### Gap 7: `lsof` dependency for cross-process safety

**Severity: low.** `held_by_other_process?` silently returns `false` if `lsof` is not installed (catches `Errno::ENOENT`). On minimal Linux installs, the cross-process CWD guard is absent. The CWD guard for the current process still works — but a parallel agent's worktree could be removed without detection.

### Gap 8: Review gate and review sweep lack JSON output

**Severity: low.** These commands lack the `json_output:` parameter that all other commands have. They write to cache files but always print human output. For programmatic consumption, agents must parse human-readable text.

### Gap 9: Runtime god object

**Severity: low (architectural debt).** `Runtime` is a single class with 25+ included modules. Issue #246 and #214 both track extracting domain objects. The current structure works but makes it harder to test individual concerns in isolation and increases cognitive load for contributors.

### Gap 10: Test pollution and CI artefacts

**Severity: low.** Issue #236 tracks test pollution. CI still installs the SQLite gem despite the migration to JSON (`.github/workflows/ci.yml:29-30` and `64-65`). The sqlite3 gem dependency in the gemspec remains for legacy import only.

---

## Part III — How Coding Agents Experience Carson

### What agents like

**Predictability.** Carson's three exit codes (0/1/2) and the silence-means-safety contract give agents a reliable decision framework. An agent does not need to parse prose — it reads the exit code. `EXIT_OK` means proceed. `EXIT_BLOCK` means the exact recovery command is in the output. `EXIT_ERROR` means something unexpected happened.

**Workflow compression.** The agent's most common sequence — commit, push, create PR, wait for CI, merge — is one command. This saves context window, reduces error surface, and eliminates the class of bugs where an agent forgets a step or uses the wrong flag.

**Recovery without diagnosis.** When something fails, the `:recovery` field contains the exact command. The agent does not waste tokens understanding what went wrong — it reads and executes the recovery command. This compounds across sessions: every error is a single-turn recovery, not a multi-turn diagnosis.

**The `--json` forcing function.** While agents rarely parse the JSON output as structured data, the JSON flag forced good internal architecture. Every command builds a result hash, every error carries recovery guidance, and every output path goes through a single `*_finish` method. The discipline this imposed is more valuable than the JSON output itself.

### What agents find frustrating

**Govern is not trustworthy enough to leave alone.** The pipeline incident proved that govern can lie about outcomes and get stuck in merge-conflict loops. An agent running `carson govern --loop` must still be supervised, which defeats the purpose of autonomous portfolio governance.

**The settle loop requires a second invocation.** When `deliver` times out during the settle window, it hands off to govern. But the agent just wanted to ship — now it must run a separate command or wait for the govern loop. The active spec for `spec.20260316.deliver-settle-loop.md` addresses this, but it is not yet implemented.

**Template system is both useful and annoying.** Template sync on push ensures lint configs stay aligned, but it can create unexpected commits during delivery. The template system itself is under question (issue #281 proposes removing it). Agents sometimes fight the template system rather than benefiting from it.

**The `command-guard` occasionally blocks legitimate commands.** The false-positive fix in 3.21.1 addressed the most common case (matching inside string arguments), but the pattern-matching approach has an inherent tension: broad patterns catch more bypasses but also catch more legitimate uses.

### What agents do not know about

**`carson status` for orientation.** TAI does not instruct agents to run `carson status` at session start. The 3.x retrospective noted that `status` solves a data-gathering problem, not a comprehension problem — but it would still be useful as a quick orientation command if agents knew about it.

**`carson recover` for baseline-red.** When a required CI check is already red on main, the only way to land a repair PR is `carson recover --check "NAME"`. Agents that do not know about this command are stuck.

**`carson abandon` for deliberate discard.** When work should be thrown away rather than landed, `carson abandon` closes the PR and cleans up safely. Without this knowledge, agents attempt manual `gh pr close` + `git worktree remove`, which can leave orphaned branches.

---

## Part IV — Trajectory Assessment

### The arc so far

```
2.x  ─── Single-repo governance substrate
         audit, hooks, prune, templates, outsider boundary

3.0  ─── Agent reorientation (explicit pivot: "Carson is for coding agents")
3.3       deliver, --json everywhere, recovery-aware errors
3.10      CWD guard, cross-process safety
3.11-12   Subtraction: −1,039 lines (wrong requirements removed)

3.13 ─── Worktree auto-sync, post-merge guidance
3.15      housekeep, dead worktree reaping
3.18      Portfolio batch --all layer
3.21      Three-layer enforcement (command guard)
3.22      Self-configuring: auto-install guard at startup

3.23 ─── Delivery architecture redesign (async deliver, JSON ledger, govern)
         INCIDENT: pipeline deadlock, govern display bug, FIFO no escape
3.24-27   Incident recovery, JSON migration, SQLite removal
3.28      Merge proof, PR telemetry, delivery/worktree safety hardening
```

### Release velocity

40+ releases in 13 days (3.0 on 2026-03-04 to 3.28 on 2026-03-16). This is extraordinarily fast. The velocity brought genuine capability — but also brought the pipeline incident when two large changes collided (the umbrella housekeep PR #299 vs the SQLite-to-JSON ledger rewrite #311).

### The pattern

The most valuable work came from experienced pain: shell death (CWD guard), error diagnosis overhead (recovery-aware errors), manual PR steps (deliver). The least valuable came from anticipated complexity: session state (removed), agent coordination signals (never built), review triage (wrong requirement).

The 3.x retrospective captured this precisely: "Build from scars, not speculation." The retrospective itself was the most valuable non-code artefact Carson produced — it cut 1,039 lines of overbuilt code and redirected effort toward safety.

### Current active specs

Three specs are active, all written 2026-03-16:
1. **Branch freshness gate** — `deliver` must verify freshness against remote main before merging. Unknown freshness is never treated as fresh.
2. **Bounded settle loop** — one `deliver` should own the short merge-settle window without requiring a second invocation.
3. **Authority model** — formal remote/local authority model. Local authority explicitly deferred.

These are the right priorities. They address real pain: freshness is a merge-conflict prevention mechanism, the settle loop eliminates the "run deliver twice" friction, and the authority model prevents the hybrid-authority bugs that caused past failures.

---

## Part V — Solidification Strategy

Solidification means making what exists reliable, not adding new capabilities. Carson has enough features. What it needs is trust.

### Priority 1: Make govern truthful and resilient

This is the single highest-impact work. The pipeline incident proved govern cannot be trusted unattended. Five fixes, in order:

1. **Fix `format_govern_action`** to report the actual outcome, not the attempted action.
2. **Add mergeability check** to `assess_delivery!`. Query GitHub's `mergeable` field. A PR that is green on CI and review but has merge conflicts is `merge_blocked`, not `queued`.
3. **Add `merge_blocked` / `conflicting` state** to the delivery state machine. This is not `gated` — it is a distinct condition that requires a different response (rebase, not wait).
4. **Skip blocked head items.** The FIFO queue must try the next ready delivery when the first is blocked.
5. **Add recovery for stale `integrating` entries.** A delivery stuck in `integrating` (process crash mid-merge) needs a reconciliation path.

These five fixes turn govern from "needs supervision" to "trustworthy for unsupervised loops."

### Priority 2: Complete the delivery loop

The active specs for freshness gate and settle loop are the right next steps. Implementation order:

1. **Freshness gate** (spec slice 1) — strict gate at delivery time, no auto-rebase. This prevents the class of merge conflicts that the pipeline incident amplified.
2. **Bounded settle loop** (spec) — one deliver invocation owns the merge-settle window. Eliminates the "run deliver twice" friction.
3. **Freshness evidence in ledger** (spec slice 2) — persisted so govern can verify freshness without re-running the check.

### Priority 3: Clean up the enforcement boundary

The agent-policy-boundary spec is correct but unfulfilled. The work is:

1. Move Carson-owned guards to governed-only activation. Non-governed repos should experience no Carson enforcement.
2. Add `git push` blocking to the `command-guard` (closing the gap where the per-repo pre-push hook is the only blocker).
3. Update TAI documentation to reflect Carson's actual command surface (status, audit, review, govern, abandon, recover).

### Priority 4: Operational hardening

1. **Ledger compaction.** Add a TTL or explicit `ledger compact` to prune terminal deliveries older than N days. The JSON file should not grow unboundedly.
2. **Remove stale CI SQLite installs.** The sqlite3 gem is no longer a runtime dependency.
3. **Add JSON output to review gate and review sweep.** Complete the dual-mode output contract.
4. **Fallback for `lsof` absence.** When `lsof` is not available, log a warning rather than silently degrading the cross-process guard.

### Priority 5: Architectural simplification (defer)

The Runtime god object (#246, #214) is real debt but not urgent. The current structure works. Extraction should happen when a concrete change is blocked by the coupling — not as a speculative refactor.

Similarly, the template system question (#281) should be decided by evidence: if templates are causing more friction than they prevent, remove them. If they are preventing real drift, keep them.

### What not to build

The 3.x retrospective's lessons apply here with full force:

- **No agent coordination signals.** Convention works. The iron rule ("don't touch other sessions' worktrees") has never been violated. Do not replace it with tooling.
- **No session state resurrection.** Memory files and git state are sufficient. The feature was removed for good reason.
- **No review triage.** The 64-finding problem was a one-time accumulation, not a recurring need.
- **No local authority model yet.** The spec explicitly defers this. Implement remote authority cleanly first.

---

## Part VI — How Agents Should Think About Carson

Carson is not a convenience wrapper around git. It is a safety layer that makes concurrent agent work possible.

Without Carson, an agent working in a governed repo has no:
- Sync-before-branch guarantee (worktree could start from stale main)
- CWD-safe worktree removal (session crash)
- Content-aware merge detection (false "unpushed" warnings after squash merge)
- Bounded delivery flow (each step is manual and error-prone)
- Recovery guidance on failure (diagnosis consumes context window)
- Portfolio-wide maintenance (manual per-repo housekeeping)
- Enforcement against raw git/gh commands (bypasses are silent)

With Carson, all of these are structural — they happen automatically or they block with a recovery command. The agent's job is to write code and commit. Carson handles everything from push to merge to cleanup.

The relationship is asymmetric: the agent provides intelligence, Carson provides discipline. Neither is sufficient alone. An agent without Carson makes mistakes in delivery. Carson without an agent has nothing to deliver. Together, they form a complete workflow.

### Carson's unique contribution to the agent ecosystem

No other tool in the coding agent ecosystem solves the concurrent-agent repository governance problem. Tools like `gh`, `git`, and CI systems provide primitives. Carson composes those primitives into a safe, predictable workflow with structural enforcement. The outsider boundary ensures this composition does not create coupling.

The recovery-aware error pattern is Carson's most transferable contribution. Any tool that interacts with agents should adopt it: every error should carry the exact command to fix it. This is not just UX — it is a fundamental property of agent-compatible tooling.

The merge proof system is Carson's most novel contribution. Content-aware merge detection that handles squash, rebase, and cherry-pick merges is genuinely new capability that no other git tool provides.

---

## Part VII — Final Assessment

### Strengths (what to preserve)

| Capability | Status | Confidence |
|---|---|---|
| `carson deliver` | Production-proven | High |
| Recovery-aware errors | Architecture-wide pattern | High |
| CWD + lsof + unpushed safety trinity | Production-proven | High |
| Outsider boundary | Principled, clean | High |
| Three-layer enforcement hooks | Production-proven | High |
| Content-aware merge proof | Production-proven | High |
| Batch `--all` portfolio operations | Production-proven | High |
| Dual-mode `*_finish` output | Architecture-wide pattern | High |
| Signal-aware loops | Production-proven | Medium-high |

### Gaps (what to fix)

| Gap | Severity | Effort | Priority |
|---|---|---|---|
| Govern truthfulness and resilience | High | Medium | 1 |
| Delivery freshness gate | Medium-high | Medium | 2 |
| Bounded settle loop | Medium | Low-medium | 2 |
| Enforcement boundary (non-governed repos) | Medium | Medium | 3 |
| TAI documentation lag | Medium | Low | 3 |
| Ledger compaction | Low | Low | 4 |
| Review gate/sweep JSON output | Low | Low | 4 |
| `lsof` fallback | Low | Low | 4 |

### Verdict

**Carson is a strong, scar-proven tool that has found its problem domain.** Single-repo delivery and safety are excellent. Portfolio governance (govern loop) is the one area where ambition has outrun reliability — the pipeline incident exposed real state-machine gaps that need fixing before govern can be trusted unattended.

The solidification path is clear: make govern truthful (Priority 1), complete the delivery loop (Priority 2), clean up the enforcement boundary (Priority 3), and harden operations (Priority 4). No new major features are needed. The tool has enough capability — it needs trust.

The 3.x retrospective's lesson still applies: build from scars, not speculation. The pipeline incident is now the latest scar. Fix what it exposed. Do not build anything it did not expose.

---

## Evidence Base

### Codebase metrics
- Source: 14,493 lines across `lib/carson/**/*.rb`
- Tests: 10,954 lines across `test/**/*_test.rb`
- Test results (as of pipeline final review): 405 runs, 1,298 assertions, 0 failures
- Smoke: `script/ci_smoke.sh` + `script/review_smoke.sh`
- External dependencies: 1 (sqlite3, migration only)

### Release history
- 2.x series: single-repo governance foundation
- 3.0–3.28: 40+ releases in 13 days
- Current: 3.28.0 (2026-03-16)
- Governed repos: 3 (`~/AI`, `~/Dev/carson`, `~/Dev/nexus`)

### Open issues: 18
- Bugs: #239 (empty branch push), #238 (template sync revert)
- Features: #336 (gh api bypass), #281 (remove templates), #203 (auto-propagate)
- Fixes: #376 (dogfood runtime), #334 (transient PR lookup), #351 (slash-scope remove), #350 (false success on reap), #352 (closed delivery active)
- Architecture: #246 (domain objects), #214 (OO extraction)
- Ideas: #339 (authority model)

### Key reviews and specs
- `review.20260309.retrospective-3x.md` — what was worth building vs overbuilt
- `review.20260315.govern-pipeline-final.md` — pipeline incident root cause and fixes
- `spec.20260316.deliver-branch-freshness.md` — freshness gate (active)
- `spec.20260316.deliver-settle-loop.md` — bounded settle loop (active)
- `spec.20260316.authority-model.md` — authority model (active)
- `docs/carson-agent-policy-boundary.md` — enforcement boundary (unfulfilled)
