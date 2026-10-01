# Carson's scars

Carson exists for one purpose: to stop scars, meaning damage that really happened, from happening again. This is the list of those scars, grouped by root cause. Each root cause gives:

- the scars it produced;
- why they happened;
- the feature of Carson that removes that cause;
- the tests that recreate those scars;
- whether it holds today.

**The rules for changing Carson.**

1. **No feature without a scar.** A feature that answers no scar has no reason to be in Carson.
2. **Root cause first.** A scar gets its root cause found before any feature, because a feature aimed at a symptom is useless.
3. **A test that recreates the scar.** Every scar gets one, and it fails on the Carson that let the scar happen.
4. **No case left for a person.** Carson serves agents: no outcome may end with a person having to settle it.
5. **Carson works while no scar below happens again.** A new scar gets its root cause found first, then a row here and a test, and only then a feature.

**Where the scars come from.**

- **162 failures of Carson 4,** catalogued on 2026-09-29 from Carson's issues, the issues of the repositories it served, its release notes, reviews and retrospectives, and the agents' own record of mistakes. Of the 162:
  - 118 fall under the root causes Carson holds (R1–R16, R19);
  - 16 are held by AGT's gate (R17, R18);
  - 15 were faults of that gate itself;
  - 13 were outside Carson (documents, tests, other acts of agents).
- **9 failures of Carson 5 (T1–T9),** found when agents of three model families used it in sandboxes on 2026-09-30.
- **3 found on 2026-10-01 (X1–X3).**

## Status on 2026-10-01

| | Root cause | Held by | Holds |
|---|---|---|---|
| R1 | Starting from a `main` nobody had proved current | Carson | Yes |
| R2 | Two copies of `main`, kept level by a separate step that could fail or be skipped | Carson | Yes |
| R3 | Nothing looked at a landing's content before `main` moved | Carson runs the repository's check | Partly: the check is the repository's |
| R4 | Landing and removing were one step, and an empty landing still "succeeded" | Carson | Yes |
| R5 | Removal was not one complete act declared by the task's owner | Carson | Partly: one removal path has no owner |
| R6 | Removal could run while someone worked inside, or from inside | Carson | Yes |
| R7 | Nothing recorded whose a worktree was, or whether its agent still worked | Carson | Partly: a continued conversation could not land its own task (X3) |
| R8 | "Cannot tell" was read as "no" | Carson | Yes |
| R9 | Carson reported what it tried, not what it saw | Carson | Yes |
| R10 | One message for many causes, and advice nobody had run | Carson | Yes |
| R11 | Refusals with no way through, so agents went around them | Carson | Partly: two dead ends remain |
| R12 | Network calls with no time limit | Carson | Yes |
| R13 | Carson's own hooks switched off every other check | Carson, by installing none | Yes |
| R14 | One machine-wide setting held facts that belong to each repository | Carson, by having no settings | Yes |
| R15 | Machinery for a team that does not exist: pull requests, queues, a background governor, CI gates | Carson, by having none of it | Yes |
| R16 | Worktrees made by several routes, inside the main working tree | Carson and Claude Code's worktree hooks | Partly: a raw `git worktree add` is open |
| R17 | Raw routes around Carson were open | AGT's gate, GitHub's ruleset | Partly: a raw push of `main` is open |
| R18 | Agents worked in the main working tree, which everyone shares | AGT's gate | Yes |
| R19 | Names that git or the disk could not tell apart | Carson | Yes |

- **13 of the 19 hold completely.** For 11 of them, tests recreate their scars; all 165 of Carson's tests pass (`bin/check` on 2fc3547, 2026-10-01). R13 and R15 hold because the code that caused them does not exist.
- **Four are open in Carson:** X3 (R7), a removal path without an owner (R5), and two dead ends (R11). See "Open".
- **Two are open in AGT's gate:** a raw `git worktree add` (R16) and a raw push of `main` (R17).

## The root causes

### R1. Starting from a `main` nobody had proved current

