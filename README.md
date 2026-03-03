<img src="icon.svg" width="141" alt="Carson">

# ⧓ Carson

Named after the head of household in Downton Abbey, Carson is your repositories' autonomous governance runtime — you write the code, Carson manages everything else. From commit-time checks through PR triage, agent dispatch, merge, and cleanup, Carson runs the household with discipline and professional standards. Carson itself has no intelligence — it follows a deterministic decision tree. The intelligence comes from the coding agents it dispatches (Codex, Claude) to fix problems.

## The Problem

If you govern more than a handful of repositories, you know the pattern: lint configs drift between repos, PR templates go stale, reviewer feedback gets quietly ignored, and what passes on a developer's laptop fails in CI. Across a portfolio of projects with coding agents producing many PRs, you become the bottleneck — manually checking results, dispatching fixes, clicking merge, and cleaning up.

## How Carson Works

Carson is an autonomous governance runtime that lives on your workstation and in CI, never inside the repositories it governs. It operates at two levels:

**Per-commit governance** — Carson gates merges on unresolved review comments, synchronises templates, and keeps your local branches clean. Every commit triggers `carson audit` through managed hooks; the same checks run in GitHub Actions. Lint execution is handled entirely by MegaLinter in CI and by the developer's own local tooling — Carson distributes the shared lint configuration but does not run linters itself.

**Portfolio-level autonomy** — `carson govern` is a scheduled triage loop that scans all your repositories, classifies every open PR, and acts: merge what's ready, dispatch coding agents (Codex or Claude) to fix what's failing, and escalate what needs human judgement. One command, all your projects, unmanned.

```
┌──────────────────────────────────────────────┐
│  Your workstation                             │
│                                               │
│  ~/.carson/            Carson config          │
│  ~/.carson/hooks/      Git hooks              │
│  ~/.carson/cache/      Reports                │
│  ~/.carson/govern/     Dispatch state         │
│                                               │
│  carson govern ──► for each repo:             │
│    1. List open PRs (gh)                      │
│    2. Classify: CI / review / audit status    │
│    3. Act: merge | dispatch agent | escalate  │
│    4. Housekeep: sync + prune                 │
│                                               │
│  Governed repos:  repo-A/  repo-B/  repo-C/   │
│    .github/* templates (committed)            │
│    core.hooksPath → ~/.carson/hooks           │
└──────────────────────────────────────────────┘
```

This separation is Carson's defining trait — the **outsider boundary**: no Carson scripts, config files, or governance payloads are ever placed inside a governed repository.

### The Governance Loop

Carson orchestrates a closed governance loop across three layers:

1. **Policy distribution** — `carson lint policy` distributes shared lint configs from a central source into each repo's `.github/linters/`. This is the single source of truth for lint rules across all governed repositories.
2. **CI enforcement** — MegaLinter runs in GitHub Actions (via the managed `carson-lint.yml` workflow) and auto-discovers configs from `.github/linters/`. Carson does not run linters — MegaLinter does. Carson's `audit` gates on CI check status reported by GitHub.
3. **Autonomous triage** — `carson govern` reads CI status (including MegaLinter results), review disposition, and audit health for every open PR. Ready PRs are merged. Failing PRs get a coding agent (Codex or Claude) dispatched to fix them. Stuck PRs are escalated.

Carson's role is governance orchestration — distributing policy, gating on results, and dispatching action. The actual lint execution, CI runs, and code fixes are delegated to specialised tools: MegaLinter for linting, GitHub Actions for CI, and coding agents for remediation.

## Opinions

Carson is opinionated about governance. These are non-negotiable principles, not configurable defaults:

- **Outsider boundary** — Carson lives outside your repo, never inside. No Carson-owned artefacts in your repository. Offboarding leaves no trace.
- **Centralised lint** — lint policy distributed from a central source into each repo's `.github/linters/`. One source of truth, zero drift. MegaLinter enforces it in CI.
- **Active review** — undisposed reviewer findings block merge. Feedback must be acknowledged, not buried.
- **Self-diagnosing output** — every message names the cause and the fix. If you need to debug Carson's output, the output failed.
- **Transparent governance** — Carson prepares everything for merge but never oversteps. It does not make decisions for you without telling you.

Everything else — workflow style, merge method, remote name, main branch — is a configurable default chosen during `carson setup`. See `MANUAL.md` for the full list of defaults and why each was chosen.

