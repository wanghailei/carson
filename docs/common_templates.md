# Common Templates

Butler manages cross-project `.github` common content through marker blocks.

## Managed Files

- `.github/copilot-instructions.md`
- `.github/pull_request_template.md`

## Workflow

1. Run `bin/butler template check` to detect drift.
2. Run `bin/butler template apply` to apply canonical template blocks.

Compatibility aliases:

- `bin/butler common check`
- `bin/butler common apply`

Repo-specific addendum content outside marker blocks is preserved.
