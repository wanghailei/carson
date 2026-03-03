<img src="icon.svg" width="141" alt="Carson">

# ⧓ Carson

*Carson at your service.*

Named after the head of household in Downton Abbey, Carson is your repositories' autonomous governance runtime — you write the code, Carson manages everything else. From commit-time checks through PR triage, agent dispatch, merge, and cleanup, Carson runs the household with discipline and professional standards. Carson itself has no intelligence — it follows a deterministic decision tree. The intelligence comes from the coding agents it dispatches (Codex, Claude) to fix problems.

## The Problem to Solve

Managing a growing portfolio of repositories is rewarding work — but the operational overhead scales faster than the code itself. Lint configs drift between repos, PR templates go stale, reviewer feedback gets quietly buried, and what passes on a developer's laptop fails in CI. When coding agents start producing PRs across multiple projects, the coordination load multiplies: checking results, dispatching fixes, clicking merge, cleaning up branches.

Carson exists so you can focus on what matters — building — while governance runs itself.

## How Carson Works

Carson is an autonomous governance runtime that lives on your workstation and in CI, never inside the repositories it governs. It operates at two levels:

**Per-commit governance** — Carson gates merges on unresolved review comments, synchronises templates, and keeps your local branches clean. Every commit triggers `carson audit` through managed hooks; the same checks run in GitHub Actions. Lint execution is handled entirely by MegaLinter in CI and by the developer's own local tooling — Carson distributes the shared lint configuration but does not run linters itself.

**Portfolio-level autonomy** — `carson govern` is a triage loop that scans your registered repositories, classifies every open PR, and acts: merge what's ready, dispatch coding agents (Codex or Claude) to fix what's failing, and escalate what needs human judgement. One command, all your projects, unmanned.

```
  ~/.carson/                     ← Carson lives here, never inside your repos
       │
       ├─ hooks ──────────────►  commit gates      (every governed repo)
       ├─ lint configs ───────►  .github/linters/  (MegaLinter auto-discovers)
       └─ govern ─────────────►  PR triage → merge | dispatch agent | escalate
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
- **Self-diagnosing output** — every warning and error names what went wrong, why, and what to do next. If you have to read source code to understand a message, that message is a bug.
- **Transparent governance** — Carson prepares everything for merge but never oversteps. It does not make decisions for you without telling you.

Everything else bends to your preference. Which branch is main, how PRs are merged, which repositories to govern, which coding agent to dispatch, where your lint policy lives — Carson asks during setup and remembers. Sensible defaults are provided; you only change what matters to you. See `MANUAL.md` for the full list.

## Quickstart

Prerequisites: Ruby `>= 3.4`, `git`, and `gem` in your PATH. `gh` (GitHub CLI) is recommended for full review governance features.

```bash
gem install carson
```

**Onboard a repository:**

```bash
carson onboard /path/to/your-repo
```

On first run, Carson walks you through setup — remote, main branch, workflow style, merge method — then installs hooks, syncs templates, and runs an initial audit.

After `carson onboard`, your repository has:
- Git hooks that run `carson audit` on every commit.
- Managed `.github/*` templates synchronised from Carson.
- An initial governance audit report.

Commit the generated `.github/*` changes, and the repository is governed.

**Set up lint policy** (optional). If you have a central directory or repository of lint configs, point Carson at it — configs are copied into `.github/linters/` where MegaLinter auto-discovers them:

```bash
# local directory
carson lint policy --source /path/to/your-policy-dir

# remote repository
carson lint policy --source https://github.com/you/lint-policy.git
```

**Govern your portfolio.** Once repositories are onboarded, `carson govern` is your recurring command. Run it whenever you want Carson to triage open PRs, enforce review policy, dispatch coding agents, and housekeep across all governed repos:

```bash
carson govern --dry-run     # preview what Carson would do, change nothing
carson govern               # triage PRs, merge ready ones, dispatch agents, housekeep
carson govern --loop 300    # run continuously, cycling every 5 minutes
```

## Where to Read Next

- **MANUAL.md** — installation, first-time setup, CI configuration, daily operations, full command reference, troubleshooting.
- **API.md** — formal interface contract: commands, exit codes, configuration schema.

## Support

- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
