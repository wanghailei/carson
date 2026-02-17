# GitHub Templates

Butler manages selected GitHub-native files through full-file synchronisation.

## Managed Files

- `.github/copilot-instructions.md`
- `.github/pull_request_template.md`

Each managed file is sourced from `templates/.github/<basename>`.

## Workflow

1. Run `butler template check` to detect drift.
2. Run `butler template apply` to write canonical content.

## Drift Reasons

- `missing_file`: target file does not exist.
- `content_mismatch`: target file content differs from canonical content.

## Boundary

- Butler-specific marker syntax is not used.
- Host repositories keep only GitHub-native managed files.
