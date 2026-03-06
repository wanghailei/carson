# Carson Chronicle

The narrative history of Carson — turning points, design decisions, and the thinking behind them. This is not a changelog (see `RELEASE.md` for version deltas). This is the story of a product finding its identity.

---

## The Bootstrap — 16 February 2026

Carson began life as **Butler**, a shared-template CLI for enforcing repository policy. The first commit bootstrapped a Ruby CLI with scope-based template management. Within hours, it had CI protection, default config inference, and the first PR was merged. The velocity was extraordinary — from zero to a working gem in a single day.

The name "Butler" reflected the original concept: a background servant managing the household of a repository. But even in these first hours, the ambition was bigger than templates. The first features already included review resilience gates and auto-pruning of squash-merged branches. Butler was never going to be just a file copier.

## The Outsider Principle — 17 February 2026

The second day brought the architectural decision that would define everything: **Carson is an outsider.** The v0.2.0 refactor split the runtime into a gem that lives outside client repositories. No `.butler.yml` config file in the repo. No Carson-owned artefacts polluting the host. Carson manages `.github/` files that are native to GitHub — pull request templates, workflow files, coding guidelines — but never plants its own flag in someone else's territory.

This was a principled choice, not a technical convenience. It meant Carson could never become a dependency that locks users in. Offboarding is clean — remove the files, and the repo returns to exactly the state it was in before.

## The Name Change — 24 February 2026

Butler became Carson. Named after Carson the butler in Downton Abbey — the consummate head of household who runs the estate with discipline and professional standards, but never oversteps his station. He prepares everything for the family's decisions but does not make them himself.

The name change was more than branding. It crystallised the product's personality: confident, competent, deeply knowledgeable, but always in service. Carson does not hedge or guess. It acts with the certainty of someone who has managed the household for decades.

## 1.0 — The Foundation Settles — 25 February 2026

After nine days of rapid iteration (0.1.0 through 0.9.0), Carson reached 1.0. The surface area was defined: `onboard`, `audit`, `sync`, `template`, `prune`, `review gate`, `review sweep`, `offboard`, `refresh`. The exit status contract was locked: `0` for success, `2` for policy block, `1` for unexpected error.

1.0 was not a marketing milestone. It was the moment the architectural bets stopped changing. The outsider principle, the template management model, the pre-commit hook integration, the audit pipeline — all settled. What followed would be deepening, not pivoting.

## 2.0 — The Butler Becomes a Governor — 2 March 2026

The leap from 1.x to 2.0 happened in a single day, driven by a single insight: if Carson can verify every PR's readiness, why can't it act on that verification?

The `govern` command was born — cross-repository triage that merges ready PRs, dispatches coding agents to fix failing ones, and escalates only what needs human judgement. `refresh --all` followed, keeping templates synchronised across the entire estate without visiting each repo.

Carson stopped being a linter and became an autonomous governance runtime. The 2.0 bump was earned: this was a different product now.

## Copywriting Is UI Design — 3 March 2026

A wave of UX work transformed Carson's output personality. The insight that drove it: **every line Carson prints is a UI surface.** Concise output became the default — silence for health, one actionable message for problems. Verbose mode became the debugging channel, not the default.

The onboard flow was rewritten with a warm welcome guide. Setup prompts became first-class UX surfaces — one question per interaction, one clear default, every response ending with a concrete next step. The post-install message was refined three times until it read like a confident professional introduction, not a technical dump.

This period established Carson's voice: brief, self-diagnosing, never leaving the user wondering "what now?"

## The Lint Pivot — 4 March 2026

Carson 2.12.0 added MegaLinter integration. By 2.19.0, lint was stripped back out. The lesson: Carson should not own lint policy. Lint is a domain-specific concern that belongs to the repository owner. What Carson *should* own is the mechanism for distributing lint configuration — canonical templates that sync the owner's chosen configs across all governed repos.

The `template.canonical` config key was born: point it at a directory, and Carson appends those files to its managed set. The owner's lint rules flow through Carson's template pipeline without Carson having any opinion about what those rules say.

This was the outsider principle applied to lint: Carson carries the envelope, it does not write the letter.

## Prune Grows Teeth — 4–6 March 2026

Branch pruning evolved through three stages:
1. **Stale branches** (2.0) — upstream deleted, PR evidence confirms merge, safe to force-delete locally.
2. **Orphan branches** (2.20.0) — no upstream at all, but merged PR evidence exists.
3. **Absorbed branches** (2.27.0) — upstream exists, but content comparison proves the work is already on main.
4. **Absorbed fallback** (2.30.0) — when stale branches fail SHA-based PR lookup (rebase merges rewrite commit hashes), content comparison catches them.

Each stage was driven by a real-world gap: agents creating branches, rebase merges changing SHAs, cherry-picks landing content without merge commits. The evidence chain grew more sophisticated, but the principle stayed simple: never delete a branch unless you can prove its work is already on main.

## Carson Is for Coding Agents — 6 March 2026

The most important product insight arrived during a session focused on audit UX and worktree lifecycle. The user stated it plainly: **Carson is for coding agents, not for humans.**

The primary consumer of Carson's commands, lifecycle management, and governance is the coding agent working on behalf of the developer. What makes working with agents best — therefore makes the human owners most happy with no burden — Carson should handle.

This reframed everything. The human owner benefits indirectly: when Carson keeps the agent's environment disciplined and predictable, the agent produces better work, and the human never has to intervene in housekeeping. The ideal state is that the human owner forgets Carson exists — everything just works.

This became the theme of Carson 3.0.

## Worktree Lifecycle — 6 March 2026

The same session produced `carson worktree remove` — born from direct pain. When a worktree directory is deleted while an agent's shell is inside it, the shell becomes permanently unusable. This happened repeatedly during the session itself.

The safe teardown order became an iron rule: exit the worktree, `git worktree remove`, then branch cleanup. Carson enforces this order in a single command so agents never have to remember it. The goal: worktree teardown is always safe, never leaves debris.

## Looking Forward — Carson 3.0

The 3.0 vision is taking shape:

- **Overseer model.** Shift from per-repo onboarding to central oversight. Repositories are *registered* under Carson's protection. The vocabulary changes from "onboard" to "register."
- **`--all` as the elegant extension.** Every single-repo command gains cross-repo reach through one flag. Same operation, wider scope.
- **Worktree lifecycle as first-class.** Create, track, and clean up — the full agent workspace lifecycle.
- **Commercial licensing.** Open-source and personal use remain free. Commercial use may require a paid licence.

The core insight remains: single-repo depth is the foundation. Multi-repo governance is the same discipline repeated. Get the single-repo story perfect; multi-repo follows naturally.
