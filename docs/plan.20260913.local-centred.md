# Plan: Local-centred Carson

Date: 2026-09-13
Status: direction approved, execution deferred. Issue: #520.
Owner decision: Carson is local-centred only, by design. Every bureau-centred feature goes. Carson does its clear and basic jobs well.

This document is the Define and Plan phases of HAC for that refactor. Design and Structure happen in the session that executes it, with the owner designing the public surface. Nothing here is implemented yet.

## Define

**Goal.** Carson is a local-centred repository governor for coding agents. For the agent it does three jobs: start work in a fresh worktree, land finished work on main, release the worktree. For the operator it does three: onboard, offboard, list. It does them boringly well: every guard fires, every leftover is collected, every message names the next command. The code, the help text, the docs and the installed hooks all describe the same tool.

**Symptoms** (observed 2026-09-13, code at 4.4.0, last commit 2026-03-31).

- `carson --help` lists 6 commands. `lib/cli.rb` dispatches 15. README, MANUAL, API.md, docs/define.md and docs/spec.oo.md describe the PR-based bureau flow, `worktree create`, `housekeep`, `receive`, `review`, templates and `recover`.
- `lib/carson/runtime/**` is 7,504 of 12,205 library lines. Of that, `deliver.rb` (1,255), `receive.rb` (580), `recover.rb` (418), `review*` (1,245), `abandon.rb` (242), `local/template.rb` (368) and `local/merge_proof.rb` (217) serve only `bureau: true`, which no governed repository sets.
- `~/.carson/state.json` (348 KB, 362 delivery records) was last written 2026-03-25. The local path writes no ledger; git is the receipt.
- Installed hooks at `~/.carson/hooks/4.4.0`: `prepare-commit-msg` blocks commits on main, `pre-merge-commit` blocks merge commits on main, `pre-commit` and `pre-push` are `exit 0`. A raw `git push github main` from a worktree passes both Carson and the TAI Claude Code guard, whose push pattern applies only to ungoverned repositories. `~/.carson/hooks/` holds 97 versioned directories.
- 21 worktrees linger across 7 governed repositories. 16 are absorbed into main and survive because of one or two stray files. 12 date from March or April. The checkin sweep only reaps clean absorbed workbenches, so they are never collected.
- `deliver` blocks when `git fetch` fails. Observed 15 times since June in session transcripts ("Cannot receive latest standard").
- 38 open issues, two P0 (#464 review gate bypass in the bureau path, #415 hooksPath override displacing global guards).
- Usage since 1 June across 8 active repositories: 352 fast-forward landings on main through `deliver`, 231 "merged into main" lines and 193 "Worktree released" lines in transcripts. The local path is the product in practice.

**Root cause.** Carson was built in February and March 2026 as a remote-centred PR governor (130 releases in six weeks). On 2026-03-25 it pivoted to local-centred delivery (4.3.0) and kept the remote path behind a `bureau` toggle as an "enhancement". The pivot reached the help text and the happy path, then development stopped on 2026-03-31. Everything else, code, tests, docs, CI, hooks, config, still carries the remote product. The toggle is the mechanism that let two products coexist; removing the toggle removes the ambiguity.

**Scope.**

- In: removing every bureau-centred code path, test, workflow, config key and document; dissolving `Runtime` into the surviving objects; making the surviving jobs complete (hooks that guard, a sweep that collects, an offline decision); rewriting docs to state the code; updating the TAI files that name Carson commands; triaging the issue backlog; releasing.
- Out: any PR-based flow, agent dispatch, GitHub settings automation, templates, multiple couriers, new commands beyond the surface below, non-squash history policies (irrelevant once there is no PR).

## Surface after the refactor

The owner designs the public surface. This table is the proposal to confirm or strike.

| Command | Keep | Reason and evidence |
|---|---|---|
| `carson checkin <name>` | yes | Start work. Worktree from local main, branch named `<name>`, sweep of delivered workbenches. 530 transcript mentions since June. |
| `carson deliver [--commit MSG]` | yes | Land work. Fetch, rebase if behind, fast-forward local main, push main. 352 landings since June. `--title` and `--body-file` go. |
| `carson checkout <name> [--force]` | yes | Release work. #520 proposed making this internal; since then it shipped (4.2.0), CONCURRENCY.md prescribes it, the WorktreeRemove hook needs it, and it was used 193 times. Keep. |
| `carson` (no arguments) | yes | Status: branch, sync state, worktrees with recommendation. The read-only truth surface every block message can point at. Replaces `status` and `worktree list` as named commands. |
| `carson onboard <path>` / `offboard <path>` / `list [--json]` / `version` | yes | Portfolio. Unchanged. |
| `worktree create/list/remove` | no | Replaced by `checkin`, bare `carson`, `checkout`. Hard dependency: the TAI hook `block-creating-worktree-bypassing-carson` calls `carson worktree create --json` and `carson worktree remove <path>`. It must switch first (Phase 0). |
| `sync`, `prune`, `housekeep` | no | Internal to `deliver` and the checkin sweep. |
| `setup`, `template`, `refresh` | no | `onboard` auto-detects and writes config; there are no templates; hook re-installation becomes part of `onboard` and of `carson` startup when the installed hook version differs. |
| `receive`, `abandon`, `recover`, `review` | no | Bureau only. |

Config after the refactor: `git.remote`, `git.main_branch`, `govern.repos`. Removed: `bureau`, `govern.merge`, `template.canonical`, `lint.canonical`, `workflow.style`, every `CARSON_REVIEW_*` and agent-provider variable. Unknown keys in an existing `~/.carson/config.json` are ignored with one notice on first run, never an error.

Installed git hooks after the refactor (harness-agnostic, the only guards that reach Codex and a terminal):

| Hook | Behaviour |
|---|---|
| `prepare-commit-msg` | Block commits on main or master. Exists today; drop the `workflow_style` file it reads. |
| `pre-merge-commit` | Block merge commits on main. Exists today. Fast-forward is the contract. |
| `pre-push` | Block any push to main or master that Carson did not make. The Courier already pushes with `--no-verify`. Closes #419. |
| `pre-commit` | Dispatch to a configurable validators directory so TAI's `enforce/hooks/git/pre-commit.d/*` runs again. Closes #525 and the P0 #415 (Carson's `core.hooksPath` currently displaces those validators). |

