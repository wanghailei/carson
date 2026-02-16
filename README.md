# Butler

Butler is a shared local governance tool for repository hygiene and merge readiness support.

## Runtime

- Ruby managed by `rbenv`
- Supported Ruby versions: `>= 4.0`

## Commands

- `bin/butler audit`
- `bin/butler sync`
- `bin/butler prune`
- `bin/butler hook`
- `bin/butler check`
- `bin/butler common check`
- `bin/butler common apply`

## Exit Statuses

- `0 - OK`
- `1 - runtime/configuration error`
- `2 - policy blocked (hard stop)`

## Configuration

`/.butler.yml` is optional.

- If absent, Butler uses shared built-in defaults.
- If present, Butler deep-merges your overrides onto those defaults.

## Common Templates

Butler can manage shared `.github` sections with explicit markers:

```md
<!-- butler:common:start <section-id> -->
...common managed content...
<!-- butler:common:end <section-id> -->
```
