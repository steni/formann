---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (GLOSSARY.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
---

<what-to-do>

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.
If you can answer it yourself by reasoning — one correct solution, no real trade-off —
state the answer declaratively as part of the design instead of asking. Only real forks
become questions: defensible options on both sides, where the choice depends on the
user's preference or knowledge you don't have.

</what-to-do>

<supporting-info>

## Domain awareness

During codebase exploration, also look for existing documentation:

### File structure

The repo has a `GLOSSARY.md` at the root and ADRs in `docs/adr/`.

Create files lazily — only when you have something to write. If no `GLOSSARY.md` exists, create one when the first term is resolved. If no `docs/adr/` exists, create it when the first ADR is needed.

## During the session

### Challenge against the glossary

When the user uses a term that conflicts with the existing language in `GLOSSARY.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update GLOSSARY.md inline

When a term is resolved, update `GLOSSARY.md` right there. Don't batch these up — capture them as they happen. Use the format in `${CLAUDE_SKILL_DIR}/GLOSSARY-FORMAT.md`.

Don't couple `GLOSSARY.md` to implementation details. Only include terms that are meaningful to domain experts.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in `${CLAUDE_SKILL_DIR}/ADR-FORMAT.md`.

### Ask whether it may merge itself

Before the tree is walked, ask this as one of its branches: **may this feature be merged without a person once its branch review is clean?** It is the maintainer's **Auto-merge opt-in** (ADR-0015), and it is decided now, while the risk is known, not after the work is built. Frame it as "what does it touch?": payments, auth, user data, the runner or its reviewers, CI, anything a person should see before it ships all argue no. Give your recommendation from what the grilling has shown the feature touches. A yes is not a release — releasing stays where it is — and the maintainer can revoke it later. Record the answer (yes, no) for the closing summary; do not grant anything here — `/to-prd` does that once the feature's parent exists.

## When the tree is walked

Stop. Say in a few lines what was decided — including the auto-merge answer (`auto-merge: yes` or `auto-merge: no`) — and which glossary entries and ADRs were written, then name the next step: `/to-prd` for a feature, or a standalone issue for a small, well-scoped task. Do not slice the work into issues or write them by hand — packaging is `/to-prd` and `/to-issues`' job, and asking "one issue or three?" here skips the module design those steps exist for. The glossary and ADR edits stay uncommitted in the working tree; `/to-prd` carries them onto the feature branch.

</supporting-info>
