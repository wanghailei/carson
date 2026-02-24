# Carson Developer Guide (Internal)

## Audience

This guide is for internal Carson developers and internal testers only.

It is not an end-user installation guide.

## Purpose and scope

This document covers:

- private/pre-public installation for local development and dogfooding
- local source installation via `install.sh`
- authenticated script fetch for private repositories when needed

This document does not cover:

- public RubyGems onboarding for end users
- Carson runtime internals

## Internal Configuration (`~/.carson/config.json`)

Carson remains outsider-only. Runtime configuration belongs in user space, never in host repositories.

Canonical path:

- `~/.carson/config.json`

Override path:

- `CARSON_CONFIG_FILE=/absolute/path/to/config.json`

Config precedence (as implemented in `lib/carson/config.rb`):

1. built-in defaults
2. global user config file
3. environment overrides

Host-repository Carson config files are intentionally not loaded.

Compact example:

```json
{
	"_comment": "Scope groups are path-based; branch naming is not enforced.",
	"scope": {
		"path_groups": {
			"domain": [ "app/**", "db/**", "config/**" ]
		}
	},
	"review": {
		"required_disposition_prefix": "Disposition:"
	},
	"style": {
		"ruby_indentation": "tabs"
	}
}
```

JSON rationale (internal):

- runtime already uses the Ruby stdlib parser (`require "json"`)
- no additional dependency surface for config parsing
- avoids YAML indentation constraints

JSON comment guidance:

- use `_comment` keys for inline hints inside `config.json`
- or keep explanatory notes in a sidecar file such as `~/.carson/config.notes.md`

Key environment overrides supported by the loader:

- `CARSON_CONFIG_FILE`
- `CARSON_HOOKS_BASE_PATH`
- `CARSON_REVIEW_WAIT_SECONDS`
- `CARSON_REVIEW_POLL_SECONDS`
- `CARSON_REVIEW_MAX_POLLS`
- `CARSON_REVIEW_DISPOSITION_PREFIX`
- `CARSON_REVIEW_SWEEP_WINDOW_DAYS`
- `CARSON_REVIEW_SWEEP_STATES`
- `CARSON_RUBY_INDENTATION`

## Internal install from a local Carson checkout

Use this path when you already have Carson source locally:

```bash
cd /local/path/of/carson
./install.sh
```

Verify:

```bash
carson version
```

If `carson` is not found in your shell, add `~/.local/bin` to `PATH`.

## Authenticated install script fetch (private repo only)

Use this only when direct raw GitHub URLs are not accessible for a private repository.

Security note:

- use trusted `<owner>/<repo>` and a trusted ref (tag or commit SHA preferred over `main`)
- download first, review content, then execute
- use `/tmp` for temporary installer files

With GitHub CLI:

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/<owner>/<repo>/contents/install.sh?ref=<trusted_ref>" > /tmp/carson-install.sh
sed -n '1,120p' /tmp/carson-install.sh
bash /tmp/carson-install.sh
rm -f /tmp/carson-install.sh
```

With `curl` and token:

```bash
curl -fsSL \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/<owner>/<repo>/contents/install.sh?ref=<trusted_ref>" > /tmp/carson-install.sh
sed -n '1,120p' /tmp/carson-install.sh
bash /tmp/carson-install.sh
rm -f /tmp/carson-install.sh
```

## Basic smoke verification for a client repository

After installation:

```bash
carson version
carson init /local/path/of/repo
```

Expected result:

- Carson version prints successfully
- `init` completes baseline setup or returns actionable policy output

## Privacy conventions for docs and examples

Always use generic paths and placeholders:

- `~` or `$HOME` (never machine-specific absolute home paths)
- `/local/path/of/carson`
- `/local/path/of/repo`
- `<owner>/<repo>`

Never include machine-local identifiers or personal workspace names.
