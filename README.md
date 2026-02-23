# Butler

Butler is an outsider governance runtime for GitHub repositories.

It runs from your workstation, applies governance consistently, and avoids placing Butler-owned tooling inside client repositories.

## Why Butler

- keeps GitHub as merge authority
- enforces local hard protection and review discipline
- provides deterministic governance checks with stable exit codes
- keeps host repositories clean from Butler runtime artefacts

## Quick start (about 10 minutes)

### 1) Prerequisites

- Ruby `>= 4.0`
- `gem`, `git`, and `gh` available in `PATH`

### 2) Install Butler

```bash
gem install --user-install butler-to-merge -v 0.6.0
```

If `butler` is not found after install:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

### 3) Verify installation

```bash
butler version
```

Expected: `0.6.0` (or newer).

### 4) Bootstrap one repository

```bash
butler init /local/path/of/repo
```

Expected outcomes:

- remote aligned to `github` when required
- hooks installed under `~/.butler/hooks/<version>/`
- commit-time governance gate enabled via managed `pre-commit` hook
- `.github` managed files synced
- initial audit executed

### 5) Commit managed GitHub files

Commit generated `.github/*` files in the client repository.

## CI quick start (pinned)

In client repositories, pin the reusable workflow to an immutable commit SHA and pin the Butler version explicitly.

```yaml
name: Butler policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/butler/.github/workflows/butler_policy.yml@9dafd1b32042dc064b9cea743fd02c933d2322a8
    with:
      butler_version: "0.6.0"
```

When upgrading Butler, update both values together.

## Daily minimum

```bash
butler sync
butler audit
butler prune
```

Before recommending merge:

```bash
butler review gate
```

For scheduled late-review monitoring (for example every 8 hours in CI):

```bash
butler review sweep
```

## Outsider boundary

Blocked Butler fingerprints in host repositories:

- `.butler.yml`
- `bin/butler`
- `.tools/butler/*`
- legacy Butler marker artefacts

Allowed managed persistence:

- selected GitHub-native files under `.github/*`

## Exit contract

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Where to read next

- user onboarding and workflows: `docs/butler_user_guide.md`
- technical behaviour and architecture: `docs/butler_tech_guide.md`
- contributor/internal install path: `docs/butler_dev_guide.md`
- version history and migration notes: `RELEASE.md`