The data flow:

1. You maintain a **policy source** — a directory or git repository containing your lint config files (e.g. `.rubocop.yml`, `biome.json`, `ruff.toml`). `carson lint policy --source <repo>` copies these into each governed repo's `.github/linters/`, where MegaLinter auto-discovers them.
2. `carson onboard` installs git hooks, synchronises `.github/*` templates (including a MegaLinter CI workflow), and runs a first governance audit on a host repository.
3. From that point, every commit triggers `carson audit` through the managed `pre-commit` hook. The same `carson audit` runs in GitHub Actions. If it passes locally, it passes in CI.
4. `carson review gate` enforces review accountability: it blocks merge until every actionable reviewer comment has been formally acknowledged by the PR author through a **disposition comment**.
5. `carson govern` triages all open PRs across your portfolio. Ready PRs are merged and housekept. Failing PRs get a coding agent dispatched to fix them. Stuck PRs are escalated for your attention.

## Commands at a Glance

**Govern** — autonomous portfolio management:

| Command | What it does |
|---|---|
| `carson govern` | Triage all open PRs: merge ready ones, dispatch agents for failures, escalate the rest. |
| `carson govern --dry-run` | Show what Carson would do without taking action. |
| `carson govern --loop SECONDS` | Run the govern cycle continuously, sleeping SECONDS between cycles. |
| `carson housekeep` | Sync main + prune stale branches (also runs automatically after govern merges). |

**Setup** — run once per machine or per repository:

| Command | What it does |
|---|---|
| `carson lint policy --source <repo>` | Distribute lint configs from policy source into `.github/linters/`. |
| `carson onboard` | One-command baseline: hooks + templates + first audit. |
| `carson prepare` | Install or refresh Carson-managed global hooks. |
| `carson refresh` | Re-apply hooks, templates, and audit after upgrading Carson. |
| `carson refresh --all` | Refresh all governed repositories at once. |
| `carson offboard` | Remove Carson from a repository. |

**Daily** — regular development workflow:

| Command | What it does |
|---|---|
| `carson audit` | Full governance check (also runs automatically on every commit). |
| `carson sync` | Fast-forward local `main` from remote. |
| `carson prune` | Remove stale local branches whose upstream is gone. |
| `carson template check` | Detect drift between managed and host `.github/*` files. |
| `carson template apply` | Repair drifted `.github/*` files. |

**Review** — PR merge readiness:

| Command | What it does |
|---|---|
| `carson review gate` | Block or approve merge based on unresolved review comments. |
| `carson review sweep` | Scan recent PRs and update a tracking issue for late feedback. |

**Info**:

| Command | What it does |
|---|---|
| `carson version` | Print installed version. |
| `carson inspect` | Verify Carson-managed hook installation and repository setup. |

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your PATH.
`gh` (GitHub CLI) is recommended for full review governance features.

```bash
# Install
gem install --user-install carson
carson version
```

**Prepare your lint policy.** A policy source is any directory (or git URL) containing your lint configuration files (`.rubocop.yml`, `biome.json`, `ruff.toml`, etc.). Carson copies these into the governed repo's `.github/linters/` where MegaLinter auto-discovers them:

```bash
carson lint policy --source /path/to/your-policy-repo
```

**Onboard a repository:**

```bash
carson onboard /path/to/your-repo
```

After `carson onboard`, your repository has:
- Git hooks that run `carson audit` on every commit.
- Managed `.github/*` templates synchronised from Carson.
- An initial governance audit report.

Commit the generated `.github/*` changes, and the repository is governed.

**Daily workflow:**

```bash
carson govern --dry-run     # see what Carson would do across all repos
carson govern               # triage PRs, merge ready ones, dispatch agents, housekeep
carson govern --loop 300    # run continuously, cycling every 5 minutes
```

Or the individual commands if you prefer manual control:

```bash
carson audit                # full governance check
carson review gate          # block or approve merge based on review status
carson sync                 # fast-forward local main
carson prune                # clean up stale local branches
```

## Where to Read Next

- **MANUAL.md** — installation, first-time setup, CI configuration, daily operations, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.
- **RELEASE.md** — version history and upgrade actions.
- **docs/define.md** — product definition and scope.
- **docs/design.md** — experience and brand design.
- **docs/develop.md** — contributor guide: architecture, development workflow.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