Carson stops shipping `command-guard`. The Claude Code PreToolUse guard is TAI's `block-bypassing-carson`, which is registered, newer, and harness-specific. Carson owns git hooks; TAI owns harness hooks.

## Decisions for the owner at plan approval

1. Command surface as in the table, in particular `checkout` stays and bare `carson` is status.
2. Hook layer as in the table, in particular Carson's `pre-commit` becomes a dispatcher and `command-guard` leaves Carson.
3. Sweep rule for absorbed-and-dirty workbenches. Proposal: at checkin, a workbench whose branch is absorbed into main and whose last change is older than 14 days is reaped after its stray files are copied to `~/.cache/carson/swept/<repo>/<name>/`, and the checkin output lists what was swept and where the files went. Nothing is destroyed; 16 leftovers today would be collected.
4. Offline delivery. Today `deliver` blocks when fetch fails. Proposal: accept into local main when the branch is based on the last known remote main, print "Synced to remote: pending", and let the next `deliver` push both. Divergence is only possible if main is pushed from another machine.
5. Version. Removing commands is a breaking change; the release is 5.0.0 and needs explicit permission (Working Agreement 22).

## Plan

Each phase is one HAC cycle in its own worktree, delivered through `carson deliver`. Sizes use the issue labels: small is one session, medium needs a plan, large is multi-session.

**Phase 0. TAI hook compatibility** (small, `~/AI`, separate session: one project per session).
Task: switch `block-creating-worktree-bypassing-carson` from `carson worktree create <name> --json` to `carson checkin <name> --json`, and from `carson worktree remove <path>` to `carson checkout <name>`, resolving name from the path's basename. Works against 4.4.0 today. Key result: EnterWorktree, `--worktree`, and subagent isolation all create through `checkin` and remove through `checkout`, proven by one native worktree round trip in a governed repo.

