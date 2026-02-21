# Butler Evolution Plan

## Insights learned for Butler

Here is a fuller distillation, with short key quotes for context.

1. ==Butler should optimise for unattended throughput, not just assisted coding.==  
Stripe’s results suggest the value is not only “better code suggestions”, but ==parallel delivery capacity==. Stripe reports about 1,300 minion-produced PRs merged per week, human-reviewed.  
Quote (Stripe Part 1): “if it’s good for humans, it’s good for LLMs, too.”  
Butler implication: ==treat unattended PR production as a first-class product surface, with human review as governance, not as execution.==

2. ==The winning architecture is hybrid: deterministic workflow + agentic reasoning.==  
The most practical lesson from Stripe is not “let the model decide everything”. They constrain predictable steps in code (linters, push, CI handoff) and reserve the model for ambiguous work.  
“putting LLMs into contained boxes”  
Butler implication: implement blueprint/state-machine execution where each node is explicitly either deterministic or agentic, with clear transitions and stop conditions.

3. ==Context quality beats model cleverness in large codebases.==  
Stripe’s approach is scoped rules + selective dynamic context, not giant global prompts. They prioritise subdirectory/file-pattern rules, and they hydrate links/docs/tickets before the run starts.  
“smaller box”  
Butler implication: build context assembly as a system capability:
rule resolution, pre-run context hydration, and strict tool/context budgeting per task.

4. Tool abundance hurts; tool curation helps.  
A central tool plane (MCP) is useful only if each run sees a curated subset. Too many tools increases confusion, latency, and failure surface.  
Butler implication: create “tool packs” by task class (bugfix, migration, flaky test, docs, refactor) and default to least privilege. Allow controlled opt-in expansion.

5. Cost and reliability improve when feedback is shifted left and CI loops are capped.  
Stripe’s ==principle is to run cheap local checks first, then at most limited CI retries. This is an engineering economics decision as much as a quality decision.==  
“often one, at most two, CI runs”  
Butler implication: ==add a pre-CI deterministic gauntlet (format/lint/static checks/small targeted tests), then cap full CI fix attempts by policy.==

6. Harness engineering is the key to sustained improvement, not prompt tinkering.  
OpenAI’s harness article is the clearest statement of this: ==progress compounds when the evaluation harness is realistic, stable, and tied to user outcomes.==  
Quote (OpenAI): “The quality of your optimization depends directly on the quality of your harness.”  
Quote (OpenAI): “The harness is where all your work compounds.”  
Butler implication: prioritise harnesses per workflow (bugfix, refactor, incident follow-up, flaky-test repair), with explicit graders and acceptance criteria before tuning prompts/models.

7. Butler’s UX should start where developers already collaborate.  
Stripe repeatedly emphasises low-friction entrypoints (chat thread, ticket, docs UI) and transparent run traces. This is a major adoption lever.  
Butler implication: launch from collaboration surfaces, auto-capture context links, and show an explicit execution timeline:
intent, context used, commands, checks, failures, retries, final diff rationale.

8. Engineer value shifts from typing code to framing and judgement.  
The Boris Cherny interview aligns with Stripe/OpenAI: as coding becomes cheaper, leverage moves to problem framing, constraints, and decision quality.  
“The software engineer of the future won’t be writing code. They’ll be deciding what to build and why.”  
Butler implication: strengthen the pre-execution brief:
problem statement, non-goals, safety constraints, acceptance tests, and rollback expectations.

9. For Butler, “trust UX” is as important as raw capability.  
Users will only delegate high-leverage tasks when they can inspect why Butler acted, what evidence it used, and where uncertainty remains.  
Butler implication: every run should output:
scope understood, assumptions made, confidence by subsystem, unresolved risks, and reviewer checklist.

10. Strategic positioning: Butler should be the orchestration and assurance layer.  
Many teams can call models. Fewer can turn model output into enterprise-safe, auditable, repeatable software delivery.  
Butler implication: differentiate on orchestration, safety controls, harness/eval quality, and governance-ready output, rather than on “best prompt” alone.

