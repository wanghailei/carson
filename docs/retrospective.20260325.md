# Retrospective: The Local-Centred Pivot — Implementation Day

2026-03-25. The day Carson became what it was always meant to be.

---

## What happened

Yesterday's retrospective clarified the direction: local-centred as the default, remote-centred as optional. Today we built it.

The session started with a brainstorming conversation — one design question at a time. By the end of that conversation, the architecture was clear. Then implementation, testing, PIW, release, and a long first-principles analysis that simplified the design further than anyone expected.

## The design conversation

Nine design questions, each one sharpening the story:

1. **Who merges?** → New local mode object. But then...
2. **What's the story name?** → Foreman? Settler? But then...
3. **What does the Foreman inspect?** → Tests are done by agents before packing. No Foreman needed.
4. **Who tracks vault acceptance?** → Git itself. Merge commit is the receipt. No Ledger.
5. **Merge strategy?** → Rebase + fast-forward. Linear history, agent corrects first.
6. **Still need a Settler?** → The Warehouse has robotic arms. It does the physical work. No Settler.
7. **Why not reuse Courier?** → One Courier, one verb: `deliver`. Different gestures per configuration.
8. **Courier asks Warehouse to merge?** → Wrong. The Courier waits at the gate. Knows nothing about inside work.
9. **Warehouse.deliver!?** → Wrong. Warehouses don't deliver. The CLI orchestrates: prepare → accept → courier.deliver.

Each question dissolved a complexity. We started with three new objects (Foreman, Settler, Vault) and ended with one (Vault) plus simplifications to existing objects.

## The first-principles cascade

After implementation and release, we applied first principles to the entire Carson surface. Each question removed something:

- **Sweep absorbs prune** — a workbench is worktree + branch + stash. One sweep, nothing left behind.
- **Checkin absorbs checkout** — the next checkin sweeps the delivered workbench. No explicit checkout.
- **Onboard absorbs setup** — auto-detect, default, edit config. No ceremony.
- **Deliver absorbs sync** — the agent never types `carson sync`. Carson syncs internally.
- **Global hook replaces per-repo hook** — the TAI pre-commit hook already guards main. Carson doesn't need per-repo hooks in local mode.
- **No templates in local mode** — agents handle linting. No `.github/linters/` to sync.
- **No compliance in local mode** — agents lint and test before delivering.

24 commands → 6: `checkin`, `deliver`, `onboard`, `offboard`, `list`, `version`.

## The key insight: remote is not a mode

The deepest evolution came at the end. We started the day thinking "local-centred" and "remote-centred" were two workstyles. By evening, we realised they're not two things at all.

Local delivery is always the foundation: prepare → accept into vault → sync to remote. Remote-centred doesn't replace this — it enhances it: after the sync, also file a PR and wait for Bureau checks.

The config changed from `workstyle: local/remote` to `bureau: true/false`. One toggle. The base is always local. The Bureau is optional.

This meant:
- No workstyle branching in the Courier — default is local, `bureau: true` adds the Bureau trip
- No workstyle detection in the pre-push hook — pushes to main are always legitimate
- No "two delivery paths" — one path, optional Bureau layer

72 insertions, 166 deletions. Simpler code from a deeper understanding.

## What was built

| Artefact | What it does |
|---|---|
| `Warehouse::Vault` concern | `accept!( parcel )` — merge branch into main via ff-only |
| `warehouse.prepare!( parcel, message: )` | Prep phase: pack, fetch, standard check, auto-rebase |
| Courier default gesture | Push main to remote (sync). Bureau gesture when `bureau: true` |
| CLI `dispatch_deliver_locally` | Orchestrates prepare → accept → courier.deliver |
| Config `bureau` toggle | `false` (default) or `true` (Bureau enhancement) |
| Pre-push hook | Simplified to no-op — pushes always allowed |
| `--help` | Leads with agent workflow, Carson's mission statement |
| Spec update | Local-centred pivot, vault, naming principles, workstyle → bureau |

## Scars

### Pre-push hook blocked Carson's own delivery (2026-03-25)

The Courier's local gesture (`git push main`) was blocked by the pre-push hook that enforced "all pushes go through PRs." The hook was designed for remote-centred mode and didn't know about local delivery. Fixed by making the hook workstyle-aware, then simplified to a no-op when we realised local is always the base.

**Lesson:** When you change the delivery model, audit every guard in the pipeline. Guards designed for the old model become blockers in the new one.

### GitHub branch protection blocked backup push (2026-03-25)

After vault acceptance succeeded, the Courier couldn't push to remote — GitHub's "require PR" branch protection rule rejected the direct push. The infrastructure hadn't caught up with the code.

**Lesson:** Code changes and infrastructure changes are one delivery. Don't claim done until both are verified.

### Warehouse path vs worktree path (2026-03-25)

`dispatch_deliver_locally` built the Warehouse at `main_worktree_root` (where main is checked out). But `current_label` and `current_head` need to resolve from the agent's worktree. Result: "main merged into main" instead of "feature merged into main."

**Lesson:** The Warehouse path determines what `current_label` returns. If you're asking about the agent's work, the Warehouse must be at the agent's worktree, not the main tree.

## Actions

1. ~~Local-centred delivery implemented and released as 4.3.0~~ (done)
2. ~~Bureau toggle replaces workstyle config~~ (done)
3. ~~Pre-push hook simplified~~ (done)
4. ~~Parcel-on-main guard added to local deliver~~ (done)
5. #520 tracks remaining LC cleanup: remove RC-only commands from CLI surface, sweep completeness (stash), Runtime dissolution
6. Spec update to reflect bureau toggle model (this commit)
