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
