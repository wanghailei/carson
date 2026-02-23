# Butler Developer Guide (Internal)

## Audience

This guide is for internal Butler developers and internal testers only.

It is not an end-user installation guide.

## Purpose and scope

This document covers:

- private/pre-public installation for local development and dogfooding
- local source installation via `install.sh`
- authenticated script fetch for private repositories when needed

This document does not cover:

- public RubyGems onboarding for end users
- Butler runtime internals

## Internal Configuration (`~/.butler/config.json`)

Butler remains outsider-only. Runtime configuration belongs in user space, never in host repositories.

Canonical path:

- `~/.butler/config.json`

Override path:

- `BUTLER_CONFIG_FILE=/absolute/path/to/config.json`

Config precedence (as implemented in `lib/butler/config.rb`):

1. built-in defaults
2. global user config file
3. environment overrides

Host-repository Butler config files are intentionally not loaded.

Compact example:

```json
{
	"_comment": "Lane-first branch naming and disposition defaults.",
	"scope": {
		"branch_pattern": "^(?<lane>tool|ui|module|feature|fix|test)/(?<slug>.+)$"
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
- or keep explanatory notes in a sidecar file such as `~/.butler/config.notes.md`

Key environment overrides supported by the loader:

- `BUTLER_CONFIG_FILE`
- `BUTLER_HOOKS_BASE_PATH`
- `BUTLER_SCOPE_BRANCH_PATTERN`
- `BUTLER_REVIEW_WAIT_SECONDS`
- `BUTLER_REVIEW_POLL_SECONDS`
- `BUTLER_REVIEW_MAX_POLLS`
- `BUTLER_REVIEW_DISPOSITION_PREFIX`
- `BUTLER_REVIEW_SWEEP_WINDOW_DAYS`
- `BUTLER_REVIEW_SWEEP_STATES`
- `BUTLER_RUBY_INDENTATION`

## Internal install from a local Butler checkout

Use this path when you already have Butler source locally:

```bash
cd /local/path/of/butler
./install.sh
```

Verify:

```bash
butler version
```

If `butler` is not found in your shell, add `~/.local/bin` to `PATH`.

## Authenticated install script fetch (private repo only)

Use this only when direct raw GitHub URLs are not accessible for a private repository.

Security note:

- use trusted `<owner>/<repo>` and a trusted ref (tag or commit SHA preferred over `main`)
- download first, review content, then execute
- use `/tmp` for temporary installer files

With GitHub CLI:

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/<owner>/<repo>/contents/install.sh?ref=<trusted_ref>" > /tmp/butler-install.sh
sed -n '1,120p' /tmp/butler-install.sh
bash /tmp/butler-install.sh
rm -f /tmp/butler-install.sh
```

With `curl` and token:

```bash
curl -fsSL \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/<owner>/<repo>/contents/install.sh?ref=<trusted_ref>" > /tmp/butler-install.sh
sed -n '1,120p' /tmp/butler-install.sh
bash /tmp/butler-install.sh
rm -f /tmp/butler-install.sh
```

## Basic smoke verification for a client repository

After installation:

```bash
butler version
butler init /local/path/of/repo
```

Expected result:

- Butler version prints successfully
- `init` completes baseline setup or returns actionable policy output

## Privacy conventions for docs and examples

Always use generic paths and placeholders:

- `~` or `$HOME` (never machine-specific absolute home paths)
- `/local/path/of/butler`
- `/local/path/of/repo`
- `<owner>/<repo>`

Never include machine-local identifiers or personal workspace names.
