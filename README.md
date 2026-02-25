# Carson

Carson is an outsider governance runtime for teams that need predictable GitHub policy controls without placing Carson-owned tooling inside client repositories.

## Introduction
Repository governance often drifts over time: local protections weaken, review actions are missed, and policy checks become inconsistent between contributors.
Carson solves this by running from your workstation or CI, applying a deterministic governance baseline, and managing only selected GitHub-native policy files where necessary.
This model is effective because ownership stays explicit: Carson runtime assets remain outside host repositories, while merge authority remains with GitHub branch protection and human review.

## Quickstart
Prerequisites:
- Ruby `>= 4.0`
- `gem`, `git`, and `gh` available in `PATH`

```bash
gem install --user-install carson -v 0.7.0
carson version
carson init /local/path/of/repo
```

Expected result:
- `carson version` prints `0.7.0` (or newer).
- `carson init` aligns remote naming, installs Carson-managed hooks, synchronises managed `.github/*` files, and runs an initial audit.
- Your repository is ready for daily governance commands.

## Where to Read Next
- User manual: `MANUAL.md`
- API reference: `API.md`
- Release notes: `RELEASE.md`

## Core Capabilities
- Outsider boundary enforcement that blocks Carson-owned host artefacts (`.carson.yml`, `bin/carson`, `.tools/carson/*`).
- Deterministic governance checks with stable exit codes for local and CI automation.
- Managed `.github/*` template synchronisation with drift detection and repair.
- Review governance controls (`review gate`, `review sweep`) for actionable feedback handling.
- Local branch hygiene and fast-forward sync workflow (`sync`, `prune`).

## Support
- Open or track issues: <https://github.com/wanghailei/carson/issues>
- Review version-specific upgrade actions: `RELEASE.md`
