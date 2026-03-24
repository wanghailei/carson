# GitHub CI for Carson: Value, Strategy, and Integration

Research compiled 2026-03-24. 15 sources consulted across GitHub official documentation, engineering blogs, Ruby gem CI case studies, and cost analysis reports.

---

## Part 1: The True Value of CI for a Project Like Carson

### What CI actually does that local cannot

CI's singular irreplaceable value is **clean-room verification**: running code on a machine with no history, no cached state, no leftover dependencies, no developer-specific configuration. A fresh checkout, a fresh install, a fresh run.

This catches a specific class of defects that local testing structurally cannot [1, 2]:

| Defect class | Why local misses it | CI catches it |
|---|---|---|
| **Missing dependencies** | Gems installed globally or cached from a previous branch mask undeclared dependencies | Fresh `gem install` from gemspec fails immediately |
| **Uncommitted files** | The file exists on disk, so tests pass — but it was never committed | Checkout has only what git tracks |
| **Environment assumptions** | Hardcoded paths, locale settings, timezone defaults that happen to match the developer's machine | Linux runner has different defaults |
| **Case-sensitive paths** | macOS is case-insensitive; Linux CI runners are case-sensitive | `require 'Carson'` works locally, fails in CI |
| **Test ordering and state leakage** | Tests pass in a specific order because shared state accumulates | CI may run in different order or from a clean database |

For Carson specifically (a Ruby gem with 631 tests, no database, no web server), the relevant subset is: **missing dependencies, uncommitted files, and environment assumptions**. These are real but infrequent — they surface perhaps once every few dozen PRs.

### What CI does that local already does (redundantly)

Everything else in a typical CI pipeline — lint, syntax checks, naming guards, indentation checks, security scans — is **verification that the developer's local environment already performed**. For a solo developer with disciplined local tooling (pre-commit hooks, Carson's guards), this duplication adds cost without information [3].

The Boring Rails blog captures this well: keep CI "close to the code" and avoid setup overhead [4]. The Switowski analysis is more direct: "everything that takes milliseconds runs in pre-commit; everything slower runs in CI" [3]. For Carson, the lint and guard checks take milliseconds locally. They do not benefit from a clean room. Running them in CI is waste.

### The cost of that value

GitHub Pro includes 3,000 Actions minutes per month. The 2026 pricing update reduced per-minute costs by ~39% for GitHub-hosted runners, but introduced a $0.002/min platform charge [5, 6].

For a solo Ruby gem project:
- A minimal test-only CI job (checkout + setup Ruby + run tests) takes **60–90 seconds**
- A full CI suite (lint + guards + tests + smoke + governance) takes **3–5 minutes**
- At ~30 PRs/month with 2 runs each (PR + push-to-main), that is:
  - Test-only: ~60–90 minutes/month (2–3% of budget)
  - Full suite: ~180–300 minutes/month (6–10% of budget)

The full suite consumes 3–5x more minutes for information the developer already has. On an active day with many PRs (like today), the budget can be exhausted entirely.

**Cost reduction levers** [7, 8]:

| Technique | Savings | Applicability to Carson |
|---|---|---|
| Concurrency cancel-in-progress | Eliminates superseded runs | High — rapid consecutive pushes are common |
| Path filtering (skip CI for docs-only changes) | 30–70% fewer runs | Medium — Carson has docs, but most PRs touch code |
| Consolidate jobs into one | ~25% fewer billed minutes | High — one job instead of five eliminates per-job setup overhead |
| Cache Ruby setup and gems | Saves ~30s per run | Already used via `ruby/setup-ruby` bundler cache |
| Run on PR only, not push-to-main | 50% fewer runs | High — the merge already proved the code |

### Verdict: CI is a narrow safety net, not a quality gate

For a solo developer with strong local tooling, CI's value is:
1. **Clean-room test execution** — the one thing local structurally cannot do
2. **Auto-merge trigger** — the mechanical requirement for GitHub's PR workflow

Everything else is redundant with local checks. The strategy should minimise CI to these two functions.

---

## Part 2: What to Use and What Not to Use

### Use: tests in CI

Run the test suite in a clean environment. This is the core value proposition. One job, one purpose.

