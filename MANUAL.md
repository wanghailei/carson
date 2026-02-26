# Carson Manual

This manual covers installation, first-time setup, CI configuration, and daily operations.
For the mental model and command overview, see `README.md`. For formal interface definitions, see `API.md`.

## Install Carson

Prerequisites: Ruby `>= 4.0`, `gem` and `git` in `PATH`. `gh` (GitHub CLI) recommended for full review governance.

```bash
gem install --user-install carson
```

If `carson` is not found after installation:

```bash
export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH"
```

Verify:

```bash
carson version
```

## First-Time Setup

### Step 1: Prepare your lint policy

Carson enforces lint rules from a central policy source — a directory or git repository you control that contains a `CODING/` folder. For Ruby governance, the required file is `CODING/rubocop.yml`.

Run `lint setup` to copy policy files into `~/AI/CODING/`:

```bash
carson lint setup --source /path/to/your-policy-repo
```

After this command, `~/AI/CODING/rubocop.yml` exists and is ready for Carson to use. Every governed repository will reference these same policy files — this is how Carson keeps lint consistent.

Options:
- `--source <path-or-git-url>` — where to read policy files from (required).
- `--ref <git-ref>` — branch or tag when `--source` is a git URL.
- `--force` — overwrite existing `~/AI/CODING` files.

Policy layout: language config files sit directly under `CODING/` (flat layout, no language subfolders). Non-Ruby entries are present but disabled by default.

### Step 2: Onboard a repository

```bash
carson init /path/to/your-repo
```

`init` performs:
- Remote alignment using configured `git.remote` (default `github`).
- Hook installation under `~/.carson/hooks/<version>/`.
- Repository `core.hooksPath` alignment to Carson global hooks.
- Commit-time governance gate via managed `pre-commit` hook.
- Managed `.github/*` template synchronisation.
- Initial governance audit.

### Step 3: Commit generated files

After `init`, commit the generated `.github/*` changes in your repository. From this point the repository is governed.

## CI Setup

Use the reusable workflow with explicit release pins:

```yaml
name: Carson policy

on:
  pull_request:

jobs:
  governance:
    uses: wanghailei/carson/.github/workflows/carson_policy.yml@v1.0.0
    secrets:
      CARSON_READ_TOKEN: ${{ secrets.CARSON_READ_TOKEN }}
    with:
      carson_ref: "v1.0.0"
      carson_version: "1.0.0"
      rubocop_version: "1.81.0"
```

Notes:
- When upgrading Carson, update both `carson_ref` and `carson_version` together.
- `CARSON_READ_TOKEN` must have read access to your policy source repository so CI can run `carson lint setup`.
- The reusable workflow installs a pinned RuboCop gem before `carson audit`; mirror the same pin in host governance workflows for deterministic checks.

## Daily Operations

**Start of work:**

```bash
carson sync                                          # fast-forward local main
carson lint setup --source /path/to/your-policy-repo # refresh policy if needed
carson audit                                         # full governance check
```

**Before push or PR update:**

```bash
carson audit
carson template check
```

If template drift is detected:

```bash
carson template apply
```

**Before merge:**

```bash
carson review gate
```

**Periodic maintenance:**

```bash
carson review sweep    # update tracking issue for late review feedback
carson prune           # remove stale local branches
```

## Configuration

Default global config path: `~/.carson/config.json`.

Precedence (highest wins): environment variables > config file > built-in defaults.

Override the config file path with `CARSON_CONFIG_FILE=/absolute/path/to/config.json`.

Common environment overrides:

| Variable | Purpose |
|---|---|
| `CARSON_HOOKS_BASE_PATH` | Custom hooks installation directory. |
| `CARSON_REVIEW_WAIT_SECONDS` | Initial wait before first review poll. |
| `CARSON_REVIEW_POLL_SECONDS` | Interval between review polls. |
| `CARSON_REVIEW_MAX_POLLS` | Maximum review poll attempts. |
| `CARSON_REVIEW_DISPOSITION_PREFIX` | Required prefix for disposition comments. |
| `CARSON_REVIEW_SWEEP_WINDOW_DAYS` | Lookback window for review sweep. |
| `CARSON_REVIEW_SWEEP_STATES` | PR states to include in sweep. |
| `CARSON_RUBY_INDENTATION` | Ruby indentation policy (`tabs`, `spaces`, or `either`). |

For the full configuration schema and `lint.languages` definition, see `API.md`.

## Troubleshooting

**`carson: command not found`**
- Confirm Ruby and gem installation.
- Confirm `$(ruby -e 'print Gem.user_dir')/bin` is in `PATH`.

**`review gate` fails on actionable comments**
- Respond with a valid disposition comment using the required prefix.
- Re-run `carson review gate`.

**Template drift blocks**

```bash
carson template apply
carson template check
```

**Audit blocks on repo-local `.rubocop.yml`**
- Carson hard-blocks governed repositories that contain their own `.rubocop.yml`. Remove the repo-local file and rely on the central policy in `~/AI/CODING/rubocop.yml`.

**Hook version mismatch after upgrade**
- Run `carson refresh` to re-apply hooks and templates for the new Carson version.

## Offboard a Repository

To retire Carson from a repository:

```bash
carson offboard /path/to/your-repo
```

This removes Carson-managed host artefacts and unsets `core.hooksPath` when it points to Carson-managed global hooks.

## Related Documents

- Mental model and command overview: `README.md`
- Formal interface contract: `API.md`
- Release notes: `RELEASE.md`
