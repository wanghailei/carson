# Carson Manual

This manual is for users who need to install Carson, configure repository governance, and run a stable daily operating cadence.

## Prerequisites
- Ruby `>= 4.0`
- `gem` in `PATH`
- `git` in `PATH`
- `gh` in `PATH` (recommended for full review governance features)

## Install Carson

Recommended installation path:

```bash
gem install --user-install carson -v 0.8.0
```

If `carson` is not found after installation:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

Verify installation:

```bash
carson version
```

Expected result:
- Carson version is printed.
- The `carson` command is available in your shell.

## Configure your first repository
Assume your repository path is `/local/path/of/repo`.

Prepare your global lint policy baseline first:

```bash
carson lint setup --source /path/to/ai-policy-repo
```

`lint setup` expects the source to contain `CODING/` and writes policy files to `~/AI/CODING/`.
Use `--ref <git-ref>` when `--source` is a git URL.
Use `--force` to overwrite existing `~/AI/CODING` files.

Run baseline initialisation:

```bash
carson init /local/path/of/repo
```

`init` performs:
- remote alignment using configured `git.remote` (default `github`)
- hook installation under `~/.carson/hooks/<version>/`
- repository `core.hooksPath` alignment to Carson global hooks
- commit-time governance gate via managed `pre-commit` hook
- managed `.github/*` template synchronisation
- initial governance audit

After `init`, commit generated `.github/*` changes in your repository.

## Pin Carson in CI
Use the reusable workflow with explicit release pins:

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v0.8.0
    secrets:
      CARSON_READ_TOKEN: ${{ secrets.CARSON_READ_TOKEN }}
    with:
      carson_ref: "v0.8.0"
      carson_version: "0.8.0"
```

When upgrading Carson, update both `carson_ref` and `carson_version` together.
`CARSON_READ_TOKEN` must have read access to `wanghailei/ai` so CI can run `carson lint setup`.

## Daily operations
Start of work:

```bash
carson sync
carson lint setup --source /path/to/ai-policy-repo
carson audit
```

Before push or PR update:

```bash
carson audit
carson template check
```

If template drift is detected:

```bash
carson template apply
```

Before merge recommendation:

```bash
gh pr list --state open --limit 50
carson review gate
```

Scheduled late-review monitoring:

```bash
carson review sweep
```

Local branch clean-up:

```bash
carson prune
```

## Exit contract
- `0`: success
- `1`: runtime or configuration error
- `2`: policy blocked (hard stop)

Treat exit `2` as a mandatory stop until the policy violation is resolved.

## Troubleshooting
`carson: command not found`
- Confirm Ruby and gem installation.
- Confirm `$(ruby -e 'print Gem.user_dir')/bin` is in `PATH`.

`review gate` fails on actionable comments
- Respond with a valid disposition comment using the required prefix.
- Re-run `carson review gate`.

Template drift blocks

```bash
carson template apply
carson template check
```

## Offboard from a repository
To retire Carson from a repository:

```bash
carson offboard /local/path/of/repo
```

This removes Carson-managed host artefacts and unsets `core.hooksPath` when it points to Carson-managed global hooks.

## Related documents
- Interface reference: `API.md`
- Release notes: `RELEASE.md`
