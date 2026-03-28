# Hook Architecture Research

Two independent hook systems protect governed repositories: **TAI hooks** and **Carson hooks**.
They do not chain. They operate at different layers.

---

## TAI Hooks (`~/AI/enforce/hooks/`)

**Purpose.** Enforce agent discipline and safety for the human developer's Claude Code sessions.
These hooks are the AI instruction layer — they have nothing to do with managed repositories.

**Two kinds of hooks live here:**

### Git hook (1)
- **Location:** `~/AI/enforce/hooks/git/pre-commit` (and `pre-commit.d/`)
- **Installed with:** `git config --global core.hooksPath ~/AI/enforce/hooks/git`
- **Consumed by:** Git — fires on every commit, in every repository on the machine
- **What it guards:** commits on main/master, secrets, `.rubocop.yml` project files, branch naming, diary format

### Claude Code hooks (13+)
- **Location:** `~/AI/enforce/hooks/<hook-name>` (flat, one script per hook)
- **Installed with:** entries in `~/.claude/settings.json` under `hooks`
- **Consumed by:** Claude Code — fires on PreToolUse, PostToolUse, Stop, SessionStart, PreCompact events
- **Examples:** `block-writing-on-main`, `block-bypassing-carson`, `detect-agent-halting`, `log-bash-errors`
- **`command-guard`** is referenced by these Claude Code hooks to detect whether the current repo is Carson-governed

TAI hooks are **not** installed per-repo. They live in one place and apply globally to the developer's machine.

---

## Carson Hooks (`~/.carson/hooks/`)

**Purpose.** Enforce git workflow safety inside each Carson-governed repository.
These hooks are the repository governance layer — they fire when git operations run in a governed repo.

**Four git hooks:**
- `pre-commit` — blocks commits on main, checks scope
- `prepare-commit-msg` — enforces commit message format
- `pre-merge-commit` — validates merge target
- `pre-push` — blocks direct push to main, checks unpushed commit safety

**One stable hook:**
- `command-guard` — installed at `~/.carson/hooks/command-guard` (non-versioned, stable path)
  - Referenced by TAI's Claude Code hooks via `~/.claude/settings.json`
  - Reads `~/.carson/config.json` to determine whether the current directory is Carson-governed
  - Must survive Carson upgrades without `settings.json` being updated → stable path is correct

**Templates live in Carson's repo at:** `config/hooks/<hook-name>`

**Installation:** `carson refresh` copies templates into `hooks_dir`, sets `git config core.hooksPath <hooks_dir>`.

---

## How They Interact

Git resolves hooks via `core.hooksPath`. **Local repo config beats global config.**

| Layer | Scope | `core.hooksPath` |
|-------|-------|-----------------|
| Global (TAI) | All repos on machine | `~/AI/enforce/hooks/git` |
| Local (Carson) | This governed repo | `~/.carson/hooks/<VERSION>/` |

In a Carson-governed repository, the local config wins. Carson's 4 git hooks run; TAI's global git pre-commit does **not** run.

This is intentional: Carson hooks encode the full repository safety policy. TAI's git pre-commit is a fallback for ungoverned repos.

Claude Code hooks are **not** affected by `core.hooksPath` — they fire from `settings.json` regardless.

---

## Root Cause: Version Accumulation

**The problem.** `~/.carson/hooks/` currently contains 93 versioned directories (0.8.0 through 4.3.2).

**The cause.** In `lib/carson/runtime/local/hooks.rb:164-165`:

```ruby
def hooks_dir
  File.expand_path( File.join( config.hooks_path, Carson::VERSION ) )
end
```

Every `carson refresh` on a new Carson version creates a new directory. `git config core.hooksPath` is updated to point to the new one. Old directories are never cleaned up.

**Why VERSION was added** (speculative): so that older repos that haven't been refreshed yet still use the hooks that match the Carson version that originally onboarded them. In practice: the user always runs the latest Carson everywhere, so this safety net has no value.

---

## Proposed Fix

**One-line change.** Drop the VERSION suffix from `hooks_dir`:

```ruby
def hooks_dir
  File.expand_path( config.hooks_path )
end
```

**Effect:**
- All 4 managed hooks are written to `~/.carson/hooks/` directly
- `carson refresh` overwrites them in-place on every upgrade
- `core.hooksPath` is set once at onboard and never needs updating
- `command-guard` is already at the stable non-versioned path — unchanged
- `workflow_style` file also written to this flat directory — unchanged

**Migration.** The 93 old versioned directories need a one-time cleanup:

```sh
ls ~/.carson/hooks/ | grep -v command-guard | xargs -I{} rm -rf ~/.carson/hooks/{}
```

Or more precisely: remove everything under `~/.carson/hooks/` that is a directory (the versioned dirs), leaving only `command-guard` and the 4 new flat hook files written by `carson refresh`.

**Open question.** Does Carson currently chain to any per-repo `.git/hooks/` after setting `core.hooksPath`? If not, any pre-existing per-repo hooks are already silenced by `core.hooksPath` — no change in behaviour from the fix.
