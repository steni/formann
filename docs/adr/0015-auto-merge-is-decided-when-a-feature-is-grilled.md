---
status: accepted
---

# Auto-merge is decided when a feature is grilled, and the branch can only take it away

Whether a feature may reach the default branch without a person pressing merge depends on what it touches (payments,
auth, data, the runner itself), and that is known when the feature is specified, not after it is built: asked after
implementation, the maintainer would approve what was put in front of them, the failure ADR-0084 (omumu) records for
the Manual. We decided that a feature is **auto-mergeable** only when the maintainer opts it in during grilling or
`/to-prd`; every other feature's Proof waits for a person. There is no cooling-off window: the maintainer's veto is the
decision not to opt in, and at runtime the branch can only take auto-merge away, never grant it. An opted-in feature's
Proof is merged by the **Runner identity**, on the exact sha that was reviewed, when all of these hold, and otherwise
waits for a person with a Note saying which did not:

1. The default branch requires the consumer's PR checks, and they passed on that sha.
2. The Proof is ready: the branch review converged, every re-judged claim is shown, and the head has not moved since.
3. The feature has no HITL issue.
4. The branch changes no protected path: anything that judges a **Dispatch** or runs on the host (the reviewer and
   skill files, `runner/`, `docs/formann/`, CI configuration, whatever a **Post-drain command** executes), plus the
   paths the **Consumer** declares never auto-mergeable.
5. The consumer has a track record: its escape measure, over Proofs merged by hand, is above the bar it set before
   switching auto-merge on.

Releasing is untouched: a consumer's release gate stays where it is, and an auto-merged feature is released like any
other.

The opt-in is an **Auto-merge opt-in**, a ref on the **Shared remote** (`refs/formann/auto-merge/<feature>`) that the
maintainer's interactive session pushes during grilling or `/to-prd`, with a Note on the feature issue saying so for
people. The sandbox's token cannot push (ADR-0014), so no **Dispatch** can opt its own feature in; deleting the ref
revokes it.

## Considered options

- **A tracker label** (`formann:auto-merge`). Rejected: the sandbox may write issues, so a **Dispatch** could label
  its own feature; trusting the label only when a maintainer applied it needs an actor check every **Binding** gets
  right, and local-markdown frontmatter has no actor.
- **A line in the PRD.** Rejected for the same reason: the PRD is tracker content.
- **Decide after implementation, on the Proof.** Rejected: the person deciding is reading what the runner produced,
  and approves it; the risk of a feature is a property of its intent.
- **A cooling-off window** (merge N hours after the ready Proof unless vetoed). Rejected: the veto belongs to grilling,
  and a window only delays the features the maintainer already said could go.
- **GitHub's native auto-merge on every ready Proof.** Rejected: no opt-in, so every feature could ship itself.

## Consequences

- Protected paths make the grilling decision safe against a branch that strays past its spec: an opted-in feature
  whose implementer touched checkout code waits for a person, and says why.
- Without protected judging paths, auto-merge would let a **Dispatch** rewrite its own judges and the host code the
  **Judges checkout** supplies, one merge later (ADR-0012).
