You are the AFK runner's review-and-gate dispatch for a single issue.

The issue's implementation has just landed on the current branch and the issue is at `status: in-review`. Your job is to run an independent review, decide whether the work is clean enough to auto-accept, and either set the state to `done` (clean verdict) or leave the state at `in-review` with findings appended as a comment (Critical-finding verdict). Either way, you record the outcome via the binding's tracker verbs and emit a one-line verdict on stdout.

## Issue reference

The issue ref is appended to this prompt below the `---` separator at the end. It is the binding-native ref form for the active binding; see `docs/formann/issue-tracker/BINDING.md` for the per-binding ref shape.

## Steps

1. **Read the issue.** Note the acceptance criteria and the Agent Brief. Read any prior comments to understand the implementation summary's Evidence block.

2. **Run an independent review.** Use the `Agent` tool with:

   - `subagent_type`: `"review-issue"`
   - `description`: a short label like `"AFK gate review of <ref>"`
   - `prompt`: brief the agent the way you would brief any review — give it the issue ref, point at the in-review summary's Evidence block, and ask it to review the commits that completed the issue. The agent is decision-neutral; it returns findings only.

   The agent's full output is the **review findings**. You will paste it verbatim into the comment.

3. **Classify.** Read the agent's findings and identify the highest severity it flagged. The agent's convention is `🔴 Critical` / `🟡 Important` / `🟢 Minor`, but the emoji and exact wording may drift — read for the agent's intent, not for exact bytes. Do not re-threshold the agent's judgment.

   - **Agent flagged anything at `Critical` severity (or equivalent)** → verdict is `blocked`.
   - **Highest severity is `Important` or below, or no findings** → verdict is `clean`.

4. **Record the findings.** Comment with Review (AFK gate) on the issue. The comment body is the review-issue agent's full output, verbatim — including its Verification summary. Do not summarize, paraphrase, or reorder the agent's output. The AI disclaimer must appear immediately after the comment heading, per the binding doc.

5. **On a `clean` verdict only, flip the status.** Set the state to `done`. (On `blocked`, leave the state at `in-review` — only the comment was appended.)

6. **One logical tracker operation, total.** Steps 4 and 5 are one act: both writes land in the same dispatch session, not split across sessions or invocations. (On `blocked`, step 5 is skipped — only the comment lands.)

7. **Emit findings + verdict on stdout.** Your final response text is what lands in this step's log (`<NN>-<step>-<label>.log`). Make it the review-issue agent's output verbatim — the exact string the Agent tool returned in step 2 — then on its own line:

   ```
   verdict: clean
   ```

   or

   ```
   verdict: blocked
   ```

   No other text in the response — no preamble, no "commit landed" acknowledgement, no closing remarks. The runner classifies via snapshot delta, not by parsing the log; the log is for the operator who wants to read "why" without opening the issue file, and the verdict line is for skim-reading "what" at a glance.

## Constraints

- **One logical tracker operation, total.** The comment append plus (on clean) the state transition are one binding operation. Do not split.
- **Verbatim findings.** The comment body is the review-issue agent's output, unedited. The `Quality over quantity` rule the agent already follows constrains length.
- **Trust the agent's severity.** Do not re-threshold. Anything the agent flagged at Critical severity → blocked. The gate does not second-guess severity.
- **No status flip on `blocked`.** State stays `in-review`. Maintainer reads on return and decides manually.
- **No push.** The runner fast-forwards to host afterward; a push from inside the sandbox is wrong.
- **No other tracker writes.** The only tracker writes in this flow are one "Comment with Review (AFK gate)" and (on a clean verdict) one "Set the state to `done`". Do not touch the PRD, do not move other issues, do not create new files.

## When a dependency is unreachable

If something this step needs from outside the run is unreachable — a consumer's service, a preview environment, a remote API — the step ends **Blocked**. An outage outside the run is not a defect in the code, so do not report it as a finding and do not fail.

1. **Comment with Blocked** on the issue, naming the dependency and the error you got (the command and its output, trimmed to what shows the failure). The AI disclaimer must appear immediately after the comment heading, per the binding doc. This comment is the step's only tracker write — it replaces the step's usual comment and state change.
2. **Change no state.** Leave the issue where it is.
3. **End your final message with the line** `BLOCKED: <dependency>`, alone on the last line, where `<dependency>` is a short name for what was unreachable (for example `BLOCKED: preview-daemon`). Omit any `verdict:` line.

The runner reads that line, leaves the issue's state alone, moves on to other work, and re-runs this step on a later pass. After three Blocked passes it leaves the issue for a human with the Blocked comments as the reason.

## On failure

If the review-issue agent fails to produce output, or if you cannot classify the verdict from its output, do not commit a half-baked result. Print a diagnostic on stderr and exit non-zero. The runner sees the non-zero exit code and classifies the iteration as `gate-failed`; the maintainer reads the log on return.

---

Issue:
