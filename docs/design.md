# Carson Experience and Brand Design

## Experience goals
- Convey governance clarity: users should quickly understand what is blocked, why, and how to resolve it.
- Keep operational confidence high: command outputs should be deterministic and avoid ambiguous wording.
- Preserve outsider identity: language and UX should reinforce that Carson manages governance without becoming a host-repository runtime dependency.

## Interaction design principles
- Action-first output: surface the blocking condition and next action near the top of command output.
- Stable terminology: use consistent terms for checks, policy blocks, review findings, and dispositions.
- Low-noise defaults: output should remain concise during healthy paths and expand detail only on policy failures.
- Human-review alignment: encourage review discipline, but avoid language implying Carson replaces reviewer judgement.

## Signal system

Carson communicates through three channels. Each carries a distinct, unambiguous meaning.

**Silence.** No output on success. When `carson audit` or `carson review gate` finds nothing wrong, it exits `0` and prints nothing. Silence is the success signal. Users who see nothing can proceed with full confidence.

**The badge.** All non-silent output is prefixed with `⧓` (U+29D3 BLACK BOWTIE). This makes Carson's voice immediately identifiable in terminal logs, CI output, and piped command chains. When a user scans a long log and sees `⧓`, they know immediately who is speaking.

**Exit codes.** Exit codes are the machine-readable signal. `0` means success. `2` means policy blocked — a known, expected state, not an error. `1` means something unexpected went wrong. Automation trusts the exit code; humans read the message. These codes are never repurposed.

## Output design

Each piece of output Carson produces follows a consistent structure: state → reason → action.

```
⧓ BLOCK  unresolved review thread
  → https://github.com/owner/repo/pull/12#discussion_r123456789
  → run: carson review gate --resolve <url>
```

Rules:
- The state word (`BLOCK`, `ERROR`, `OK`) appears first and in caps — scannable at a glance.
- The reason is one line. If it needs more, the design is wrong.
- The action is an exact command the user can copy and run. Never describe what to do; prescribe it.
- Indented continuation lines use `→` as a visual guide. No decorative separators, no box-drawing characters.

Good output: actionable, terse, exact.
Bad output: narrative paragraphs, vague nouns ("something went wrong"), or suggestions without commands.

## Interactive prompt design

Interactive prompts are first-class UX surfaces, not implementation conveniences. Every prompt follows four rules:

1. **One question per prompt.** Never ask two things at once.
2. **One clear default.** The default is always the safe, sensible choice. Display it in brackets: `[Y/n]`.
3. **Every answer leads somewhere.** After accept or decline, Carson tells the user the next step. Never leave the user at a prompt dead end.
4. **TTY guard.** If stdin is not a TTY (CI, piped input), skip the prompt and apply the default silently. Interactive prompts must never block automation.

Example:

```
⧓ Template drift detected: .github/workflows/ci.yml
  Apply managed version? [Y/n]: _

  → Applied. Run: git add .github/workflows/ci.yml
```

## UX principles

**Ask once, remember forever.** Carson prompts for preferences during setup and stores them. It never asks the same question twice. Re-running a command should feel identical to the first time, without re-entering preferences.

**Carson manages; the user decides.** Carson prepares everything for a merge decision but does not make it. It surfaces policy violations but does not bypass them. It dispatches agents to fix problems but reports what was done. The user retains authority; Carson handles the administration.

**Upgrades are invisible.** When Carson is updated, governed repositories are updated with it. The user should not need to visit each repository after an upgrade, remember to apply templates, or clean up old files. Carson does this automatically.

## Ideal user journey

### Stage 1 — Installation

The user installs Carson with one command and it is immediately usable. No project scaffolding, no configuration wizard, no environment variables to set. Carson detects sensible defaults on first use.

The user does not think about Carson's installation again. If they upgrade, `bash install.sh` runs the upgrade and propagates any changes to governed repositories automatically.

### Stage 2 — Onboarding a repository

