# Carson Chronicle

---

## Day One — 16 February 2026

It started with a frustration every developer knows: repositories drift. Templates go stale. Hooks fall out of sync. Review comments get lost. Nobody remembers the merge method. Every project reinvents the same governance from scratch, and every project gets it slightly wrong.

The first commit landed at 5:30 PM on a Sunday. A Ruby CLI called **Butler** — a shared-template tool that could push policy files into repositories. Within six hours, it had CI protection, default config inference, a scope-matching engine, and its first two merged PRs. By midnight, it had a version number: 0.1.0.

The name came from the idea of background service — a butler who keeps the household running without being asked. But even on day one, the ambition outran the name. The first features included review resilience gates and auto-pruning of squash-merged branches. This was never going to be a file copier.

## The Iron Rule — 17 February 2026

The second day produced the decision that would define everything that followed.

Carson is an **outsider**.

The v0.2.0 refactor split the runtime into a gem that lives outside client repositories. No config file planted in the repo. No Carson-owned artefacts polluting someone else's territory. Carson manages `.github/` files — pull request templates, workflow files, coding guidelines — all native to GitHub. But it never plants its own flag.

This was not a technical convenience. It was a principled boundary. It meant Carson could never become a dependency that locks users in. It meant offboarding is always clean: remove the managed files, and the repository returns to exactly the state it was in before Carson arrived. No residue. No lock-in. No awkward conversation about "we used to use this tool."

The outsider rule is an iron rule. It governs every design decision that follows.

## The Naming — 24 February 2026

Butler became Carson.

The name comes from Charles Carson, the head butler of Downton Abbey. He runs the household of Downton with absolute discipline and professional standards — but he never oversteps. He prepares everything for the family's decisions. He does not make those decisions himself. He maintains the estate in impeccable order. He does not own it.

The rename was more than branding. It crystallised a personality that the code had been reaching for. Carson is confident — not because it is arrogant, but because it knows things deeply well. It does not hedge. It does not guess. It does not ask unnecessary questions. It acts with the certainty of someone who has managed the household for decades and has seen every kind of mess.

When Carson speaks, it is brief and exact. When Carson is silent, that silence means everything is in order.

## 1.0 — The Foundation — 25 February 2026

Nine days. Versions 0.1.0 through 0.9.0. Then 1.0.

The surface area was defined: `onboard`, `audit`, `sync`, `template`, `prune`, `review gate`, `review sweep`, `offboard`, `refresh`. The exit status contract was locked down — the kind of contract that automation depends on: `0` means success, `2` means policy blocked (a known, expected state, not an error), `1` means something unexpected went wrong.

1.0 was not a celebration. It was the moment the bets stopped changing. The outsider principle. The template management model. The pre-commit hook integration. The audit pipeline. All settled. What followed would be depth, not direction changes.

## 2.0 — The Butler Becomes a Governor — 2 March 2026

The leap happened in a single day, driven by a single insight: if Carson can verify every PR's readiness, why can't it act on that verification?

The `govern` command was born. Cross-repository triage — Carson examines every open PR across all governed repositories, merges what is ready, dispatches coding agents to fix what is failing, and escalates only what needs human judgement. The human reviews the escalation list. Everything else was already handled.

`refresh --all` followed: keep templates synchronised across the entire estate without visiting each repository individually. One command, all repos, done.

Carson stopped being a linter. It became an autonomous governance runtime. The version bump from 1.x to 2.0 was earned. This was a different product now — one that acts, not just one that checks.

## The Voice — 3 March 2026

A wave of UX work transformed how Carson speaks. The insight that drove it was simple but ruthless: **every line Carson prints is a UI surface.** If a message does not help the user act, it is noise. Noise trains users to ignore messages. And then the important messages get ignored too.

Concise output became the default. Silence for health — if Carson says nothing, the user can trust the commit is clean. One actionable message for problems — what is wrong, what command fixes it. Verbose mode became the debugging channel, not the primary experience.

The onboard flow was rewritten three times. The post-install message was refined until it read like a confident professional introduction, not a technical dump. Every interactive prompt got the same treatment: one question, one clear default, and every response ending with a concrete next step. Never leave the user at a dead end asking "what now?"

