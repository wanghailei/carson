# Carson Definition

> **Purpose:** What Carson is — identity, scope, principles, brand.
> **Audience:** Humans and agents.

---

## One-sentence identity

Carson is a worktree-first branch delivery governor for coding agents: it starts work safely, lands branches through a disciplined PR flow, and cleans up with proof rather than optimism.

## What Carson is

- **An outsider tool** — governs repositories without becoming their runtime dependency. No `.carson.yml`, no `bin/carson`, no `.tools/carson/` inside governed repos. Managed files are limited to `.github/*` templates.
- **A branch-delivery system** — the branch is the delivery unit; the worktree is the isolation container.
- **A truth surface** — `status`, `audit`, merge proof, and govern tell the operator what is actually true, not what Carson hoped would happen.
- **Single-repo first** — portfolio govern matters, but the product only works if one repository works boringly well.
- **For coding agents** — the primary user is the coding agent working on behalf of the developer. The human benefits indirectly: when Carson keeps the agent's environment disciplined, the agent produces better work.

## What Carson is not

- Not a generic repo automation platform.
- Not a local-authority workflow (today).
- Not a background daemon that owns everything.
- Not a substitute for GitHub CI, review, or branch protection.
- Not successful just because it prints decisive-looking output.

## Two-audience command model

| Audience | Scope | Commands |
|---|---|---|
| **Agent** | Single repo (CWD or explicit) | `worktree create`, `worktree list`, `deliver`, `status`, `audit`, `recover` |
| **Human** | Portfolio-wide | `list`, `onboard`, `offboard`, `refresh`, `version` |

Agents work with Carson at the per-repo level only. They create a workspace, deliver work, and check status — nothing else. All other repo operations (sync, prune, housekeep, abandon, review, receive, setup, template) are internal to Carson and run automatically via strategies.

Portfolio commands are for the human operator managing which repositories Carson governs. Agents never call portfolio commands.

## Directory model

Two `.github/` directories serve different roles:

| Directory | Purpose | Contents |
|-----------|---------|----------|
| `config/hooks/` | Distribution payload — git hooks Carson installs into governed repos | `pre-commit`, `pre-push`, `command-guard`, etc. (installed to `~/.carson/hooks/`) |
| `.github/` | Carson serving itself — Carson's own repo configuration | `workflows/`, `linters/` |

`config/hooks/` is the source of truth for git hooks Carson distributes. These are local git hooks, not GitHub configuration — they have no relationship to `.github/`. `carson refresh` reads from here when installing hooks into governed repos.

## Scope

**In scope:** Agent repo commands (`worktree create/list`, `deliver`, `status`, `audit`, `recover`), human portfolio commands (`list`, `onboard`, `offboard`, `refresh`, `version`), internal strategies (sync, prune, housekeep, review, receive, template), managed `.github/*` templates, strict exit status contract.

**Out of scope:** Non-squash integration policies, business-domain policy for host repos, force merges or check bypasses, Carson configuration inside host repos.

## Three ideas to protect

1. **Truth beats convenience.** If Carson cannot prove something, it blocks or says unknown.
2. **Main-tree safety beats eager cleanup.** Carson never makes the user's main worktree collateral damage.
3. **One story beats clever surfaces.** Branch origin, delivery truth, cleanup rules, docs, and output all describe the same operating model.

## Brand

**Mark:** ⧓ (U+29D3 BLACK BOWTIE) — prefixes all CLI output. Named after the Downton Abbey butler's white-tie evening dress.

**Voice:** Measured, direct, never flustered. States facts, prescribes actions. Does not apologise for blocks, celebrate successes, or editorialize.

**Signal system:**
- **Silence** — success. No output on clean pass.
- **Badge** — all non-silent output prefixed with ⧓.
- **Exit codes** — `0` success, `1` unexpected error, `2` policy block.

**Output structure:** state → reason → action. The state word appears first in caps. The reason is one line. The action is an exact command to copy and run.

**Vocabulary:**

| Preferred | Avoid |
|---|---|
| policy block | error, failure, violation |
| governance check | linting, validation |
| disposition | acknowledgement, note |
| outsider boundary | isolation, sandbox |
| merge-ready | approved, green |
| review thread | comment, note |
| managed file | owned file, Carson file |

## Interactive prompts

1. One question per prompt.
2. One clear default shown in brackets: `[Y/n]`.
3. Every answer leads to a next step.
4. TTY guard: skip prompt and apply default when stdin is not a TTY.

## User journeys

**Agent journey:**
1. **Start work** — `carson worktree create feature-x`. Isolated workspace, synced main, fresh branch.
2. **Code** — commit normally. Silence means safety. Blocks are actionable and exact.
3. **Deliver** — `carson deliver`. Carson handles push, PR, merge, and cleanup.
4. **Check** — `carson status` or `carson audit` when needed.

**Human journey:**
1. **Install** — `gem install carson`. No configuration wizard.
2. **Onboard** — `carson onboard <repo>`. Asks only what it cannot detect. One-time.
3. **Portfolio** — `carson list` shows all repos. `carson refresh` maintains all.
4. **Offboard** — `carson offboard <repo>` removes everything cleanly. No residue.
