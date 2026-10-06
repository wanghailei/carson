# Defects

Bugs and wrong designs in Carson itself: what Carson 4 did wrong, and what Carson 5 has done wrong so far. The damage agents do, which Carson exists to prevent, is in [scenarios.md](scenarios.md).

**The rules.**

1. **Root cause first.** A defect gets its root cause found before any fix.
2. **A test that recreates the defect.** Every defect gets one, and it fails on the Carson that had the defect.
3. **No case left for a person.** Carson serves agents: no outcome may end with a person having to settle it.

**Where they come from.**

- 113 of the 162 failures catalogued on 2026-09-29 were Carson 4's own defects; 12 of those rows also show an agent's damage (see scenarios.md).
- Carson 5's defects come from agents of three model families using it in sandboxes on 2026-09-30, and from what was seen on 2026-10-01.
- On 2026-10-01 every issue in 14 repositories was read in full. That added four sources to defects already listed (ai#343, ai#457, ai#878, pi#1), and found no new defect.

## Status on 2026-10-06

| | Defect | Holds in Carson 5 |
|---|---|---|
| D1 | Removed work on its own judgement | Partly: one removal path has no owner |
| D2 | Removed a worktree from inside it, or gave its owner no way to release it | Yes |
| D3 | Destroyed the worktree after landing nothing | Yes |
| D4 | Reported what it tried, not what happened | Yes |
| D5 | Read "cannot tell" as "no" | Yes |
| D6 | One message for many causes, and advice that did not work | Yes |
| D7 | Refused with no way through | Partly: one dead end, and 14 places that hand a case to a person |
| D8 | Started from a stale `main` without a word, or left local `main` behind | Yes |
| D9 | Showed no ownership, or misjudged it | Partly: a continued conversation could not land its own task |
| D10 | Confused names that git or the disk could not tell apart | Yes |
| D11 | Switched off other checks with its own hooks | Yes, by installing none |
| D12 | Left its own guard open | Yes, by having no hooks; the routes are now AGT's gate's |
| D13 | Kept per-repository facts in one global setting | Yes, by having no settings |
| D14 | Put worktrees inside the main working tree | Yes |
| D15 | Let a network call hang | Yes |
| D16 | Built machinery for a team that does not exist | Yes, by having none of it |
| D17 | Built for cases that never happened | No: about 290 lines, harmless |

The tests named below pass: `bin/check` ran all 181 of Carson's tests on 31c08f9, 2026-10-06.

## D1. Removed work on its own judgement

- **What happened.**
  - Carson 4, 2026-03-06 (release notes 2.33.0): removal used force by default, "silently destroying uncommitted work".
  - Carson 4, 2026-03-06 (release notes 2.32.0): `prune` removed any worktree that stood in the way of deleting a branch.
  - Carson 4, 2026-03-05 to 07 (release notes 2.27.0, 3.15.1, 3.16.0): branches were deleted because their files matched `main`.
  - Carson 4, 2026-03-16 (carson#350), and again 2026-09-23 (aix#57): a worktree made minutes earlier was swept away as "absorbed into main".
  - Carson 4, 2026-03-16 (current-state audit): once a worktree's folder had vanished, cleanup could delete its branch even when that branch was the last copy of the work.
  - Carson 4, 2026-03-19 (ai#782, ai#720): `carson abandon` closed a pull request and deleted a worktree in the middle of a rebase conflict.
  - Carson 4, 2026-03-23 (carson#457): one call removed every worktree it judged dead.
  - Carson 4, 2026-07-29 (aix#75): a release left the branch behind, and its name stayed taken.
  - Carson 4, also: carson#484, #513, #524; aix#102; 21 worktrees lingering across 7 repositories (2026-09-13).
  - **Carson 5, 2026-09-30 (trial): `carson remove MAIN` deleted `main`.**
- **Root cause.**
  - Removal acted on Carson's own judgement, such as "its content is on main", "absorbed" or "dead", instead of the owner's declaration. It also used force, removed in batches, or left the branch behind.
  - In Carson 5, a path for "leftover branches" still deleted a branch that had no owner, judging only that "its work is on main", which `main` itself always is. Its name checks also compared letters exactly (D10).
- **Fix.** Nothing is removed unless the task's owner names it:
  - `carson remove <task>`, for landed work, removes worktree and branch together, from outside, by git's safe delete, never by force, one task per call.
  - `carson abandon <task>`, for unfinished work, commits what was uncommitted onto the branch and keeps it as `abandoned/<task>`.
  - There is no sweep.
- **Tests.** TestRemoveRemovesAMergedTask, TestRemoveRefusesUncommittedFiles, TestRemoveRefusesWorkNotOnMain, TestRemoveRefusesAnotherSessionsTask, TestRemoveATaskWhoseFolderIsGoneWithWorkNotOnMain, TestRemoveAbandonedKeepsEverything, TestRemoveAbandonedRefusesWhileARebaseIsInProgress, TestRemoveNeverTakesAnotherCaseForABranch.
- **Holds.** Partly.
  - The leftover-branch path is still there (`removeLeftoverBranch` in `remove.go`), and deletes a branch no owner declared. `MAIN` went through it.
  - No test yet shows that another session's fresh worktree survives every command.
  - See Open.

## D2. Removed a worktree from inside it, or gave its owner no way to release it

- **What happened.**
  - Carson 4, 2026-03-05 to 09 (ai#765; release notes 3.10.0): there was no guard at first against removing a worktree with a shell inside, and the first guard resolved the wrong path when given a bare name.
  - Carson 4, 2026-03-07 (carson#189, carson#190): Carson itself passed `--delete-branch`, which destroyed the worktree it ran from.
  - Carson 4, 2026-03-14 and 15 (carson#277, carson#304): cleanup ran `git switch main` inside a worktree.
  - Carson 4, 2026-03-19 (carson#417): from inside its own worktree, an owner could not release it, and `prune` silently did nothing.
- **Root cause.** Carson assumed one working tree, and never looked at who worked inside a worktree before removing it.
- **Fix.** `carson remove` and `carson abandon` run only from outside the worktree, and name the folder to run from. They refuse while any process works inside, and when that cannot be observed.
- **Tests.** TestRemoveRefusesFromInsideTheWorktree, TestRemoveRefusesWhileProcessesWorkInside, TestRemoveRefusesWhenProcessesCannotBeChecked.
- **Holds.** Yes.

## D3. Destroyed the worktree after landing nothing

- **What happened.**
  - Carson 4, 2026-03-31 (release notes 4.3.4): for a task with no commits and four edited files, Carson fast-forwarded nothing, printed "merged into main", and deleted the worktree; the edits were lost.
  - Carson 4, 2026-03-10 (carson#239): an empty branch was pushed before Carson checked it had commits.
  - Carson 4, 2026-03-18 (carson#414): a branch already on `main` was told to land again, in a loop.
- **Root cause.** The landing checked neither for uncommitted files nor for commits to land, and removed the worktree as part of "landing".
- **Fix.** `carson land` refuses uncommitted files and a task with nothing `main` lacks, naming the next step. It never removes anything.
- **Tests.** TestLandRefusesUncommittedFiles, TestLandRefusesATaskWithNothingMainLacks, TestLandOfATaskAlreadyOnMainSaysItHoldsNothingOfItsOwn.
- **Holds.** Yes.

## D4. Reported what it tried, not what happened

- **What happened.**
  - Carson 4, 2026-03-15 and 16 (carson#301, #350, #364): Carson printed "created" for a worktree that did not exist.
  - Carson 4, 2026-03-15 (govern incident review): Carson printed "integrated" while the pull request was still open.
  - Carson 4, 2026-03-06 and 15 (release notes 3.10.2, 3.23.2): a check that always answered "true" let a push guard pass, and reported `main` as synced.
  - Carson 4, also: release notes 2.32.0, 3.13.2, 4.0.3.
  - Carson 5, 2026-09-30 (trials): Carson named `main`'s commit as the task's own work, and called a fresh task "merged and clean".
- **Root cause.** Messages were written from the action attempted; the result was never looked at afterwards.
- **Fix.** Carson looks after every step and reports what it saw:
  - the worktree exists;
  - `main` is the landed commit;
  - GitHub's `main` equals local `main`;
  - a rebase that stopped is undone, and the branch is checked to be back where it was.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestStartReportsAWorktreeMadeDespiteAFailingHook, TestLandFastForwardsMainAndPushes, TestLandWhosePushIsCutOffDoesNotClaimItFailed, TestAPushThatCouldNotBeCheckedIsNotCalledFailed, TestLandUndoesAConflictingRebase, TestRemoveAnEmptyTaskSaysItHeldNothing, TestStatusEndedTaskLandedAndClean.
- **Holds.** Yes.

## D5. Read "cannot tell" as "no"

- **What happened.**
  - Carson 4, 2026-03-21 (carson#422): without `lsof`, the check for a process inside a worktree silently answered "no", and removal went ahead.
  - Carson 4, 2026-09-23 (carson#534): the same check's own detection answered "ok".
- **Root cause.** A failed observation was read as a negative answer.
- **Fix.** Every observation has three answers: yes, no and unknown. Unknown never permits an action.
- **Tests.** TestRemoveRefusesWhenProcessesCannotBeChecked, TestAdoptRefusesAnOwnerWhoseStateIsUnknown, TestStatusRecordNamingNoProcessIsUnknown, TestStartRecordsAndSaysWhenTheHarnessProcessCannotBeObserved.
- **Holds.** Yes.

## D6. One message for many causes, and advice that did not work

- **What happened.**
  - Carson 4, June to 2026-09-19 (carson#527, #531; aix#21, #130): "Cannot receive latest standard" was printed for three different causes, 15 times; diagnosing it required reading Carson's source.
  - Carson 4, 2026-03-26 (carson#522): a dirty file was reported as divergence, and the agent rebased three times for nothing.
  - Carson 4, 2026-03-23 (carson#458, #468): "unable to reach the bureaucrats", with the real cause discarded.
  - Carson 4, 2026-03-16 (carson#348): the advice was a flag the command does not take.
  - Carson 4, 2026-03-16 (current-state audit): the advice taught raw `git` and `gh`.
  - Carson 4, also: carson#280; ai#642, ai#846, ai#878 (2026-06-11); reviews of 2026-03-16; the retrospective of 2026-03-25.
  - Carson 5, 2026-09-30 (trials): advice that failed where the agent stood; a refusal with no next step; git's raw words once `main` was missing.
- **Root cause.** Errors were replaced by generic text, git's own reason was discarded, and no next step was ever run against the state it was given for.
- **Fix.**
  - Each cause has its own message, quoting git's reason, and the files in the way are named.
  - Every refusal names a next step that is a Carson command, or git in the agent's own worktree; the trials ran those steps.
  - Exit codes: 0 done, 1 not finished, 2 refused.
- **Tests.** TestGitGivesTheReasonNotTheURLLine, TestStartNamesModifiedAndUntrackedFilesInTheWay, TestLandRefusesWhenGitHubCannotBeReached, TestAMissingMainIsSaidWithTheWayBack, TestStartMentionsEarlierAbandonedWork, TestStartSaysATaskIsAlreadyYours, TestStartRefusesANameALiveSessionHolds; the trials of 2026-09-30.
- **Holds.** Yes, apart from the messages that hand a case to a person (D7).

## D7. Refused with no way through

- **What happened.**
  - Carson 4, 2026-03-23 (carson#467): a branch whose folder had vanished could not be reattached, and raw `git worktree add` was refused.
  - Carson 4, 2026-03-18 and 19 (carson#418, #413): "branch is behind" had no Carson command, so agents ran raw fetch and rebase; Carson's answer was to refuse those too.
  - Carson 4, 2026-03-24 (carson#491): a hung CI run blocked every commit in three repositories, including the fix.
  - Carson 4, 2026-09-14 (carson#528): a repository whose GitHub copy was empty could not be landed at all.
  - Carson 4, 2026-09-15 (carson#529): in a repository with no commit, "an agent following the rules is forced to stop and ask the user for a raw-git exception on day one".
  - Carson 4, 2026-09-23 (aix#11, aix#12, aix#61): a file left in the main working tree blocked landings with no way through.
  - Carson 4, also: carson#335, #443, #452, #456, #460, #492, #521; ai#923; the retrospective of 2026-03-25; the govern incident review of 2026-03-15.
  - Carson 5, 2026-09-30 (trial): Carson's own advice to run a raw `git worktree add` stranded the agent.
  - Carson 5, to 2026-10-06: in a repository with no commit, `start` still ended with "a person must make its first commit", and named no way to make it.
- **Root cause.** Guards were built to refuse, with no sanctioned way through for the case they refused, so agents learned raw routes (scenario S8). Carson's own design note of 2026-03-16 named the chain: "baseline-red deadlock → escape hatch → bypass habit → guardrail legitimacy erosion".
- **Fix.**
  - `adopt` takes up a branch without a worktree, or abandoned work.
  - `land` brings a task up to `main` itself, and undoes a conflict.
  - `start` pushes `main` to a GitHub copy that has none.
  - In a repository with no commit, `start` makes the first task empty, as an orphan, and its landing makes `main` and pushes it; a `main` GitHub was given meanwhile is brought in first.
  - Carson installs no hooks and never looks at CI.
- **Tests.** TestAdoptTakesUpABranchLeftWithoutAWorktree, TestAdoptTakesUpAbandonedWork, TestLandRebasesOntoANewerMainFirst, TestLandUndoesAConflictingRebase, TestStartPushesMainToAGitHubThatHasNone, TestStartMakesTheFirstTaskOfAnEmptyRepository, TestLandOfTheFirstTaskMakesMainAndPushesIt, TestLandOfTheFirstTaskAfterGitHubWasGivenAMain, TestStartBringsInTheMainGitHubWasGivenSinceTheEmptyClone.
- **Holds.** Partly.
  - Files in the main working tree still end with "ask a person whose they are" (scenarios.md, Open 1).
  - 14 places in Carson 5 hand a case to a person (see Open).

## D8. Started from a stale `main` without a word, or left local `main` behind

- **What happened.**
  - Carson 4, 2026-03-07 to 31 (release notes 3.13.0, 3.29.0, 4.3.3): where a task starts changed three times; one version silently fell back to a stale `main` when the pull failed.
  - Carson 4, 2026-03-23 (carson#481): when the fetch failed, a task silently started from a possibly stale `main`.
  - Carson 4, 2026-09-14 (aix#21): a task started from a `main` ten commits behind, without a word.
  - Carson 4, 2026-03-23 (carson#451): after every landing from a worktree, local `main` fell behind, because the sync used a git command git refuses while `main` is checked out.
  - Carson 4, 2026-03-25 (retrospective): the local landing succeeded, GitHub refused the push, and "done" was claimed.
  - Carson 4, also: carson#339 (2026-03-16); 2026-03-23 (a cascade of conflicts, extra pull requests and lost commits); 2026-09-29 (Carson's own local `main` lacked a release that was on GitHub); aix#193.
- **Root cause.** Proving `main` current was best effort, and keeping the two copies level was a separate step after a landing, which could fail or be skipped.
- **Fix.**
  - `carson start` fetches within 30 seconds and refuses if it cannot.
  - `start` and `land` bring local `main` level with GitHub's first.
  - `land` fast-forwards local `main`, pushes, and looks that both are equal.
  - A failed push is said (exit 1), and the next `land` or `start` pushes it.
- **Tests.** TestStartRefusesWhenGitHubCannotBeReached, TestStartBringsLocalMainForwardToGitHubs, TestLandFastForwardsMainAndPushes, TestLandWhosePushFailsSaysSoAndIsPushedByTheNextMerge, TestStartPushesMergedWorkGitHubLacks.
- **Holds.** Yes.

## D9. Showed no ownership, or misjudged it

- **What happened.**
  - Carson 4, 2026-03-06 (agent-orientation review): agents could see whose a worktree was only by inferring it from `git worktree list`.
  - Carson 4, 2026-03-06 and 07 (release notes 3.9.0, 3.12.0): ownership signals built from process ids fragmented and proved unreliable, and were removed a day later.
  - Carson 5, 2026-09-30 (trial): a Pi session was recorded as Claude, because it had inherited Claude's session variable.
  - **Carson 5, 2026-10-01: the agent that started a task could not land it.** Its harness had continued the conversation, after summarising its context, under a new session id and a new process. The process recorded as the task's owner was still running, so `land` answered that the task belonged to another, live session. `adopt` refuses a live owner too, so no route was left.
- **Root cause.**
  - Carson 4 recorded no owner at all.
  - Carson 5 records the harness's session id and process. The 2026-09-30 defect came from reading an inherited variable instead of the nearest harness.
  - The 2026-10-01 defect's root cause is not yet found.
- **Fix.**
  - An owner record at `start`, in the worktree's own git folder: harness, session, process and the process's start time.
  - The harness nearest Carson is the owner.
  - `status` shows every task under its owner, as live, ended or unknown.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestStartUnderPiInsideClaudeRecordsPi, TestStartUnderClaudeInsidePiRecordsClaude, TestTwoPiSessionsAreToldApart, TestStatusProcessReusedIsEnded, TestStartThenStatusShowsTheTaskLive.
- **Holds.** Partly: the 2026-10-01 defect is open.

## D10. Confused names that git or the disk could not tell apart

- **What happened.**
  - Carson 4, 2026-03-16 (carson#351): a name with `/` was taken for a path.
  - **Carson 5, 2026-09-30 (trial): `carson remove MAIN` deleted `main`.**
  - Carson 5, 2026-09-30 (trial): `github`, a remote's name, was accepted as a task name, and `abandoned` failed in git's raw words.
- **Root cause.** Names were compared letter for letter, while the Mac's disk ignores case. git found the file of `main` when asked for `MAIN`, and no check recognised it as the trunk. Remote names and `abandoned/` share git's namespace with branch names.
- **Fix.**
  - A task's name is lowercase words joined by hyphens.
  - Trunk names are refused in any case, and so are remote names and `abandoned`.
  - Branches are found by their exact name.
  - A name that differs from an existing branch only in case is refused. Once branches are packed, which `git gc` does, git itself lets such a name hide the original (tried 2026-09-30).
- **Tests.** TestStartRefusesANameThatIsNotLowercaseWordsJoinedByHyphens, TestStartRefusesTheTrunkAsATaskName, TestRemoveRefusesTheTrunk, TestRemoveNeverTakesAnotherCaseForABranch, TestStartRefusesNamesGitCannotTellApart, TestStartRefusesANameGitCannotTellFromABranchByCase. Checked again on the released 5.1.0 on 2026-10-01: `carson remove MAIN` is refused, and `main` stays.
- **Holds.** Yes.

## D11. Switched off other checks with its own hooks

- **What happened.**
  - Carson 4, from 0.2.0 to 2026-09-13 (carson#411, #415): in every repository Carson governed, the global checks for empty files, secrets and branches never ran.
  - Carson 4, 2026-03-09 to 13 (release notes 3.21.0, 3.22.1): Carson pushed with `--no-verify` and skipped its own checks.
  - Carson 4, also: carson#420, #425, #525, #526; ai#381, ai#812.
- **Root cause.** Carson set a repository's `core.hooksPath`, which git allows only one of, so it displaced every global hook.
- **Fix.** Carson installs no hooks, sets no git configuration, and pushes without `--no-verify`.
- **Tests.** None yet: see Open.
- **Holds.** Yes, by design.

## D12. Left its own guard open

- **What happened.**
  - Carson 4, 2026-03-21 (carson#419): raw `git push` was blocked only by a hook in each repository, so a repository whose hooks were missing or old accepted it.
  - Carson 4, from 2026-03-25 (release notes 4.3.1): the pre-push hook was made a no-op on purpose, and a raw `git push github main` from a worktree passed everything.
- **Root cause.** A per-repository hook can be missing, and a hook can be switched off.
- **Fix.** Carson guards nothing by hooks. Refusing raw routes is AGT's gate's job, across every repository; the routes still open there are listed in scenarios.md, Open 2.
- **Holds.** Yes, for Carson.

## D13. Kept per-repository facts in one global setting

- **What happened.**
  - Carson 4, 2026-09-12 to 14 and 2026-09-19 (aix#180, aix#185; carson#531; pi#1): one global remote name broke every landing for two days, reported as a network fault.
  - Carson 4, 2026-09-11: a stale registry entry needed editing by hand.
  - Carson 4, 2026-03-09 (release notes 3.22.0): a setting was silently ignored.
- **Root cause.** Carson kept its own configuration for facts that belong to each repository.
- **Fix.** Carson has no configuration; the remote is read from each repository.
- **Tests.** TestStatusPrefersTheRemoteNamedGithubAmongSeveral, TestStatusUsesTheOnlyRemoteWhenMainTracksNone, TestStatusNoRemote.
- **Holds.** Yes.

## D14. Put worktrees inside the main working tree

- **What happened.** Carson 4, 2026-09-15 (carson#530): worktrees were made under `.claude/worktrees`, inside the main working tree, and 42 guard refusals fell on those paths (session transcripts).
- **Root cause.** The worktree folder was fixed for one harness, inside the repository.
- **Fix.** Every worktree is made under `~/.worktrees/`, outside every main working tree.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord.
- **Holds.** Yes.

## D15. Let a network call hang

- **What happened.** Carson 4, 2026-03-14 (session transcript): a git push was still alive after 26 minutes. On 2026-09-30 a fetch hung for minutes.
- **Root cause.** Calls to GitHub had no time limit, git's helper processes outlived them, and git could wait for a password nobody would type.
- **Fix.** Every network call is limited to 30 seconds, and its whole process group is killed. git is told never to ask for a password.
- **Tests.** TestStatusGivesUpOnASilentGitHubWithinTheLimit, TestInterruptingACallToGitHubStopsItsHelpers, TestGitAnswerStandsWhenAChildHoldsThePipes.
- **Holds.** Yes.

## D16. Built machinery for a team that does not exist

- **What happened.** 32 of the catalogued failures. Among them:
  - Carson 4, 2026-03-11 (carson#246): the pull-request lookup lost three commits.
  - Carson 4, 2026-03-15 (govern incident reviews): the background governor deadlocked four pull requests.
  - Carson 4, 2026-03-15 (govern incident review): a merge silently kept `main`'s code over a branch's (scenario S7).
  - Carson 4, 2026-03-23 (carson#466, #469): eight landings stranded, and were merged by hand on GitHub.
  - Carson 4, 2026-03-24 (retrospective): CI minutes ran out, and every job failed.
  - Carson 4, also: carson#57, #203, #214, #238, #251, #281, #282, #287, #334, #347, #352, #360, #390, #421, #423, #439, #444, #445, #459, #461, #462, #464, #465, #510, #520, #523; ai#343, #382, #457, #666, #728, #730, #749, #751, #753–#756, #758, #774, #776; aix#191; release notes, reviews and plans of March 2026.
- **Root cause.** Pull requests, a merge queue, a background governor, CI gates and templates were built for a team that did not exist (the retrospective of 2026-03-24; carson#520).
- **Fix.** None of it exists. Carson lands locally, and runs only when an agent calls it.
- **Holds.** Yes.

## D17. Built for cases that never happened

Carson 5 holds parts that answer no scenario and no defect. They are harmless, and can be deleted when convenient:

- the landing lock;
- the race-proof owner records;
- Ctrl-C handling across a whole landing;
- the check that `bin/check` left the task unchanged;
- "pushed but unchecked" as a third outcome;
- finding a worktree switched off its branch;
- the separate messages for half-done removals;
- the `HOME` checks;
- the unique folder name for kept ignored files;
- the owner record's `Previous` field;
- the next free name `abandoned/<task>-2`;
- the process start time (no reused pid ever gave a wrong answer);
- the refusals for submodules, nested repositories and locked worktrees.

**Root cause.** They were built against risks that merely sounded reasonable, not against failures that had happened. That is the fault D16 shows at a larger scale.

One part has no scenario but rests on a rule, that nothing of the person's is destroyed: removal keeps ignored files, such as `.env`, which `git worktree remove` would delete. That deletion was seen in a test on 2026-09-29, not in real use.

## Open

1. **D9: find the root cause first.** Two facts are missing:
   - what the process recorded as the owner was, once the conversation had moved on;
   - when a harness gives a conversation a new session id: only when it continues one after summarising, or also on resume.

   No fix until both are known.
2. **D1: delete the removal path that has no owner.**
   - A branch left without a worktree then just keeps its name.
   - `start` says the name is taken and names `carson adopt`.
   - `adopt` accepts such a branch even when all its work is on `main` (today it refuses), and its new owner can then remove it.
   - New test: no command deletes a branch whose owner is not the caller.
3. **D1: a test that another session's fresh worktree survives every Carson command** (carson#350).
4. **D7: no case left for a person.** These 14 places change:

   | Where | Carson 5 says | Carson will say |
   |---|---|---|
   | `start.go`, `adopt.go`, `remove.go`: the owner's state cannot be observed | "a person must settle it" | Nothing was changed; the state could not be observed (the reason); run it again. Until its owner is seen to have ended, it is not yours: choose another name, or leave it |
   | `adopt.go`, `remove.go`: the owner record cannot be read | "a person must settle it" | The same as above |
   | `adopt.go`, `remove.go`, `status.go`: a worktree made outside Carson | "a person must settle it" | Made outside Carson, so it is left as it is; start your task under another name |
   | `start.go`, `adopt.go`: the owner record could not be written | "a person must settle it" | Carson undoes what it has just done, and says to run the command again |
   | `start.go`, `land.go` (twice): files in the main working tree in the way | "Ask a person whose they are" | scenarios.md, Open 1 |
   | `lock.go`: the landing lock's holder cannot be observed | "a person must settle it" | Goes with the lock (D17) |

5. **D11: a test that no Carson command changes a repository's git configuration.**
