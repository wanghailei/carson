# Carson

Carson is an outsider governance runtime for teams that need predictable GitHub policy controls without placing Carson-owned tooling inside client repositories.

## Introduction
Repository governance often drifts over time: local protections weaken, review actions are missed, and policy checks become inconsistent between contributors.
Carson solves this by running from your workstation or CI, applying a deterministic governance baseline, and managing only selected GitHub-native policy files where necessary.
This model is effective because ownership stays explicit: Carson runtime assets remain outside host repositories, while merge authority remains with GitHub branch protection and human review.

## Quickstart
Prerequisites:
- Ruby `>= 4.0`
- `gem` and `git` available in `PATH`
- `gh` available in `PATH` for PR/check reporting (recommended, not required for core local commands)

```bash
gem install --user-install carson -v 0.9.0
carson version
carson lint setup --source /path/to/ai-policy-repo
carson init /local/path/of/repo
```

Expected result:
- `carson version` prints `0.9.0` (or newer).
- `carson lint setup` seeds `~/AI/CODING` from your explicit source.
- Ruby lint policy data is sourced from `~/AI/CODING/rubocop.yml`; Ruby lint execution stays Carson-owned.
- Policy files live directly under `~/AI/CODING/` (no per-language subdirectories).
- `carson init` aligns remote naming, installs Carson-managed hooks, synchronises managed `.github/*` files, and runs an initial audit.
- Your repository is ready for daily governance commands.

## Where to Read Next
- User manual: `MANUAL.md`
- API reference: `API.md`
- Release notes: `RELEASE.md`

## Core Capabilities
- Outsider boundary enforcement that blocks Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson/*`).
- Deterministic governance checks with stable exit codes for local and CI automation.
- Ruby lint governance from `~/AI/CODING/rubocop.yml` with Carson-owned execution and deterministic local/CI blocking.
- Hard policy block when a client repository contains repo-local `.rubocop.yml`.
- Non-Ruby lint language entries remain present but disabled by default in this phase.
- Managed `.github/*` template synchronisation with drift detection and repair.
- Review governance controls (`review gate`, `review sweep`) for actionable feedback handling.
- Local branch hygiene and fast-forward sync workflow (`sync`, `prune`).

## Support
- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