- **Scars.**
  - 2026-09-14 (aix#21): on a second machine, local `main` was ten commits behind. A task started from it, and files the other machine had moved lingered.
  - 2026-03-23 (carson#481): when the fetch failed, a task silently started from a possibly stale `main`.
  - 2026-03-11 (ai#347): an agent rebuilt a page from a stale source and overwrote the latest design.
  - Also: where a task starts changed three times between 2026-03-07 and 31 (release notes 3.13.0, 3.29.0, 4.3.3); aix#193 (2026-09-24).
- **Root cause.** Starting a task never required proof that local `main` matched GitHub's. The fetch was best effort, and if it failed, the task started from whatever local `main` held, without a word.
- **Feature.** `carson start` fetches GitHub's `main` within 30 seconds and refuses if it cannot. It brings local `main` level first: it pushes what GitHub lacks and fast-forwards what local lacks. Only then does it branch.
- **Tests.** TestStartRefusesWhenGitHubCannotBeReached, TestStartBringsLocalMainForwardToGitHubs, TestStartPushesMergedWorkGitHubLacks.
- **Holds.** Yes.

### R2. Two copies of `main`, kept level by a separate step that could fail or be skipped

- **Scars.**
  - 2026-03-23 (carson#451): after every landing from a worktree, local `main` fell behind, because the sync step used a git command that git refuses while `main` is checked out.
  - 2026-03-25 (retrospective): the local landing succeeded, GitHub refused the push, and "done" was claimed.
  - 2026-09-29: Carson's own local `main` lacked a release that was on GitHub.
  - X1, 2026-10-01: in a private repository, 23 landings made by fast-forward before Carson 5 had never been pushed.
  - X2, 2026-10-01: meanwhile a commit was pushed to GitHub from a second machine, so the two `main`s diverged.
  - Also: carson#339 (2026-03-16); a cascade of conflicts, extra pull requests and lost commits (2026-03-23).
- **Root cause.** A landing went to one side, and the other side was brought level by a later, separate step. That step could fail or be skipped, and nothing made "landed" mean "on both".
- **Feature.** One landing order:
  1. Bring local `main` level with GitHub's first.
  2. Fast-forward local `main` to the task.
  3. Push, and look that GitHub's `main` now equals local `main`.
  4. If the push fails, say so (exit 1); the next `land` or `start` pushes it.
  5. If the two `main`s have diverged, merge GitHub's `main` into the task, in its own worktree. Never rebase that merge away: a plain rebase drops GitHub's commits from the task (tried 2026-09-30), and the push would be refused. Both moves then stay fast-forwards.
- **Tests.** TestLandFastForwardsMainAndPushes, TestLandWhosePushFailsSaysSoAndIsPushedByTheNextMerge, TestStartPushesMergedWorkGitHubLacks, TestLandRetryAfterAFailedPushJoinsAGitHubThatMovedOn, TestLandJoinsDivergedMains, TestLandKeepsATaskThatCarriesAJoinUnflattened, TestStartWhenMainsDivergedSaysTheMergeWillJoinThem.
- **Holds.** Yes, for every landing through Carson. X1 and X2 are joined by the next landing in that repository.

### R3. Nothing looked at a landing's content before `main` moved

- **Scar.** 2026-03-18 (carson#416): a file move committed an empty file and deleted another; 151 lines of rules were lost. A check added the next day never ran (R13).
- **Root cause.** The agent's move emptied a file, and nothing between the commit and `main` looked at the result.
- **Feature.** `carson land` runs the repository's `bin/check` on the exact commit that will land, before `main` moves; a failure stops the landing. Carson installs no hooks, so nothing it does switches a check off.
- **Tests.** TestLandStopsWhenTheChecksFail, TestLandSaysTheChecksPassed, TestLandFailedCheckAfterARebaseSaysSo.
- **Holds.** Partly. Carson guarantees that the check runs; whether an emptied file is caught depends on what the repository's check looks at.

### R4. Landing and removing were one step, and an empty landing still "succeeded"

- **Scars.**
  - 2026-03-31 (release notes 4.3.4): an agent edited four files and landed without committing. Carson fast-forwarded nothing, printed "merged into main" and deleted the worktree. The edits were lost.
  - 2026-03-10 (carson#239): an empty branch was pushed, then failed late.
  - 2026-03-18 (carson#414): a branch already on `main` was told to land again, in a loop.
- **Root cause.** The landing checked neither for uncommitted files nor for commits to land, and it removed the worktree as part of "landing".
- **Feature.** `carson land` refuses uncommitted files (naming them) and a task with nothing `main` lacks (naming `carson remove`). It never removes anything: removal is the owner's separate command.
- **Tests.** TestLandRefusesUncommittedFiles, TestLandRefusesATaskWithNothingMainLacks, TestLandOfATaskAlreadyOnMainSaysItHoldsNothingOfItsOwn.
- **Holds.** Yes.

### R5. Removal was not one complete act declared by the task's owner

- **Scars.**
  - 2026-03-06 (release notes 2.33.0): removal used force by default and destroyed uncommitted work.
  - 2026-03-05 to 07 (release notes 2.27.0, 3.15.1, 3.16.0): branches were deleted because their files matched `main`.
  - 2026-03-16 (carson#350), and again 2026-09-23 (aix#57): a worktree made minutes earlier was swept away as "absorbed into main".
  - 2026-03-16 (current-state audit): once a worktree's folder had vanished, cleanup could delete its branch even when that branch was the last copy of the work.
  - 2026-03-23 (carson#457): one call removed every worktree it judged dead.
  - 2026-03-19 (ai#782, ai#720): an agent abandoning in a panic nearly destroyed a session's work.
  - 2026-07-29 (aix#75): a branch left behind after release blocked its name.
  - **T1, 2026-09-30: `carson remove MAIN` deleted `main`.**
  - Also: release notes 2.32.0 (2026-03-06); carson#513, #524, #484; aix#102; 21 worktrees lingering across 7 repositories (2026-09-13).
- **Root cause.** Removal acted on Carson's own judgement, such as "its content is on main", "absorbed" or "dead", instead of the owner's declaration. It also used force, removed in batches, or left the branch behind.
  - T1 has the same root. A path for "leftover branches" deleted a branch that had no owner, judging only that "its work is on main", which `main` itself always is. Its name checks also compared letters exactly on a disk that ignores case (R19).
- **Feature.** Nothing is removed unless the task's owner names it:
  - `carson remove <task>` for landed work: worktree and branch together, from outside, by git's safe delete, never by force, one task per call.
  - `carson abandon <task>` for unfinished work: uncommitted files are committed onto the branch, ignored files are kept, and the branch is kept as `abandoned/<task>`.
  - There is no sweep.
- **Tests.** TestRemoveRemovesAMergedTask, TestRemoveRefusesUncommittedFiles, TestRemoveRefusesWorkNotOnMain, TestRemoveRefusesAnotherSessionsTask, TestRemoveATaskWhoseFolderIsGoneWithWorkNotOnMain, TestRemoveAbandonedKeepsEverything, TestRemoveAbandonedRefusesWhileARebaseIsInProgress, TestRemoveNeverTakesAnotherCaseForABranch.
- **Holds.** Partly.
  - The leftover-branch path is still there (`removeLeftoverBranch` in `remove.go`): it deletes a branch that no owner declared. T1 went through it. Its own scar (aix#75) has a root cause that is already gone, because `remove` now deletes the branch together with its worktree.
  - No test yet shows that another session's fresh worktree survives every command (carson#350).

### R6. Removal could run while someone worked inside, or from inside

- **Scars.**
  - 2026-03-05 to 09 (ai#765; release notes 3.10.0): worktrees were deleted with an agent's shell inside, "the #1 agent session crash".
  - 2026-03-07 (carson#189, #190): a merge with `--delete-branch`, run from inside, deleted the worktree and killed the shell.
  - 2026-03-19 (carson#417): an owner could not release its worktree, and `prune` did nothing silently.
  - Also: carson#277, #304.
- **Root cause.** Removal never looked at which processes worked inside the folder, and it could be started from inside the very worktree it deleted.
- **Feature.** `carson remove` and `carson abandon` run only from outside, and name the folder to run from. They refuse while any process works inside, naming it with its pid. They also refuse when that cannot be observed.
- **Tests.** TestRemoveRefusesFromInsideTheWorktree, TestRemoveRefusesWhileProcessesWorkInside, TestRemoveRefusesWhenProcessesCannotBeChecked, TestPSFindsAProcessWorkingInsideAFolder.
- **Holds.** Yes.

### R7. Nothing recorded whose a worktree was, or whether its agent still worked

- **Scars.**
  - 2026-03-30 (ai#872, ai#877): an agent landed another session's branch; nine corrections followed.
  - 2026-03-06 (ai#760): an agent force-removed a live session's worktree.
  - 2026-03-09 (ai#741): an agent discarded a person's commit as "another session's".
  - 2026-09-13 (session transcript): an agent did not recognise its own worktree, which held the only copy of a 333-line plan.
  - T2, 2026-09-30: a Pi session was recorded as Claude.
  - **X3, 2026-10-01: the agent that started a task could not land it.** Its harness had continued the conversation, after summarising its context, under a new session id and a new process. The process recorded as the task's owner was still running, so `land` answered that the task belonged to another, live session, and `adopt` refuses a live owner too. No route was left.
  - Also: ai#759; a review of 2026-03-06; release notes 3.9.0 and 3.12.0 (ownership signals built from process ids, unreliable, removed).
- **Root cause.** Nothing recorded who made a worktree. Ownership was guessed from names, files and `git worktree list`, and whether its agent still worked could not be observed.
- **Feature.**
  - `carson start` writes an owner record in the worktree's own git folder: harness, session, process and the process's start time. The harness nearest Carson is the owner.
  - `land`, `remove` and `abandon` act only for the owner.
  - `adopt` takes over only a task whose owner is seen to have ended.
  - `status` shows every task under its owner, as live, ended or unknown.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestLandRefusesAnotherSessionsTask, TestAdoptRefusesALiveOwnersTask, TestAdoptAnEndedAgentsTask, TestStatusProcessReusedIsEnded, TestStartUnderPiInsideClaudeRecordsPi, TestTwoPiSessionsAreToldApart, TestStartThenStatusShowsTheTaskLive.
- **Holds.** Partly.
  - Every scar before X3 holds.
  - X3 shows that the harness's session id is not stable for one agent's work; its root cause is not yet found.
  - The refusals still end with "a person must settle it" (see "No case left for a person").

### R8. "Cannot tell" was read as "no"

- **Scars.**
  - 2026-03-21 (carson#422): without `lsof`, the check for a process inside silently answered "no", and removal went ahead.
  - 2026-09-23 (carson#534): the same check's own detection answered "ok".
- **Root cause.** A failed observation was read as a negative answer.
- **Feature.** Every observation has three answers: yes, no and unknown. Unknown never permits an action, so removal and adoption refuse.
- **Tests.** TestRemoveRefusesWhenProcessesCannotBeChecked, TestAdoptRefusesAnOwnerWhoseStateIsUnknown, TestStatusRecordNamingNoProcessIsUnknown, TestStartRecordsAndSaysWhenTheHarnessProcessCannotBeObserved.
- **Holds.** Yes.

### R9. Carson reported what it tried, not what it saw

- **Scars.**
  - 2026-03-15 and 16 (carson#301, #350, #364): Carson printed "created" for a worktree that did not exist.
  - 2026-03-15 (govern incident review): Carson printed "integrated" while the pull request was still open.
  - 2026-03-06 and 15 (release notes 3.10.2, 3.23.2): a check that always answered "true" let a push guard pass and reported `main` as synced.
  - T3, T4, 2026-09-30: Carson called `main`'s commit the task's own, and called a fresh task "merged and clean".
  - Also: release notes 2.32.0, 3.13.2, 4.0.3.
- **Root cause.** Messages were written from the action attempted; the result was never looked at afterwards.
- **Feature.** Carson looks after every step and reports what it saw:
  - the worktree exists;
  - `main` is the landed commit;
  - GitHub's `main` equals local `main`;
  - a rebase that stopped is undone, and the branch is checked to be back where it was.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, TestStartReportsAWorktreeMadeDespiteAFailingHook, TestLandFastForwardsMainAndPushes, TestLandWhosePushIsCutOffDoesNotClaimItFailed, TestAPushThatCouldNotBeCheckedIsNotCalledFailed, TestLandUndoesAConflictingRebase, TestRemoveAnEmptyTaskSaysItHeldNothing, TestStatusEndedTaskLandedAndClean.
- **Holds.** Yes.

### R10. One message for many causes, and advice nobody had run

- **Scars.**
  - June to 2026-09-19 (carson#527, #531; aix#21, #130): "Cannot receive latest standard" was printed for three different causes, 15 times; diagnosing it required reading Carson's source.
  - 2026-03-26 (carson#522): a dirty file was reported as divergence, and the agent rebased three times for nothing.
  - 2026-03-23 (carson#458, #468): "unable to reach the bureaucrats", with the real cause discarded.
  - 2026-03-16 (carson#348): the advice was a flag the command does not take.
  - 2026-03-16 (current-state audit): the advice taught raw `git` and `gh`.
  - T6, T8, T9, 2026-09-30: advice that failed where the agent stood, a refusal with no next step, and git's raw words once `main` was missing.
  - Also: carson#280; ai#642, #846; a review of 2026-03-16; the retrospective of 2026-03-25.
- **Root cause.** Errors were replaced by generic text, git's own reason was discarded, and no next step was ever run against the state it was given for.
- **Feature.**
  - Each cause has its own message, quoting git's reason, and the files in the way are named.
  - Every refusal names a next step that is a Carson command, or git in the agent's own worktree. The trials ran those steps.
  - Exit codes are 0 for done, 1 for not finished and 2 for refused.
- **Tests.** TestGitGivesTheReasonNotTheURLLine, TestStartNamesModifiedAndUntrackedFilesInTheWay, TestLandRefusesWhenGitHubCannotBeReached, TestAMissingMainIsSaidWithTheWayBack, TestStartMentionsEarlierAbandonedWork, TestStartSaysATaskIsAlreadyYours, TestStartRefusesANameALiveSessionHolds; also the trials of 2026-09-30.
- **Holds.** Yes, apart from the messages that hand a case to "a person".

### R11. Refusals with no way through, so agents went around them

- **Scars.**
  - 2026-03-23 (carson#467): a branch whose folder had vanished could not be reattached, and raw `git worktree add` was refused.
  - 2026-03-18 and 19 (carson#418, #413): "behind main" had no Carson command, so agents ran raw fetch and rebase.
  - 2026-03-24 (carson#491): a hung CI run blocked every commit in three repositories, including the fix.
  - 2026-09-14 (carson#528, aix#162): a repository whose GitHub copy was empty could not be landed at all.
  - 2026-09-15 (carson#529): in a repository with no commit, "an agent following the rules is forced to stop and ask the user for a raw-git exception on day one".
  - 2026-09-23 (aix#11, #12): a file a skill left in the main working tree blocked a landing with no way through; about 30 minutes were lost, and the person the agents work for was interrupted.
  - 2026-09-23 (aix#61): blocked the same way, an agent asked a person to run `git reset --hard`, then cleared another session's file itself.
  - T5, 2026-09-30: Carson's own advice to run a raw `git worktree add` stranded the agent.
  - Also: carson#335, #443, #452, #456, #460, #492, #521; ai#923; the retrospective of 2026-03-25; the govern incident review of 2026-03-15.
- **Root cause.** Guards were built to refuse, with no sanctioned way through for the case they refused. So agents learned raw routes. Carson's own design note of 2026-03-16 named the chain: "baseline-red deadlock → escape hatch → bypass habit → guardrail legitimacy erosion".
- **Feature.**
  - `adopt` takes up a branch without a worktree, or abandoned work.
  - `land` brings a task up to `main` itself, and undoes a conflict.
  - `start` pushes `main` to a GitHub copy that has none.
  - Carson installs no hooks and never looks at CI.
- **Tests.** TestAdoptTakesUpABranchLeftWithoutAWorktree, TestAdoptTakesUpAbandonedWork, TestLandRebasesOntoANewerMainFirst, TestLandUndoesAConflictingRebase, TestStartPushesMainToAGitHubThatHasNone.
- **Holds.** Partly. Two dead ends are still there: an empty repository (carson#529), where Carson says "a person must make its first commit", and files in the main working tree (aix#11, #12, #61), where Carson says "ask a person whose they are".

### R12. Network calls with no time limit

- **Scars.** 2026-03-14 (session transcript): a git push was still alive after 26 minutes. 2026-09-30: a fetch hung for minutes.
- **Root cause.** Calls to GitHub had no time limit, git's helper processes outlived them, and git could wait for a password nobody would type.
- **Feature.** Every network call is limited to 30 seconds, and its whole process group is killed. git is told never to ask for a password.
- **Tests.** TestStatusGivesUpOnASilentGitHubWithinTheLimit, TestInterruptingACallToGitHubStopsItsHelpers, TestGitAnswerStandsWhenAChildHoldsThePipes.
- **Holds.** Yes.

### R13. Carson's own hooks switched off every other check

- **Scars.**
  - From Carson 0.2.0 to 2026-09-13 (carson#411, #415): in every repository Carson governed, the global checks for empty files, secrets and branches never ran.
  - 2026-03-09 to 13 (release notes 3.21.0, 3.22.1): Carson pushed with `--no-verify` and skipped its own checks.
  - Also: carson#420, #425, #525, #526; ai#381, #812.
- **Root cause.** Carson set a repository's `core.hooksPath`, which git allows only one of, so it displaced every global hook.
- **Feature.** Carson installs no hooks, sets no git configuration and pushes without `--no-verify`.
- **Tests.** None yet. A test is to be added: no Carson command changes a repository's git configuration.
- **Holds.** Yes, by design.

### R14. One machine-wide setting held facts that belong to each repository

- **Scars.**
  - 2026-09-12 to 14, and 2026-09-19 (aix#180, #185; carson#531): one global remote name broke every landing for two days, reported as a network fault.
  - 2026-09-11: a stale registry entry needed editing by hand.
  - 2026-03-09 (release notes 3.22.0): a setting was silently ignored.
- **Root cause.** Carson kept its own configuration for facts that belong to each repository.
- **Feature.** Carson has no configuration; the remote is read from each repository.
- **Tests.** TestStatusPrefersTheRemoteNamedGithubAmongSeveral, TestStatusUsesTheOnlyRemoteWhenMainTracksNone, TestStatusNoRemote.
- **Holds.** Yes.

### R15. Machinery for a team that does not exist

- **Scars.** 32 failures. Among them:
  - 2026-03-11 (carson#246): the pull-request lookup lost three commits.
  - 2026-03-15 (govern incident reviews): the background governor deadlocked four pull requests.
  - 2026-03-23 (carson#466, #469): eight landings stranded and were merged by hand on GitHub.
  - 2026-03-24 (retrospective): CI minutes ran out, and every job failed.
  - Also: carson#57, #203, #214, #238, #251, #281, #282, #287, #334, #347, #352, #360, #390, #421, #423, #439, #444, #445, #459, #461, #462, #464, #465, #510, #520, #523; ai#382, #666, #728, #730, #749, #751, #753–#756, #758, #774, #776; aix#191; release notes, reviews and plans of March 2026.
- **Root cause.** Pull requests, a merge queue, a background governor, CI gates and templates were built for a team that did not exist (the retrospective of 2026-03-24; carson#520).
- **Feature.** None of it exists. Carson lands locally, and runs only when an agent calls it.
- **Tests.** None needed: the code does not exist.
- **Holds.** Yes.

### R16. Worktrees made by several routes, inside the main working tree

- **Scars.**
  - 2026-09-15 (carson#530): worktrees were made inside the main working tree, under `.claude/worktrees`, and 42 guard refusals fell on those paths (session transcripts).
  - Claude Code's own worktree tool made worktrees outside Carson, with random names and a possibly stale start (Carson 4's manual, 2026-03-26).
  - The 2026-09-13 orphan (R7) was made outside Carson.
- **Root cause.** Worktrees were made by Carson, by the harness's tool and by raw git, inside the main working tree.
- **Feature.** Carson makes every worktree under `~/.worktrees/`, outside every main working tree. Claude Code's worktree hooks (in AGT) send the harness's own tool through `carson start` and `carson remove`.
- **Tests.** TestStartMakesTheTaskWorktreeAndItsOwnerRecord, and AGT's hook tests.
- **Holds.** Partly. A raw `git worktree add` still passes every layer; that belongs to AGT's gate.

### R17. Raw routes around Carson were open

- **Scars.**
  - 2026-03-11 (ai#345, #346): one session made 16 raw pushes and 20 raw merges.
  - 2026-03-11 (ai#367, #734): an agent copied Carson's own signal to pass its hook.
  - 2026-09-16 (ai#932): a raw fast-forward was run on the main working tree.
  - 2026-09-15 (ai#929): a commit was made with the hooks switched off.
  - From 2026-03-25 (release notes 4.3.1): a raw `git push github main` from a worktree passes everything.
  - Also: carson#419; aix#70; ai#352.
- **Root cause.** Two things together: refusals with no way through (R11) pushed agents to raw routes, and those routes were open.
- **Feature.** Carson's part is R11: a way through for every case. The refusals belong to AGT's gate, which refuses force pushes, commits and merges that are not fast-forwards in the main working tree, rebases, resets, `checkout`, `clean`, and stash drop and clear. GitHub's ruleset refuses a force push or deletion of `main`.
- **Tests.** AGT's tests.
- **Holds.** Partly. A raw push of `main` from a worktree is still open in the gate.

### R18. Agents worked in the main working tree, which everyone shares

- **Scars.**
  - 2026-03-04 (ai#767): stash, checkout and clean destroyed 26 files.
  - 2026-03-10 (ai#297): a person's uncommitted edits in the main working tree were discarded.
  - 2026-03-23: a file untracked in one tree was deleted from another by a fast-forward.
  - 2026-03-09 (ai#747, #742): three commits were made straight on `main` in one session.
  - Also: carson#260; ai#380, #768, #893, #894.
- **Root cause.** The main working tree is shared, nothing there says whose a change is, and the rule against working there was only text.
- **Feature.** AGT's gate refuses agents' edits, shell writes, commits, `checkout` and `clean` there. Carson never fast-forwards over a file there.
- **Tests.** TestLandRefusesToOverwriteAModifiedFileInTheMainTree, TestLandRefusesToOverwriteWhatTheMainTreeHolds, TestStartRefusesAFastForwardThatWouldOverwriteAnIgnoredFile; AGT's tests.
- **Holds.** Yes.

### R19. Names that git or the disk could not tell apart

- **Scars.**
  - **T1, 2026-09-30: `carson remove MAIN` deleted `main`.**
  - T7, 2026-09-30: `github`, a remote's name, was accepted as a task name, and `abandoned` failed in git's raw words.
  - 2026-03-16 (carson#351): a name with `/` was taken for a path.
- **Root cause.** Names were compared letter for letter, while the Mac's disk ignores case. git found the file of `main` when asked for `MAIN`, and none of the checks recognised it as the trunk. Remote names and `abandoned/` share git's namespace with branch names.
- **Feature.**
  - A task's name is lowercase words joined by hyphens.
  - Trunk names are refused in any case, and so are remote names and `abandoned`.
  - Branches are found by their exact name.
  - A name that differs from an existing branch only in case is refused. Once branches are packed, which `git gc` does, git itself lets such a name hide the original (tried 2026-09-30).
- **Tests.** TestStartRefusesANameThatIsNotLowercaseWordsJoinedByHyphens, TestStartRefusesTheTrunkAsATaskName, TestRemoveRefusesTheTrunk, TestRemoveNeverTakesAnotherCaseForABranch, TestStartRefusesNamesGitCannotTellApart, TestStartRefusesANameGitCannotTellFromABranchByCase. Checked again on the released 5.1.0 on 2026-10-01: `carson remove MAIN` is refused, and `main` stays.
- **Holds.** Yes.

## Open

1. **X3 (R7): find the root cause first.** Two facts are missing:
   - what the process recorded as the owner was, once the conversation had moved on;
   - when a harness gives a conversation a new session id: only when it continues one after summarising, or also on resume.

   No feature until both are known.
2. **R5: delete the removal path that has no owner.** It removes a branch nobody declared finished, and it is the path T1 went through.
   - A branch left without a worktree then just keeps its name.
   - `start` says the name is taken and names `carson adopt`.
   - `adopt` accepts such a branch even when all its work is on `main` (today it refuses), and its new owner can then remove it.
   - New test: no command deletes a branch whose owner is not the caller.
3. **R5: the missing scar test (carson#350).** Another session's fresh worktree survives every Carson command.
4. **R11: an empty repository (carson#529).** `start` makes the first task as an orphan, and its landing makes `main` and pushes it. git does this in two commands: `git worktree add --orphan -b <task>`, then `git merge --ff-only <task>` in the main working tree (tried 2026-09-30).
5. **R11: files in the main working tree in the way of a landing (aix#11, #12, #61).**
   - **Where they came from.** Something wrote into the main working tree and left it there: a skill, hooks writing tracked files every session (ai#923), a generated file. AGT's gate now refuses agents' writes there. What remains is what the gate cannot see, such as scripts and tools, and a person's own edits.
   - **Proposed, not yet decided.** When such files stand in the way of a fast-forward, Carson keeps them as abandoned work on a branch, `abandoned/main-tree-<date-time>`. `carson status` shows it, and `carson adopt` takes it up like any abandoned task. Carson then puts those paths back to `main` and lands. Nothing is lost, and nobody is asked.
   - **The cost.** A person's own uncommitted edits in a repository edited by hand would leave the working tree and wait on that branch.
6. **R13: the missing scar test.** No Carson command changes a repository's git configuration.
7. **AGT's gate (R16, R17).** Refuse a raw `git worktree add`, pointing to `carson start` and `carson adopt`. Refuse a raw `git push <remote> main`, pointing to `carson land`.

## No case left for a person

Carson 5 hands a case to "a person" in these 15 places, and each changes as follows:

| Where | Carson 5 says | Carson will say |
|---|---|---|
| `start.go`, `adopt.go`, `remove.go`: the owner's state cannot be observed | "a person must settle it" | Nothing was changed; the state could not be observed (the reason); run it again. Until its owner is seen to have ended, it is not yours: choose another name, or leave it |
| `adopt.go`, `remove.go`: the owner record cannot be read | "a person must settle it" | The same as above |
| `adopt.go`, `remove.go`, `status.go`: a worktree made outside Carson | "a person must settle it" | Made outside Carson, so it is left as it is; start your task under another name |
| `start.go`, `adopt.go`: the owner record could not be written | "a person must settle it" | Carson undoes what it has just done, and says to run the command again |
| `start.go`, `land.go` (twice): files in the main working tree in the way | "Ask a person whose they are" | Open item 5 |
| `repository.go`: no `main` yet | "a person must make its first commit" | Open item 4: `start` works |
| `lock.go`: the landing lock's holder cannot be observed | "a person must settle it" | Goes with the lock, which has no scar |

## Parts with no scar behind them

They are harmless, and can be deleted when convenient:

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

One part has no scar but rests on a rule, that nothing of the person's is destroyed: removal keeps ignored files, such as `.env`, which `git worktree remove` would delete. That deletion was seen in a test on 2026-09-29, not in real use.
