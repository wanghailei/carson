# OO Carson — Functional Comparison and TODO

Date: 2026-03-23

## Delivery Flow (Courier + Warehouse + Waybill)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `deliver!` → push branch | Warehouse | `ship( parcel )` | Done |
| `deliver!` → create/find PR | Waybill | `file!( title:, body_file: )` | Done |
| `deliver!` → check CI/review/merge state | Waybill | `refresh!`, `cleared?`, `held?` | Done |
| `deliver!` → merge PR | Waybill | `accept!( method: )` | Done |
| `deliver!` → settle polling loop | Courier | `settle( waybill, result )` | Done |
| `deliver!` → full orchestration | Courier | `deliver( parcel )` | Done |
| `deliver!` → check branch freshness | Warehouse | `based_on_latest_standard?( parcel )` | Done |
| `deliver!` → rebase onto main | Warehouse | `rebase_on_latest_standard!` | Done |
| `deliver!` → template sync before push | Warehouse | `submit_compliance!` | Done |
| `deliver!` → stage + commit | Warehouse | `pack!( message: )` | Done |
| `deliver!` → `--commit` flag (dirty delivery) | Courier | `deliver( parcel, commit_message: )` | Done |
| `deliver!` → sync local main after merge | Warehouse | `sync!` | Done |
| `deliver!` → ledger update | Courier | `record( parcel, status:, summary: )` via injected ledger | Done |
| `deliver!` → output rendering | Carson Co. | `Carson.report( result, format: )` | Done |

## Cleanup (Warehouse)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `housekeep!` → reap dead worktrees | Warehouse | `sweep!` | TODO |
| `housekeep!` → sync + prune | Warehouse | `sweep!` (orchestrates sync + prune) | TODO |
| `prune!` → remove stale branches | Warehouse | part of `sweep!` or standalone | TODO |
| `sync!` → fetch + fast-forward main | Warehouse | `fetch_latest` exists; local ff needs work | Partial |

## Worktree Management (Warehouse → Shelf)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `worktree_create!` | Warehouse / Shelf | shelf creation | TODO |
| `worktree_remove!` | Warehouse / Shelf | shelf removal | TODO |
| `worktree_list!` | Warehouse | `shelves` (basic list exists) | Partial |

## Inventory and Query (Warehouse)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `status!` → repo state | Carson Co. | `track` | TODO |
| `audit!` → health checks | Carson Co. / Warehouse | governance audit | TODO |
| branch list | Warehouse | `labels` | Done |
| worktree list | Warehouse | `shelves` | Done |
| branch merged check | Warehouse | `label_absorbed?( name )` | Done |

## Template and Compliance (Warehouse)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `template_check!` | Warehouse | part of `submit_compliance!` | TODO |
| `template_apply!` | Warehouse | `submit_compliance!` | TODO |

## Review (Waybill + external)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `review_gate!` | Waybill | review gate injection | TODO |
| `review_sweep!` | Waybill | review sweep | TODO |

## Portfolio (Carson Co.)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `list!` | Carson Co. | portfolio management | TODO |
| `onboard!` | Carson Co. | warehouse onboarding | TODO |
| `offboard!` | Carson Co. | warehouse offboarding | TODO |
| `refresh!` | Carson Co. | refresh all warehouses | TODO |
| `receive!` | Carson Co. | triage deliveries | TODO |

## Recovery and Abandonment (Courier)

| Current Runtime | OO Owner | OO Method | Status |
|---|---|---|---|
| `abandon!` | Courier | `return( parcel )` | TODO |
| `recover!` | Courier | `salvage( parcel )` | TODO |

## Domain Objects

| Object | Spec | Status |
|---|---|---|
| Parcel | label, head, shelf, `on_main?` | Done |
| Warehouse | path, config, git gateway | Partial — core done, compliance/sweep/shelf missing |
| Waybill | PR lifecycle, bureau response | Done |
| Courier | delivery orchestration | Partial — deliver done, return/salvage missing |
| Delivery | tracking record | Exists (old `delivery.rb`), needs OO integration |
| Shelf | worktree object | TODO |
| Label | branch object | TODO |
| Carson Co. | dispatch, portfolio, rendering | TODO |

## Command Rename Map

| Current | OO Name | Status |
|---|---|---|
| `deliver` | `deliver` | Same |
| `abandon` | `return` | TODO |
| `recover` | `salvage` | TODO |
| `housekeep` | `sweep` | TODO |
| `status` | `track` | TODO |
| `govern` (old) | `monitor` | TODO |
