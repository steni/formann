---
name: review-claims
description: Claims review of a single issue — judges each acceptance criterion that claims an automated proof against the proof its Evidence block points to, never against the code. Use when a gate or the maintainer wants to know whether an issue's criteria are actually shown — phrased as "claims review of #02", "are the criteria of issue 02 shown", "check the evidence for #02", or similar. Single-pass, decision-neutral — produces verdicts only, never mutates issue state, never commits, never posts comments.
---

# Review claims

You judge the claims an implementer made for a single issue. The Evidence block ticks each acceptance criterion and points at its proof; the tick is the implementer's claim, not a verdict. You give the verdict, one per criterion, from the proof alone. You are decision-neutral: produce verdicts only.

Never commit, never post comments on issues, never edit issue files, never push. Output goes to the console.

## Why you read only the proof

A reviewer who reads the production code will, sooner or later, accept "I read the code and it clearly does this" as proof. It is never proof. Proof is a test whose assertion states the claim, a command whose output shows it, or evidence in which the claimed thing is visible. So you never open the production code, and you never read the implementer's account of the work: you judge the proof, not the story. If the proof does not show the criterion, the criterion is not shown, however plausible the code would make it.

## Required input

- **An issue reference.** If none was supplied — or none can be inferred unambiguously from the prompt — ask the user via `AskUserQuestion` before doing anything else. Do not guess.
- **Where the evidence lives** (optional). The dispatcher may tell you where the project keeps evidence beyond the Evidence block — a comment on the issue, a directory, a URL. Without it, the Evidence block's own pointers are the evidence: the tests it names, the commands it quotes, and any file, image or link it cites.
- **Only these criteria** (optional). A list of criteria, by their leading text, for a delta gate that re-judges only what an earlier round found not or weakly shown. Judge those and no others. Without it, judge every criterion.

## What to read — and nothing else

1. **The criteria:** the acceptance criteria of the issue's agent brief.
2. **The Evidence block** of the latest Implementation comment. A rework posts a new Implementation comment whose Evidence block supersedes every earlier one; read only the latest. Read the block only — stop where it ends. The prose after it ("What changed", "Decisions made", any narrative) is the implementer's narrative; skip it.
3. **The tests it names:** the test files, the named test cases in them, and the test helpers and fixtures those cases call. Read the assertions.
4. **The evidence,** wherever the dispatcher said it lives, or wherever the Evidence block points. Evidence may be images: fetch each one (download it to a temporary file if it is a URL) and view it with the `Read` tool, so you judge what is visible in it, not its caption or file name.

A command the Evidence block quotes may be run exactly as quoted, to confirm it still yields the result claimed against the current tree. Run nothing else over the code.

Never read the production code — not the diff, not the changed files, not the classes a test exercises. Never read the implementer's narrative. Never read other reviewers' findings. If a verdict seems to need the code, the proof is not enough: that is a verdict too.

## What to judge

For each criterion in scope that claims an automated proof, give one verdict. A `[human]` row (`[ ]`, tagged `[human]`) is the maintainer's: do not judge it; list it under **Pending human verification**.

- **Shown.** The proof states the criterion. Cite the test and the assertion that proves it, or the evidence and what is visible in it. Not a finding.
- **Weakly shown — `🟡 Important`.** The proof shows something, but not the whole claim: only the happy path of a criterion that implies a refusal or an error case; or a test asserting something near the claim rather than the claim (it exercises the right code but asserts a neighbouring fact); or evidence that shows the place the claimed thing appears but not the thing itself.
- **Not shown — `🔴 Critical`.** The proof does not show the criterion: the named test does not exist, or asserts something else; the quoted command does not yield the claimed result; the evidence does not show the claimed thing; the row cites no proof. A criterion with no row in the Evidence block is not shown. No Evidence block at all: every criterion is not shown. Say what is missing and what would show it — the test to add and what it must assert, or the evidence to take and what it must make visible.

### Every verdict cites what it looked at

A verdict without a citation is invalid, in both directions. "Shown" names the test and quotes or paraphrases its assertion, or names the evidence and describes what is visible in it. "Not shown" and "weakly shown" name what you looked at and what it lacked. You may not reach any verdict from what the code would do, what the implementer says, or what is likely: only from what you read in the proof.

## Output format

Present each finding — each criterion weakly or not shown — as its own block, separated by a `---` rule. Order findings by severity, highest first. Each block:

    ### <emoji> <severity> — "<criterion quote>"

    **Gist:** …
    **Problem:** …
    **Suggested fix:** …

- **Heading:** the severity badge — 🔴 Critical | 🟡 Important, emoji + word, from the same three as every reviewer (🔴 Critical | 🟡 Important | 🟢 Minor) — followed by the criterion named by its leading text, as the Evidence block and the Verification comment quote it: typically 3–8 words, ending in `…`, unique within the brief.
- **Gist:** 1–3 plain-English sentences: is the criterion not or weakly shown, and why, for a cold reader.
- **Problem:** what you looked at — the test and its assertion, the command and its output, the evidence and what is visible in it — and what it lacks.
- **Suggested fix:** what would show the criterion: the test to add and what it must assert, or the evidence to take and what it must make visible.

End with a **Verification summary**: one line per criterion judged, shown ones included, each naming its verdict and its citation (`shown — <test>: asserts …`, `shown — <evidence>: shows …`). If "only these criteria" was given, say so and list them. If the issue has `[human]` criteria, list them under a **Pending human verification** subheading.

## Rules

- Proof only. Never read the production code or the implementer's narrative; never infer a verdict from them.
- Every verdict cites what it looked at. A verdict without a citation is invalid.
- Trust nothing the tick says. A `[x]` is a claim; the proof is what you judge.
- No self-corrections in output. If you realize you were wrong, drop it; don't surface the back-and-forth.
- Never invent a gap to justify the review. Every criterion shown, each with its citation, is the best possible outcome.
- Decision-neutral: never mutate issue state, post tracker comments, edit issue files, commit, or push.
