# Carson

Carson is an outsider governance runtime for GitHub repositories.

It runs from your workstation, applies governance consistently, and avoids placing Carson-owned tooling inside client repositories.

## Why Carson

- keeps GitHub as merge authority
- enforces local hard protection and review discipline
- provides deterministic governance checks with stable exit codes
- keeps host repositories clean from Carson runtime artefacts

## Quick start (about 10 minutes)

### 1) Prerequisites

- Ruby `>= 4.0`
- `gem`, `git`, and `gh` available in `PATH`

### 2) Install Carson

```bash
gem install --user-install carson -v 0.6.1
```

If `carson` is not found after install:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

### 3) Verify installation

```bash
carson version
```

Expected: `0.6.1` (or newer).

### 4) Bootstrap one repository

```bash
carson init /local/path/of/repo
```

Expected outcomes:

- canonical remote name is `github` (`origin` is renamed when required)
- hooks installed under `~/.carson/hooks/<version>/`
- commit-time governance gate enabled via managed `pre-commit` hook
- `.github` managed files synced
- initial audit executed

Remote check:

```bash
git -C /local/path/of/repo remote get-url github
```

### 5) Commit managed GitHub files

Commit generated `.github/*` files in the client repository.

## CI quick start (pinned)

In client repositories, pin the reusable workflow to an immutable commit SHA and pin the Carson version explicitly.

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v0.6.1
    with:
      carson_ref: "v0.6.1"
      carson_version: "0.6.1"
```

When upgrading Carson, update both values together.

## Daily minimum

```bash
carson sync
carson audit
carson prune
```

Before recommending merge:

```bash
carson review gate
```

For scheduled late-review monitoring (for example every 8 hours in CI):

```bash
carson review sweep
```

## Outsider boundary

Blocked Carson fingerprints in host repositories:

- `.carson.yml`
- `bin/carson`
- `.tools/carson/*`

Allowed managed persistence:

- selected GitHub-native files under `.github/*`

## Exit contract

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Where to read next

- user onboarding and workflows: `docs/carson_user_guide.md`
- technical behaviour and architecture: `docs/carson_tech_guide.md`
- contributor/internal install path: `docs/carson_dev_guide.md`
- version history and migration notes: `RELEASE.md`
