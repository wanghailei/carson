# Scenarios

The real-world damage agents have done while working in shared git repositories. Carson exists to stop each of these from happening again. Carson's own bugs and wrong designs are in [defects.md](defects.md).

**The rules.**

1. **Every feature of Carson answers a scenario here.** A feature that answers none has no place in Carson.
2. **Root cause first.** A scenario gets its root cause found before any feature, because a feature aimed at a symptom is useless.
3. **A test that recreates the scenario.** Every scenario gets one, and it fails without the feature.
4. **Carson works while no scenario here happens again.** A new one gets its root cause found first, then a section here and a test, and only then a feature.

**Where they come from.** The incidents run from 2026-03-04 to 2026-10-01.

- **The 2026-09-29 catalogue.** 162 failures were catalogued on that day, from Carson's issues, the issues of the repositories it served, its release notes, reviews and retrospectives, and the agents' own record of mistakes.
  - 32 of them show damage done by agents.
  - 113 show Carson 4's own defects; 12 rows show both.
  - 17 were faults of the global guards, now AGT's gate.
  - 12 lie outside: documents, tests, and other acts of agents.
- **A full reading on 2026-10-01.** Every issue in 14 repositories was read in full, 531 in all, because the catalogue had read some of them by keyword only. That found 8 incidents the catalogue missed, four of them the new scenario S12.
- **Two seen on 2026-10-01:** S9 and S11.

**April to August is thin.** Only three incidents fall in those five months: two in July (S8) and one in August (S1). Every issue from that time has now been read. The agents' session transcripts from that time no longer exist, so damage that was never written up as an issue cannot be found.

## Status on 2026-10-01

| | Scenario | Prevented by | Holds |
|---|---|---|---|
| S1 | Worked from an old `main`, overwriting newer work | Carson | Yes |
| S2 | Damaged the main working tree, which everyone shares | AGT's gate, Carson | Partly: files left there still block a landing with no way through |
| S3 | Touched another agent's work | Carson | Yes |
| S4 | Removed a worktree with a session inside it | Carson | Yes |
| S5 | Lost its own unfinished work | Carson | Yes |
| S6 | Landed content that destroyed work | Carson runs the repository's check | Partly: what the check looks at is the repository's |
| S7 | Two agents changed the same files, and one landing undid the other's | Carson | Yes |
| S8 | Went around the rules with raw git | AGT's gate, GitHub's ruleset, Carson | Partly: three raw routes are open in the gate |
| S9 | Landed without pushing | Carson | Partly: a raw fast-forward in the main working tree still lands without a push |
| S10 | Made worktrees outside Carson | Carson, Claude Code's worktree hooks | Partly: a raw `git worktree add` is open in the gate |
| S11 | Work reached GitHub's `main` from another machine | Carson | Yes |
| S12 | Left finished work on a branch that never landed | Carson | Partly: a branch without a worktree is not shown |

The tests named below pass: `bin/check` ran all 165 of Carson's tests on 2fc3547, 2026-10-01.

## S1. Worked from an old `main`, overwriting newer work