Sources:
- [Stripe Minions Part 1 (9 February 2026)](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents)
- [Stripe Minions Part 2 (19 February 2026)](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)
- [OpenAI: Harness engineering (14 July 2025)](https://openai.com/index/harness-engineering/)
- [Video](https://youtu.be/We7BZVKbCVw?si=5NCdWIYcWGwAstKP)
- [Transcript page used for quoting context](https://youtubetranscript.com/?v=We7BZVKbCVw)



## Butler Maturity Model (`M0`→`M4`)

Balanced reliability, Butler-core-first, phase-based (no timeboxing)

### Summary
Scope and branch mapping: Butler capability/value/UX maturity planning, mapped to `main` (planning only, no code changes in this turn).

This plan evolves Butler from a strong ==outsider governance runtime== into a ==reliability-first hybrid delivery system==, while preserving existing policy and merge-readiness guarantees.

### Context Quotes Driving the Plan

- Stripe Part 1: “if it’s good for humans, it’s good for LLMs, too.”
- Stripe Part 2: “putting LLMs into contained boxes”
- Stripe Part 1: “often one, at most two, CI runs”
- OpenAI Harness Engineering: “The quality of your optimization depends directly on the quality of your harness.”

### Maturity Levels and Promotion Gates

| Level          | Definition                                                   | Capability Outcome                                           | Value Outcome                                                | UX Outcome                                                   | Promotion Gate (must pass)                                   |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `M0` (current) | Outsider governance runtime with hooks, audit, review gate, sweep | Deterministic governance and PR-readiness controls           | Reduces policy drift and unsafe merges                       | Clear policy blocking and governance feedback                | Baseline documented from current commands and reports        |
| `M1`           | Instrumented governance foundation                           | Run telemetry, failure taxonomy, decision trace for `audit/gate/sweep` | Identifies highest-friction failure modes and false blocks   | Users see why a run failed and what to do next               | `>=95%` run event completeness, `0` exit-code contract regressions, false-positive block rate measured |
| `M2`           | Deterministic reliability loop                               | Pre-CI deterministic checks, bounded remediation loop, structured fix guidance | Higher first-pass success, lower wasted CI cycles            | Less back-and-forth, clearer next action per failure         | First-pass required-check pass rate improves by `>=20%` vs `M1` baseline; median time-to-green improves by `>=15%` |
| `M3`           | Controlled agentic pilot inside Butler core                  | One narrow unattended agent node class (for example flaky-test remediation drafts) with strict guardrails | Adds limited autonomous throughput without destabilising governance | Human reviewers receive PR-ready drafts with rationale and risk notes | `0` high-severity policy/security escapes; accepted-draft rate `>=35%` on pilot tasks; manual rollback path proven |
| `M4`           | Scaled hybrid autonomy with assurance                        | Blueprint-style orchestration combining deterministic and agentic nodes across task classes | Material throughput gains with bounded risk and auditable controls | “Request to review-ready” feels one flow, with trust signals at each stage | Throughput uplift `>=2x` on in-scope task classes; governance breach rate no worse than `M2`; auditability complete |

### Phase Plan (No Timeline)

| Phase   | Scope                          | Deliverables                                                 | Exit Criteria                                                |
| ------- | ------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| Phase 1 | `M1` foundation                | Event schema for Butler runs, failure taxonomy, baseline KPI dashboard, traceable decision logs in existing report outputs | Complete baseline for pass/fail/time/rework metrics and reliable instrumentation |
| Phase 2 | `M2` deterministic reliability | Deterministic pre-CI loop, bounded retry policy, structured remediation outputs, reliability-focused UX messaging | Measured reliability and cycle-time gains with no governance regression |
| Phase 3 | `M3` controlled autonomy       | Narrow agentic pilot node integrated with existing gates, strict sandbox/tool constraints, reviewer-facing confidence/risk summary | Pilot acceptance and safety thresholds met; explicit go/no-go decision for wider rollout |
| Phase 4 | `M4` scaled hybrid system      | Multi-node blueprint orchestration, policy-aware context assembly, expanded task-class coverage, trust and audit UX | Target throughput and trust gates met without weakening governance guarantees |

### Architecture and Data Flow (Decision-Complete)

1. Keep Butler’s outsider governance model as the control plane.
2. ==Add observability to every run path (`local`, `audit`, `review`)== before expanding autonomy.
3. Route remediation through deterministic checks first; escalate to agentic logic only in scoped phases.
4. Enforce bounded loops: one local remediation cycle, then capped CI retries.
5. Persist run evidence as structured records linked to PR number, commit SHA, and check state.
6. Add confidence and risk annotations to user-facing output before autonomous suggestions are accepted.
7. ==Keep human review mandatory for merge across all phases.==
8. Promote phases only via gate metrics, never by feature-completion alone.

### Public APIs / Interfaces / Types
No breaking public interface changes are included in this plan.
No new top-level CLI command names are introduced in this plan phase.
Existing command surfaces remain primary: `butler audit`, `butler review gate`, `butler review sweep`, and existing governance hooks/workflows.
If any new public CLI/API name becomes necessary during implementation, that naming decision is deferred for explicit confirmation.

### Test Cases and Scenarios
1. Governance correctness: forbidden artefact detection, branch protection checks, required-check parsing, and review gate outcomes remain deterministic.
2. Observability integrity: every run emits a complete, parseable trace with stable identifiers and exit-status mapping.
3. Reliability-loop behaviour: deterministic remediation runs before CI escalation; capped retries are enforced.
4. False-positive containment: blocked states are sampled and reviewed; thresholds are tracked and alarmed.
5. Failure resilience: missing PR, missing checks, flaky checks, API timeouts, and partial GitHub data all produce actionable outputs.
6. Pilot safety (`M3`): agentic nodes cannot bypass deterministic policy checks; unsafe actions are denied and logged.
7. Rollback proof: each phase includes a validated rollback path in CI smoke workflows.

### Monitoring and KPI Pack
1. Throughput: in-scope tasks completed, review-ready artefact count, merged PR count for pilot classes.
2. Reliability: first-pass required-check pass rate, false-positive block rate, governance breach count.
3. Efficiency: median time-to-green, CI rerun count per change, human rework rate after Butler output.
4. Trust UX: proportion of runs with complete rationale, reviewer override rate, user-reported clarity score.

### Explicit Assumptions and Defaults
1. Primary objective: balanced reliability.
2. Rollout scope: Butler core first, then controlled agentic expansion.
3. Governance posture: human review remains mandatory at every maturity level in this roadmap.
4. Existing Butler architecture and outsider boundary remain non-negotiable.
5. Baseline evidence references existing Butler guides and contracts in:
`docs/butler_tech_guide.md`, `docs/butler_user_guide.md`, `README.md`.
