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

## Documentation UX intent
- README is first-read orientation for new users.
- Manual focuses on practical operation and troubleshooting.
- API reference defines contract-level behaviour (commands, exits, configuration).
- Internal `/docs` content remains implementation-facing and is not part of first-run user onboarding.

## Brand language
- Tone: precise, operational, and credible.
- Claims: factual and verifiable; avoid hype language.
- Positioning: Carson is governance runtime support for GitHub workflows, not a GitHub replacement.

## UX quality checks
- Every blocking output includes a clear remediation path.
- Core workflows (`init`, `audit`, `review gate`) can be understood without internal implementation knowledge.
- Documentation links lead users from orientation to operation in one step.