This period established Carson's psychological contract with its users: **silence means safety.** When Carson speaks, listen — because it only speaks when something needs your attention.

## The Lint Reckoning — 4 March 2026

Carson 2.12.0 added MegaLinter integration. Four versions later, 2.19.0 stripped it back out.

The lesson was painful and valuable: Carson should not own lint policy. Lint is domain-specific. What counts as a lint violation in a Rails app is irrelevant to a data pipeline. The repository owner decides their lint rules — not Carson.

But what Carson *can* own is the **distribution mechanism**. The `template.canonical` config key was born: point it at a directory of files, and Carson appends them to its managed template set. The owner's lint rules, CI workflows, whatever they choose — they flow through Carson's template pipeline without Carson having any opinion about what those files say.

Carson carries the envelope. It does not write the letter.

This was the outsider principle applied beyond code. Carson does not have opinions about your domain. It has discipline about your process.

## Prune — 4–6 March 2026

Branch pruning tells you something about how a tool matures. Carson's prune started simple and grew sophisticated as reality proved simple was not enough.

**Stage 1** — stale branches. The remote deleted the branch, a merged PR confirms the work landed, safe to force-delete locally. Straightforward.

**Stage 2** — orphan branches. No upstream at all. But dig through GitHub's PR history, find a merged PR that matches the branch, and now you have evidence. Safe to delete.

**Stage 3** — absorbed branches. The upstream still exists, but content comparison against main proves the work is already there. The branch is a ghost — it looks alive but its purpose has been fulfilled.

**Stage 4** — the absorbed fallback. When a rebase merge rewrites commit hashes, SHA-based PR evidence fails. The commit that merged is technically a different commit from the one on the branch. But content comparison catches it — if the files on main match the files on the branch, the work landed. The evidence chain grew more sophisticated, but the principle stayed simple: **never delete a branch unless you can prove its work is already on main.**

Each stage was driven by a real gap encountered in daily use. Agents create branches. Rebase merges change SHAs. Cherry-picks land content without merge commits. Reality is messy. Prune has to be thorough.

## "Carson Is for Coding Agents" — 6 March 2026

The most important product insight arrived during a session about audit UX and worktree lifecycle.

**Carson is for coding agents, not for humans.**

The primary consumer of Carson's commands, lifecycle management, and governance is the coding agent working on behalf of the developer. The human developer benefits indirectly — when Carson keeps the agent's environment disciplined and predictable, the agent produces better work, and the human never has to intervene in housekeeping.

The ideal state: the human owner forgets Carson exists. Everything just works.

This reframed everything. The UX is not for human eyes scanning terminal output — it is for agents parsing structured signals. The exit codes are not for humans reading error messages — they are for automation making decisions. The silence-means-safety contract is not for human psychology alone — it is for agent confidence: if Carson did not block, proceed.

This became the theme of Carson 3.0.

## The Worktree Lesson — 6 March 2026

The same session that produced the agent-first insight also produced `carson worktree remove` — born from direct, repeated pain.

Coding agents work in git worktrees. When a worktree directory is deleted while the agent's shell is still inside it, the shell becomes permanently unusable. Every subsequent command fails. The session is effectively dead.

This happened over and over during a single working session. The escape hatch — recreating the directory with a file-write tool — was fragile and unreliable.

The safe teardown order became an iron rule:

1. Exit the worktree — move the shell to the main repository root.
2. `git worktree remove` — removes the directory and git registration.
3. Branch cleanup — delete the local branch, prune the remote.

If any step is skipped or reordered, the agent is stranded. Carson enforces this order in a single command so agents never have to remember it. One command, always safe, never leaves debris.

---

## Looking Forward — Carson 3.0

The vision is forming.

Carson shifts from per-repo onboarding to central oversight. Repositories are *registered* under Carson's protection, and Carson oversees all of them by default. The vocabulary changes from "onboard" to "register." You never need to know which repo you are standing in to manage the estate.

Every single-repo command gains cross-repo reach through one flag: `--all`. Same operation, wider scope. No separate commands, no different mental model. The flag says: do what you always do, but everywhere.

The core insight remains: **single-repo depth is the foundation.** Working on one repository thoroughly well is the essence. Multi-repo governance is the same discipline repeated across the estate. Get the single-repo story perfect. Multi-repo follows naturally.