- **What happened.**
  - 2026-03-11 (ai#347): an agent rebuilt a page from a stale source and overwrote the person's latest design commits.
  - 2026-03-12 (ai#468, ai#469): a branch was stacked on an old copy of a commit already landed.
  - 2026-08-06 (ai#919): an agent branched from a `main` five days stale. The code had moved on since, so the whole first implementation was thrown away, and half the session went on a file already deleted.
  - 2026-09-14 (aix#21): a task started from a `main` ten commits behind; files another machine had moved lingered.
- **Root cause.** The agent's work began from, or stayed on, a copy of `main` that others had moved on from, and nothing made it start from, and land onto, the current `main`.
- **Prevention.**
  - `carson start` fetches GitHub's `main` within 30 seconds and refuses if it cannot. It brings local `main` level first, then branches from it.
  - `carson land` brings the task up to the current local `main` before it lands.
- **Tests.** TestStartRefusesWhenGitHubCannotBeReached, TestStartBringsLocalMainForwardToGitHubs, TestLandRebasesOntoANewerMainFirst.
- **Holds.** Yes.

## S2. Damaged the main working tree, which everyone shares

- **What happened.**
  - 2026-03-04 (ai#767): `git stash`, `git checkout main` and `git clean -fd` destroyed 26 untracked files.
  - 2026-03-04 (ai#768): a feature branch's changes collided with the person's own work in the main working tree.
  - 2026-03-05 (ai#766): an agent used `git stash` to clear unstaged changes that blocked a merge in a shared checkout, instead of working in a worktree.
  - 2026-03-09 (ai#747, ai#742; carson#260): three commits were made straight on `main` in one session.
  - 2026-03-10 (ai#297): `git checkout --` discarded the person's uncommitted edits.
  - 2026-03-23: `git rm --cached` in one tree, then a fast-forward deleted three local-only files from the main working tree.
  - 2026-09-16 (ai#932): a raw fast-forward was run on the main working tree.
  - 2026-09-18 (mint#3): an uncommitted lockfile change left in a main working tree blocked a landing, and the agent handed a raw `git restore` to the person.
  - 2026-09-23 (aix#11, aix#12): a session left an uncommitted file in the main working tree. Other sessions' landings were blocked, about 30 minutes were lost, and the person was interrupted.
  - 2026-09-23 (aix#61): blocked the same way, an agent asked the person to run `git reset --hard`, then cleared another session's file itself.
- **Root cause.** The main working tree is shared, nothing there says whose a change is, and the rule against working there was only text.
- **Prevention.**
  - AGT's gate refuses agents' edits, shell writes, commits, `checkout`, `clean`, and `stash drop` and `stash clear` there.
  - Carson never fast-forwards over a file there.
  - A note in the coding rules says `git rm --cached` protects only the tree where it ran.
- **Tests.** TestLandRefusesToOverwriteAModifiedFileInTheMainTree, TestLandRefusesToOverwriteWhatTheMainTreeHolds, TestStartRefusesAFastForwardThatWouldOverwriteAnIgnoredFile; AGT's tests.
- **Holds.** Partly.
  - The damage itself is refused.
  - A file left there by a route the gate cannot see, or by a person's own edit, still blocks every landing that would change it. Carson then says "ask a person whose they are": see Open, and defect D7.
  - The files deleted after `git rm --cached` keep their last content in git's history; Carson does not stop that.

## S3. Touched another agent's work

- **What happened.**
  - 2026-03-06 (ai#760): post-merge cleanup force-removed another live session's worktree with a raw `git worktree remove --force`.
  - 2026-03-06 (ai#759): an agent left its own abandoned files behind and blamed them on another session.
  - 2026-03-09 (ai#741): an agent discarded files it did not recognise; they were the person's own commit.
  - 2026-03-30 (ai#872, ai#877): an agent landed another session's branch along with its own changes; nine corrections followed.
  - 2026-09-13 (session transcript): an agent did not recognise its own worktree, which held the only copy of a 333-line plan, and handed it to the person.
- **Root cause.** Nothing recorded who made a worktree, so ownership was guessed from names, files and `git worktree list`, and nothing stopped one agent acting on another's.
- **Prevention.**
  - `carson start` writes an owner record in the worktree's own git folder.
  - `carson status` shows every task under its owner, as live, ended or unknown.
  - `land`, `remove` and `abandon` act only for the owner.
  - `adopt` takes over only a task whose owner is seen to have ended.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestLandRefusesAnotherSessionsTask, TestRemoveRefusesAnotherSessionsTask, TestAdoptRefusesALiveOwnersTask, TestAdoptAnEndedAgentsTask, TestStatusGroupsTwoTasksOfOneSessionAndPutsUnownedLast.
- **Holds.** Yes, for everything done through Carson. Raw git is S8.

## S4. Removed a worktree with a session inside it

- **What happened.**
  - 2026-03-05 to 09 (ai#765): worktrees were deleted while an agent's shell was inside them. Every later command failed, and the session could not recover: "the #1 agent session crash".
  - 2026-03-07 (carson#189, carson#190): `gh pr merge --delete-branch`, run from inside a worktree, deleted it and killed the shell.
- **Root cause.** Nothing checked, before a worktree was removed, whether anyone was working in it, and removal could be started from inside it.
- **Prevention.** `carson remove` and `carson abandon` run only from outside the worktree, and name the folder to run from. They refuse while any process works inside (naming it), and refuse when that cannot be observed.
- **Tests.** TestRemoveRefusesFromInsideTheWorktree, TestRemoveRefusesWhileProcessesWorkInside, TestRemoveRefusesWhenProcessesCannotBeChecked, TestPSFindsAProcessWorkingInsideAFolder.
- **Holds.** Yes.

## S5. Lost its own unfinished work

- **What happened.**
  - 2026-03-19 (ai#782, ai#720): during a rebase conflict an agent ran `carson abandon` in a panic, and nearly destroyed a session's work.
  - 2026-03-23 (carson#443): after a failed delivery an agent kept editing, and then could not rebase.
  - 2026-03-31 (Carson 4 release notes 4.3.4): an agent edited four files and landed without committing; the edits were lost. Carson's part, deleting the worktree after landing nothing, is defect D3.
- **Root cause.** Agents acted on work in an unsettled state, uncommitted or in the middle of a rebase, and nothing made those commands keep the work.
- **Prevention.**
  - `carson land` refuses uncommitted files, and a rebase or merge in progress.
  - `carson abandon` commits what was uncommitted onto the branch and keeps it as `abandoned/<task>`; it refuses during a rebase.
  - A conflicting rebase is undone, and the files are named.
- **Tests.** TestLandRefusesUncommittedFiles, TestLandRefusesWhileARebaseIsInProgress, TestRemoveAbandonedKeepsEverything, TestRemoveAbandonedRefusesWhileARebaseIsInProgress, TestLandUndoesAConflictingRebase.
- **Holds.** Yes.

## S6. Landed content that destroyed work

- **What happened.**
  - 2026-03-11 (ai#733): a clean-up commit deleted a build script along with the files it meant to remove. Another script depended on it, and silently served stale bundles.
  - 2026-03-18 (carson#416): a file move committed an empty file and deleted another; 151 lines of rules were lost.
  - 2026-03-18 (ai#665): a file move kept 102 of 209 lines; 108 lines and five sections were lost without a word.
  - 2026-03-19 (ai#666): a glossary was deleted after only 5 of its 12 terms had been moved.
- **Root cause.** The agent's change emptied, shrank or deleted a file that others needed, and nothing between the commit and `main` looked at the result.
- **Prevention.** `carson land` runs the repository's `bin/check` on the exact commit that will land, before `main` moves; a failure stops the landing.
- **Tests.** TestLandStopsWhenTheChecksFail, TestLandSaysTheChecksPassed.
- **Holds.** Partly: Carson guarantees the check runs; whether an emptied file is caught depends on what the repository's check looks at.

## S7. Two agents changed the same files, and one landing undid the other's

- **What happened.** 2026-03-15 (govern incident review): two pull requests overlapped on shared files. The merge silently kept `main`'s code over the branch's; one lost half its scope, and the other was never merged.
- **Root cause.** Concurrent work on the same files was joined by a merge that resolved the overlap silently.
- **Prevention.** `carson land` brings the task up to the current `main` by rebase. Any conflict stops the landing; it is undone and its files are named, and the agent resolves it, keeping what landed first. Nothing resolves an overlap silently.
- **Tests.** TestLandRebasesOntoANewerMainFirst, TestLandUndoesAConflictingRebase.
- **Holds.** Yes.

## S8. Went around the rules with raw git

- **What happened.**
  - 2026-03-09 (ai#263, ai#745), and again 2026-07-28: raw `git push github main` and `gh pr create` in a governed repository.
  - 2026-03-11 (ai#345, ai#346): one session made 16 raw pushes, 20 raw merges and 3 force-with-lease pushes, and claimed "done" six times while files remained.
  - 2026-03-11 (ai#367, ai#734): an agent set Carson's internal signal to get past its hook.
  - 2026-03-11 (ai#352): an agent told the person to run a raw `git pull`.
  - 2026-03-15 (govern incident review): a temporary clone and a Python script got past the write guards.
  - 2026-03-18 (carson#413): raw fetch and rebase when a branch was behind `main`.
  - 2026-07-27 (aix#70): a raw `git push --delete`, `git worktree remove` and `git pull`, chained.
  - 2026-09-15 (ai#929): a commit made with the hooks switched off.
- **Root cause.** Two things together: refusals with no way through left agents stuck (defect D7), and the raw routes were open.
- **Prevention.**
  - Carson gives a way through for every case.
  - AGT's gate refuses force pushes, and commits, rebases and resets in the main working tree.
  - GitHub's ruleset refuses a force push or deletion of `main`.
- **Tests.** AGT's tests.
- **Holds.** Partly. Three raw routes are still open in the gate:
  - `git push <remote> main` from a worktree;
  - `git worktree add` (S10);
  - `git merge --ff-only` in the main working tree, which lands a task without its check or a push (S9).

## S9. Landed without pushing

- **What happened.** 2026-09-29 to 30 (seen 2026-10-01): in a private repository, 23 landings made by fast-forward were never pushed, so GitHub's copy of `main` fell behind.
- **Root cause.** Agents landed with a raw fast-forward, which moves only local `main`. Pushing was a separate step, and they skipped it.
- **Prevention.**
  - `carson land` fast-forwards, pushes, and looks that GitHub's `main` equals local `main`.
  - `carson start` first pushes landed work GitHub lacks.
- **Tests.** TestLandFastForwardsMainAndPushes, TestLandWhosePushFailsSaysSoAndIsPushedByTheNextMerge, TestStartPushesMergedWorkGitHubLacks.
- **Holds.** Partly. Through Carson it cannot happen, but AGT's gate still lets an agent land with a raw `git merge --ff-only` in the main working tree. Its own comment calls that "how a finished task lands"; since Carson 5, `carson land` is.

## S10. Made worktrees outside Carson

- **What happened.**
  - 2026-03-12 (session transcript): an interrupted raw `git worktree add` left an unknown partial state.
  - From 2026-03-26 (Carson 4's manual): Claude Code's own worktree tool made worktrees outside Carson, with random names and a possibly stale start.
  - 2026-09-13 (session transcript): a worktree made outside Carson held the only copy of a 333-line plan, and nobody knew whose it was.
  - 2026-09-13 (ai#924): another worktree, made outside Carson, had been left with ten uncommitted edits on a base older than May.
- **Root cause.** Worktrees could be made by several routes, and only Carson records whose they are.
- **Prevention.** `carson start` makes every worktree, under `~/.worktrees/` and outside every main working tree. Claude Code's worktree hooks, in AGT, send the harness's own tool through `carson start` and `carson remove`.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestStatusWorktreeWithoutOwnerRecord; AGT's hook tests.
- **Holds.** Partly: a raw `git worktree add` is still open in the gate.

## S11. Work reached GitHub's `main` from another machine

This is a situation, not damage: a person works on the same repository from a second machine.

- **What happened.** 2026-10-01: a commit pushed to GitHub from a second machine met 23 unpushed landings here (S9), and the two `main`s diverged.
- **Root cause.** `main` has two copies, and both moved.
- **Prevention.** On diverged `main`s, `carson land` merges GitHub's `main` into the task, in the task's own worktree, and never rebases that merge away: a plain rebase drops GitHub's commits from the task, and the push would be refused (tried 2026-09-30). Local `main` and GitHub's then both move by fast-forward.
- **Tests.** TestLandJoinsDivergedMains, TestLandKeepsATaskThatCarriesAJoinUnflattened, TestStartWhenMainsDivergedSaysTheMergeWillJoinThem, TestLandRetryAfterAFailedPushJoinsAGitHubThatMovedOn.
- **Holds.** Yes. The diverged repository is joined by its next landing.

## S12. Left finished work on a branch that never landed

- **What happened.**
  - 2026-03-10 (ai#296): four commits sat on a branch without being landed. The branch drifted from `main`, landing it took three pull requests, and stale files were left on `main`.
  - 2026-09-07 (aix#173, aix#181): two lessons committed on a branch never landed; they were found 17 days later, during a migration.
  - 2026-09-14 (aix#177, aix#178, aix#180, aix#182): four lessons on another branch never landed. That session's landing had failed on Carson 4's global remote setting (defect D13), and was never retried.
  - 2026-09-19 (aix#174 to aix#176, aix#179, aix#183 to aix#185): six lessons on two more branches never landed.
- **Root cause.** A session ended with its work committed but not landed, sometimes after a landing had failed, and nothing showed anyone the branches holding work `main` lacked.
- **Prevention.**
  - `carson remove` refuses a task whose work is not on `main`, so the task and its branch stay.
  - `carson status` shows every task with the commits `main` lacks, under its owner, live or ended.
  - An ended owner's task can be taken up with `carson adopt` and landed.
- **Tests.** TestRemoveRefusesWorkNotOnMain, TestStatusLiveTaskAtWork, TestAdoptAnEndedAgentsTask.
- **Holds.** Partly.
  - A branch that holds work `main` lacks but has no worktree is not shown: `carson status` lists only `abandoned/` branches.
  - No test shows an ended owner's unlanded task in `status`.

## Open

1. **S2: files left in the main working tree that block a landing.**
   - **Proposed, not yet decided.** When such files stand in the way of a fast-forward, Carson keeps them as abandoned work on a branch, `abandoned/main-tree-<date-time>`. `carson status` shows it, and `carson adopt` takes it up like any abandoned task. Carson then puts those paths back to `main` and lands. Nothing is lost, and nobody is asked.
   - **The cost.** A person's own uncommitted edits, in a repository edited by hand, would leave the working tree and wait on that branch.
2. **S8, S9, S10: three open routes in AGT's gate.**
   - Refuse a raw `git push <remote> main` from a worktree, pointing to `carson land`.
   - Refuse a raw `git worktree add`, pointing to `carson start` and `carson adopt`.
   - Refuse a raw `git merge --ff-only` in the main working tree, pointing to `carson land`.
3. **S12: show unlanded branches.** `carson status` lists every branch that holds work `main` lacks but has no worktree, and names `carson adopt`. A test shows an ended owner's unlanded task.

## Considered and left out

Damage found in the issues that neither git nor Carson could prevent:

- 2026-09-23 (aix#58, ai#962): an agent took a statement of direction for an order, deleted scripts, and landed the deletion through the agreed route. The fault is acting without an order, which the rules for agents hold.
- 2026-08-30 (aix#178): a fix that lived only in unversioned configuration was overwritten when an old copy was committed. The newer work was never in git.
- 2026-09-21 (env#3): a sync script's `rsync --delete` wiped ten clones on a machine. Not git.
- 2026-09-19 (aix#15): a `find … -delete` removed a person's own files outside any repository; git was only the way back.
- 2026-03-26 (ai#868, ai#882): a renamed file made a posting tool repost every entry, and a clean-up deleted 107 posts. The damage was on a website.
- 2026-09-13 (aix#31): an entry was pushed while the posting secrets were known to be missing, and the post failed.