```yaml
name: Gate

on:
  pull_request:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  gate:
    name: Gate
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
          bundler-cache: true
      - run: gem install sqlite3 --no-document
      - run: ruby -Itest -e 'Dir.glob("test/**/*_test.rb").sort.each { |f| require File.expand_path(f) }'
```

Design choices:
- **`concurrency` with `cancel-in-progress`**: if you push twice in quick succession, the first run is killed immediately. Zero waste [9].
- **`timeout-minutes: 5`**: prevents stuck jobs from billing indefinitely. Set to ~3x average duration [7].
- **`on: pull_request` only**: no push-to-main trigger. The PR already proved the code; re-running after merge is redundant.
- **Single job**: eliminates per-job setup overhead. Consolidating from five jobs to one saves ~25% of billed minutes [7].
- **`bundler-cache: true`**: `ruby/setup-ruby` handles gem caching automatically, saving ~30 seconds per run [10].

### Do not use: lint in CI

Lint (RuboCop, syntax checks, indentation guards) belongs in local hooks exclusively. Rationale:

1. **No clean-room benefit.** Lint checks are deterministic — they produce the same result locally and remotely. The clean environment adds nothing.
2. **Immediate feedback is better.** A pre-commit hook catches the issue in seconds, before the commit. CI catches it minutes later, after the push. The pre-commit is strictly better feedback [3].
3. **Wasted minutes.** Every lint job that passes consumed runner time to tell you what your local hook already confirmed.

Carson already runs lint and guard checks locally via pre-commit and pre-push hooks. These are the correct enforcement point.

### Do not use: naming guards and path privacy guards in CI

Same reasoning as lint. These are deterministic, local-only checks. They do not benefit from a clean room. Carson's hooks enforce them.

### Do not use: governance and review gates in CI

Carson's `audit` and `review gate` commands are governance checks that inspect PR state via the GitHub API. They can run from anywhere — the CI runner has no special advantage. Running them in CI adds a job that waits for API responses, consuming minutes.

Better approach: run governance checks locally as part of `carson deliver`, or as a separate lightweight action that does not require Ruby setup.

### Do not use: smoke tests in CI (for now)

Carson's smoke tests (`ci_smoke.sh`) exercise the CLI end-to-end. These are valuable but expensive — they require full repo setup, Ruby installation, and multiple Carson commands. For a solo developer, running smoke tests locally before delivery provides the same assurance without the CI cost.

