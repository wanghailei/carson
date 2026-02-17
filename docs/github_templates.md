# GitHub Templates

Butler manages cross-project `.github` template content through marker blocks.

## Managed Files

- `.github/copilot-instructions.md`
- `.github/pull_request_template.md`

Each file is matched by basename to `templates/github/<basename>`.
Marker ids are derived from the managed filename, for example:

- `.github/copilot-instructions.md` -> `copilot-instructions`
- `.github/pull_request_template.md` -> `pull-request-template`

## Workflow

1. Run `bin/butler template check` to detect drift.
2. Run `bin/butler template apply` to apply canonical GitHub template blocks.

Compatibility aliases:

- `bin/butler common check`
- `bin/butler common apply`

Repo-specific addendum content outside marker blocks is preserved.

## Drift Reasons

- `missing_file`: target file does not exist yet.
- `missing_markers`: target file exists but has no managed markers.
- `content_mismatch`: markers exist but managed block content differs from template.
