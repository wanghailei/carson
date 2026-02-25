# Carson

Enforce the same governance rules across every repository you manage — from a single install, without polluting any of them with governance tooling.

## The Problem

If you govern more than a handful of repositories, you know the pattern: lint configs drift between repos, PR templates go stale, reviewer feedback gets quietly ignored, and what passes on a developer's laptop fails in CI.
The usual fix is to copy governance scripts into each repository. That works until you need to update them — now you are maintaining dozens of copies, each free to diverge.

## What Carson Does

Carson is a governance runtime that lives on your workstation and in CI, never inside the repositories it governs. You install it once, point it at each repository, and it enforces a consistent baseline — same checks, same rules, same exit codes — everywhere.

**One command to onboard a repo.**
`carson init` installs git hooks, synchronises PR and AI-coding templates, and runs a first governance audit. From that point, every commit is checked automatically.

**Same checks locally and in CI.**
The `pre-commit` hook runs `carson audit` before every commit. The same `carson audit` runs in your GitHub Actions workflow. If it passes locally, it passes in CI. No surprises.

**Review accountability.**
`carson review gate` blocks merge until every actionable reviewer comment — risk keywords, change requests — has been formally acknowledged by the PR author. No more "I missed that comment" after merge.

**Template consistency.**
Carson keeps PR templates and AI coding guidelines identical across all governed repositories. Drift is detected on every audit; `carson template apply` repairs it.

**Centralised lint policy.**
Lint rules come from a single policy source you control. Carson owns the lint execution path — repo-local config overrides are hard-blocked so teams cannot silently weaken the baseline.

**Branch hygiene.**
`carson sync` fast-forwards your local main. `carson prune` removes branches whose upstream is gone, including squash-merged branches verified through the GitHub API.

**Clean boundary.**
No Carson scripts, config files, or governance payloads are ever placed inside your repositories. Carson actively blocks if it detects its own artefacts in a host repo.

## When to Use Carson

- A platform team standardising policy across many product repositories — one governance flow for all of them, no per-repo tooling.
- A consultancy governing client repositories you do not own — enforce rules without committing your tooling into their repos.
- A regulated engineering team that needs auditable, reproducible gates — every merge decision has a deterministic pass/block result.
- A solo developer who wants the same lint and review discipline everywhere — without maintaining governance scripts in each project.

## Quickstart

Prerequisites: Ruby `>= 4.0`, `git`, and `gem` in your PATH.
`gh` (GitHub CLI) is recommended for full review governance features.

```bash
# Install
gem install --user-install carson
carson version

# Prepare your lint policy baseline
carson lint setup --source /local/path/of/policy-repo

# Onboard a repository
carson init /local/path/of/repo
```

After `carson init`, your repository has:
- Git hooks that run `carson audit` on every commit.
- Managed `.github/*` templates synchronised from Carson.
- An initial governance audit report.

Commit the generated `.github/*` changes, and the repository is governed.

**Daily workflow:**

```bash
carson sync                 # fast-forward local main
carson audit                # full governance check (also runs on every commit via hook)
carson review gate          # block or approve merge based on review status
carson prune                # clean up stale local branches
```

## Where to Read Next
- User manual: `MANUAL.md`
- API reference: `API.md`
- Release notes: `RELEASE.md`

## Support
- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