Consider re-enabling smoke tests in CI only when:
- Multiple contributors are involved (cannot trust everyone's local setup)
- The test suite grows to include integration tests that require services (databases, APIs)

### Consider: path filtering for documentation

If many PRs touch only documentation (README, MANUAL, RELEASE, docs/), adding `paths-ignore` prevents unnecessary CI runs [11]:

```yaml
on:
  pull_request:
    paths-ignore:
      - '**.md'
      - 'docs/**'
      - 'RELEASE.md'
      - 'MANUAL.md'
      - 'API.md'
```

**Caveat**: path filtering interacts poorly with required status checks. If a docs-only PR skips the Gate job, GitHub considers the check "pending" (not passed), blocking merge. The workaround is a second lightweight job that runs when only docs change [11]. This adds complexity — evaluate whether it is worth it based on the ratio of docs-only to code PRs.

---

## Part 3: How Carson Can Benefit From and Work With GitHub CI

### Current friction

Carson's `deliver` command gates on CI checks. The courier (`Courier`) pushes to remote, creates a PR, then polls GitHub for check status up to `MAX_CHECKS_AT_BUREAU` times with 30-second intervals. When CI is slow, broken, or rate-limited, delivery stalls.

This coupling means:
- **CI failure = delivery failure**, even for infrastructure problems unrelated to the code
- **CI latency = delivery latency**, adding minutes of waiting to every delivery
- **CI budget exhaustion = complete workflow halt**, as experienced today

### Strategy: decouple verification from delivery mechanism

Carson should distinguish between **verification** (proving the code works) and **delivery mechanism** (getting the code to main). Today, verification is delegated to CI. But Carson already performs local verification — tests, lint, guards, audit. CI re-runs a subset of this remotely.

The recommended architecture separates two modes that Carson already plans to support:

**Local-centred mode (future):**
- Carson runs all verification locally before delivery
- CI is optional monitoring, not a gate
- `deliver` pushes, creates PR, and merges immediately
- Fastest feedback, lowest cost, suitable for solo developers

**Remote-centred mode (current):**
- CI runs tests in a clean room
- `deliver` waits for CI to pass before merging
- Auto-merge is triggered by the Gate check passing
- Suitable for teams or when clean-room assurance is required

### Practical integration improvements

**1. Resilience to CI failure.**
Carson's courier should distinguish between:
- **Test failure** (code problem — block merge, report to developer)
- **Infrastructure failure** (runner unavailable, billing issue — report but offer bypass)

The courier currently treats all CI failures the same. A runner allocation failure should not block delivery the same way a test failure does.

**2. Minimal required check.**
Use a single required check named `Gate`. This is both the job name and the branch protection check. One check, one job, one workflow. No matrix of required checks to maintain.

**3. Timeout and cost awareness.**
Carson could track cumulative CI minutes per month (via the GitHub API billing endpoint) and warn when approaching the budget. This prevents surprise exhaustion.

**4. Local bypass with audit trail.**
When CI is unavailable, Carson could offer a `--local-verified` flag that:
- Runs the full test suite locally
- Records the SHA, test output, and timestamp
- Merges without waiting for CI
- Logs the bypass in the PR description for audit

This preserves the remote-centred default while providing a safe escape valve.

---

## Key Takeaways

1. **CI's true value for Carson is clean-room test execution.** Everything else is redundant with local tooling.
2. **One job, one purpose.** Run tests. That is all. Lint, guards, governance, and smoke tests belong locally.
3. **Use concurrency cancellation and timeouts.** These are free optimisations that prevent waste.
4. **Budget awareness matters.** 3,000 minutes/month is generous until it is not. A full five-job suite on an active day can exhaust it.
5. **Carson should be resilient to CI failure.** Infrastructure failures should not block delivery.
6. **The Gate pattern works.** One required check, one job, simple branch protection. Easy to understand, easy to maintain.

---

## Sources

| # | Source | URL |
|---|--------|-----|
| 1 | Panto — Why Do Tests Pass Locally but Fail in CI? | https://www.getpanto.ai/blog/why-do-tests-pass-locally-but-fail-in-ci |
| 2 | Feldera — The Pain That Is GitHub Actions | https://www.feldera.com/blog/the-pain-that-is-github-actions |
| 3 | Switowski — Pre-commit vs CI | https://switowski.com/blog/pre-commit-vs-ci/ |
| 4 | Boring Rails — Building a Rails CI Pipeline with GitHub Actions | https://boringrails.com/articles/building-a-rails-ci-pipeline-with-github-actions/ |
| 5 | GitHub — Pricing Changes for GitHub Actions (2026) | https://github.com/resources/insights/2026-pricing-changes-for-github-actions |
| 6 | GitHub Blog — Update to GitHub Actions Pricing | https://github.blog/changelog/2025-12-16-coming-soon-simpler-pricing-and-a-better-experience-for-github-actions/ |
| 7 | Blacksmith — How to Reduce Spend in GitHub Actions | https://www.blacksmith.sh/blog/how-to-reduce-spend-in-github-actions |
| 8 | WarpBuild — Reducing GitHub Actions Costs | https://www.warpbuild.com/blog/github-actions-cost-reduction |
| 9 | GitHub Docs — Control Workflow Concurrency | https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency |
| 10 | ruby/setup-ruby — GitHub Action for Ruby | https://github.com/ruby/setup-ruby |
| 11 | Pantsbuild — Skipping GitHub Actions Jobs While Keeping Branch Protection | https://blog.pantsbuild.org/skipping-github-actions-jobs-without-breaking-branch-protection/ |
| 12 | The Rubyist — Moving a Ruby Gem's CI to GitHub Actions | https://therubyist.org/2025/02/19/moving-a-ruby-gem-ci-to-github-actions/ |
| 13 | DEV Community — Ship Safer Code: GitHub Actions Patterns That Actually Matter | https://dev.to/prabhu_ponnambalam_67867a/ship-safer-code-the-github-actions-patterns-that-actually-matter-1omd |
| 14 | GitHub — Well-Architected Anti-Patterns | https://wellarchitected.github.com/library/scenarios/anti-patterns/ |
| 15 | Martin Fowler — YAGNI | https://martinfowler.com/bliki/Yagni.html |