The user runs `carson onboard` once per repository. Carson asks only what it cannot detect: the merge method and whether to register the repo for portfolio governance. Everything else — remote, main branch, workflow style — is inferred from the repository itself.

After onboarding, the user commits the generated `.github/*` files. The repository is governed. That is the last time the user thinks about setup for that repository.

### Stage 3 — Daily commit flow

This is the core of the daily experience. The user writes code and commits. Most of the time, nothing happens — governance is healthy and Carson is silent. The commit goes through.

When governance is not healthy, the commit is blocked. Carson surfaces exactly one actionable message: what is wrong, and what command fixes it. The user runs that command, commits again. No digging through logs, no guessing.

The psychological contract: _silence means safety_. If Carson says nothing, the user can trust the commit is clean. This makes the occasional block feel informative rather than obstructive.

### Stage 4 — Review and merge

Before recommending a merge, the user runs `carson review gate`. Carson checks for unresolved review threads, outstanding CHANGES_REQUESTED reviews, and comments containing risk keywords. If anything is open, Carson reports it with the URL and blocks.

The user either resolves the thread or records a disposition (`Disposition: accepted`, `rejected`, or `deferred`) acknowledging the finding. Carson re-evaluates. When the gate passes, the user can recommend merge with full confidence that every reviewer comment has been seen and handled.

This stage removes the social anxiety of merge decisions — the user is not guessing whether something was missed. Carson has verified the record.

### Stage 5 — Portfolio governance

Once multiple repositories are onboarded, the user shifts from per-repo commands to portfolio commands. `carson govern` runs across all registered repositories: it triages open PRs, merges what is ready, dispatches coding agents to fix what is failing, and escalates what needs human judgment. The user reviews the escalation list; everything else was handled.

`carson refresh --all` keeps templates in sync across all repositories without the user visiting each one. When Carson is upgraded, this runs automatically.

The psychological contract at portfolio scale: _one command means all is well_. The user runs `carson govern`, sees the summary, and knows the state of every project.

### Stage 6 — Offboarding

When a repository no longer needs governance, `carson offboard` removes every Carson-managed file cleanly. The repository returns to exactly the state it was in before onboarding — no lingering hooks, no managed templates, no Carson configuration. The offboard is transparent: Carson lists every file it removes before removing it.

## Documentation UX intent
- README is first-read orientation for new users.
- Manual focuses on practical operation and troubleshooting.
- API reference defines contract-level behaviour (commands, exits, configuration).
- Internal `/docs` content remains implementation-facing and is not part of first-run user onboarding.

## Brand mark
- Carson's brand mark is ⧓ (U+29D3 BLACK BOWTIE) — a formal bow tie, after the Downton Abbey butler's white-tie evening dress.
- The badge prefixes all CLI output lines so Carson's voice is always identifiable in terminal logs.
- Use ⧓ as the app icon, GitHub avatar, and documentation heading mark.

## Brand language
- Tone: precise, operational, and credible.
- Claims: factual and verifiable; avoid hype language.
- Positioning: Carson is an autonomous git strategist and repositories governor for GitHub workflows, not a GitHub replacement.
- Voice: Carson speaks as the butler it is — measured, direct, and never flustered. It does not apologise for blocks, celebrate successes, or editorialize. It states facts and prescribes actions.

### Vocabulary guide

Use consistent terms across all surfaces (CLI output, documentation, error messages):

| Preferred | Avoid |
|-----------|-------|
| policy block | error, failure, violation |
| governance check | linting, validation |
| disposition | acknowledgement, note |
| outsider boundary | isolation, sandbox |
| merge-ready | approved, green |
| review thread | comment, note |
| managed file | owned file, Carson file |

## UX quality checks
- Every blocking output includes a clear remediation path.
- Core workflows (`onboard`, `audit`, `review gate`) can be understood without internal implementation knowledge.
- Documentation links lead users from orientation to operation in one step.
- No prompt leaves the user without a next step.
- Silent success is treated as a feature, not a missing confirmation message.