**Phase 1. Remove the bureau path** (large).
Tasks: delete `runtime/deliver.rb`, `receive.rb`, `recover.rb`, `review.rb`, `review/`, `abandon.rb`, `loop_runner.rb`, `setup.rb`, `local/template.rb`, `local/merge_proof.rb`; delete `waybill.rb`, `delivery.rb`, `ledger.rb`, `revision.rb`, `warehouse/bureau.rb`, `warehouse/seal.rb`, `adapters/github.rb`, `adapters/claude.rb`, `adapters/codex.rb`, `adapters/agent.rb`, `adapters/prompt.rb`; reduce `courier.rb` to the sync gesture; strip the removed keys and validation from `config.rb`; remove the corresponding CLI parsers and dispatch; delete their tests (`runtime_deliver`, `runtime_receive*`, `runtime_recover`, `runtime_review_helpers`, `runtime_abandon`, `runtime_setup`, `runtime_canonical_template`, `runtime_template_propagate`, `runtime_merge_proof`, `ledger`, `waybill`, `config_canonical`, `carson_report`); remove `.github/workflows/carson_policy.yml`, `gate.yml`, `review-sweep.yml`, `release_node24_probe.yml` and the governance job in `ci.yml`; stop reading and writing `~/.carson/state.json` and `~/.carson/seals/`.
Key results: `grep -rn "gh " lib` and `grep -rni bureau lib` return nothing; `carson --help` equals the surface table; the remaining suite passes; library under 4,000 lines.

**Phase 2. Dissolve Runtime** (medium). Closes #462, #246, #523, #457.
Tasks: move `status`, `onboard`, `offboard`, `list` and hook installation onto `Warehouse` and a small portfolio object; fold `lib/carson/worktree.rb` (661 lines, legacy) into `Warehouse::Workbench`; fold `local/sync.rb`, `local/prune.rb`, `local/worktree.rb` into the Warehouse sweep; delete `runtime.rb` and `runtime/`.
Key results: no `runtime` directory; every CLI command dispatches to a domain object as `checkin` and `checkout` already do; library under 2,500 lines; the OO checklist in CODING.md passes for each surviving class.

**Phase 3. Do the basic jobs well** (medium). Closes #419, #525, #415, #467, #417, #416 if confirmed.
Tasks: implement the hook table above; implement the sweep rule (decision 3); implement the offline decision (decision 4); install hooks into `~/.carson/hooks/<version>` and remove directories no governed repository points at; refuse to deliver an empty file set if #416 is confirmed.
Key results, each proven live on a throwaway governed repository under `~/.cache`: raw `git commit` on main is blocked; raw `git push github main` from a worktree is blocked while `carson deliver` still pushes; a TAI validator in `pre-commit.d` fires; an absorbed dirty workbench older than the threshold is swept with its files preserved; `deliver` with the network off accepts locally and the next `deliver` syncs.

**Phase 4. Docs and cross-file consistency** (medium). Closes #510, #281.
Tasks: rewrite README, MANUAL, API.md, docs/define.md, docs/spec.oo.md and docs/class-diagram.mmd to state the code and nothing else (Working Agreement 26); add the 5.0.0 entry to RELEASE.md; in `~/AI` (separate session) update `skills/carson/SKILL.md` (drop `--title`, `--body-file`, "review comments unresolved", "push, PR, merge"), CONCURRENCY.md pre-flight scan (`carson worktree list`, `gh pr list`), and the `~/.claude/CLAUDE.md` hook descriptions; triage issues: close with disposition the bureau-only set (#464, #491, #484, #439, #421, #414, #391, #390, #339, #336, #280, #239, #521, #524, #460, #459, #425), close as done (#498, #494), keep (#422, #236, #481, #458, #461).
Key result: `grep -rn "worktree create\|worktree list\|review gate\|housekeep\|gh pr" ~/AI/core ~/AI/skills/carson ~/.claude/CLAUDE.md` returns nothing that contradicts the surface table; every closed issue carries a `Claude:` disposition.

**Phase 5. Release** (small). Requires the owner's permission for 5.0.0.
Tasks: release the gem; `carson onboard` or startup re-installs hooks in all 10 governed repositories; verify `core.hooksPath` in each; one live `checkin`, commit, `deliver`, `checkout` cycle in a real governed repository with the output quoted.
Key result: `carson version` prints 5.0.0 in every governed repository and the cycle output matches the MANUAL.

**Dependencies and sequence.** Phase 0 before Phase 1 (the TAI hook must stop calling `worktree create` before it disappears). Phase 1 before Phase 2 (dissolve what remains, not what will be deleted). Phase 3 after Phase 2 (hooks and sweep land on the final objects). Phase 4 can start after Phase 1 and must finish before Phase 5. `~/AI` edits are their own sessions and their own deliveries.

**Risks.** The TAI hook and Carson are in different repositories; a version skew between them breaks native worktree creation, so Phase 0 is not optional. Removing `worktree remove` removes the only path the WorktreeRemove hook has for a worktree Carson did not register; `checkout` must accept a path as well as a name, or the hook falls back to raw git as it does today. The offline decision changes when main can move; if rejected, `deliver` keeps blocking and the message names the remote.
