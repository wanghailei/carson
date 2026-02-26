# Carson

Named after the head butler of Downton Abbey, Carson is your repositories' master butler — you write the code, Carson manages everything else. From commit-time checks through merge-readiness on GitHub to cleaning up locally afterwards, Carson runs the household with discipline and professional standards, without ever overstepping.

## The Problem

If you govern more than a handful of repositories, you know the pattern: lint configs drift between repos, PR templates go stale, reviewer feedback gets quietly ignored, and what passes on a developer's laptop fails in CI.
The usual fix is to copy governance scripts into each repository. That works until you need to update them — now you are maintaining dozens of copies, each free to diverge.

## How Carson Works

Carson is a governance runtime that lives on your workstation and in CI, never inside the repositories it governs. You focus on writing code; Carson handles the rest — enforcing lint policy, gating merges on unresolved review comments, synchronising templates, and keeping your local branches clean. This separation is its defining trait — called the **outsider boundary**: no Carson scripts, config files, or governance payloads are ever placed inside a *governed repository* (also called a **host repository** — any git repo that Carson manages).

```
┌─────────────────────────────────────┐
│  Your workstation                   │
│                                     │
│  ~/.carson/          Carson config  │
│  ~/.carson/hooks/    Git hooks      │
│  ~/AI/CODING/        Lint policy    │
│  ~/.cache/carson/    Audit reports  │
│                                     │
│  carson audit ───► governs ────►  repo-A/
│                                   repo-B/
│                                   repo-C/
│                                     │
│  Governed repos get only:           │
│    .github/* templates (committed)  │
│    core.hooksPath → ~/.carson/hooks │
└─────────────────────────────────────┘
```

The data flow:

1. You maintain a **policy source** — a directory or git repository containing your lint rules (e.g. `CODING/rubocop.yml`). Carson copies these to `~/AI/CODING/` via `carson lint setup`.
2. `carson init` installs git hooks, synchronises `.github/*` templates, and runs a first governance audit on a host repository.
3. From that point, every commit triggers `carson audit` through the managed `pre-commit` hook. The same `carson audit` runs in GitHub Actions. If it passes locally, it passes in CI.
4. `carson review gate` enforces review accountability: it blocks merge until every actionable reviewer comment — risk keywords, change requests — has been formally acknowledged by the PR author through a **disposition comment** (a reply with a configured prefix, e.g. `Disposition: ...`).
5. `carson audit` also checks **scope integrity** — verifying that staged changes stay within expected feature/module path boundaries — and confirms that no Carson artefacts have leaked into the host repository (the outsider boundary).

All governance checks are **advisory checks**: they produce deterministic pass/block results (exit `0` or `2`) that CI and hooks consume, but Carson never force-merges or bypasses GitHub's own merge authority.

## Commands at a Glance

**Setup** — run once per machine or per repository:

| Command | What it does |
|---|---|
| `carson lint setup` | Seed `~/AI/CODING/` from your policy source. |
| `carson init` | One-command baseline: hooks + templates + first audit. |
| `carson hook` | Install or refresh Carson-managed global hooks. |
| `carson refresh` | Re-apply hooks, templates, and audit after upgrading Carson. |
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
| `carson check` | Verify Carson-managed hook installation and repository setup. |

## Quickstart

Prerequisites: Ruby `>= 4.0`, `git`, and `gem` in your PATH.
`gh` (GitHub CLI) is recommended for full review governance features.

```bash
# Install
gem install --user-install carson
carson version
```

**Prepare your lint policy.** A policy source is any directory (or git URL) that contains a `CODING/` folder with your lint configuration files. For Ruby, the required file is `CODING/rubocop.yml`. Carson copies these into `~/AI/CODING/` so that every governed repository uses the same rules:

```bash
carson lint setup --source /path/to/your-policy-repo
```

**Onboard a repository:**

```bash
carson init /path/to/your-repo
```

After `carson init`, your repository has:
- Git hooks that run `carson audit` on every commit.
- Managed `.github/*` templates synchronised from Carson.
- An initial governance audit report.

Commit the generated `.github/*` changes, and the repository is governed.

**Daily workflow:**

```bash
carson sync                 # fast-forward local main
carson audit                # full governance check
carson review gate          # block or approve merge based on review status
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
