---
status: accepted
---

# After a drain, agents run only in the sandbox; the consumer's loop runs on the host and borrows it

The **Post-drain phase** ran a `.md` entry as `claude -p` on the host, in the maintainer's repo, and omumu's Branch
review (`scripts/branch-review`) runs its reviewer and fix passes as `claude --dangerously-skip-permissions` on the
host too. Run unattended by the **Runner**, both would be unsandboxed agents on a person's machine with their
credentials (#30). We decided that **no agent runs on the host after a drain**: a `.md` post-drain entry is a
**Feature dispatch** in the sandbox, and anything else is a **Post-drain command**, deterministic consumer code read
from the **Judges checkout** that starts each agent turn it needs as a **Feature dispatch**. The branch-review loop
(reads, verdicts, fix rounds, filing, the Proof) stays the **Consumer**'s code; Formann supplies the sandbox and the
propagation, and the host does only what needs host credentials: the push and the pull request.

## Considered options

- **Formann owns the branch review** (verdict classifier, pre-existing filer and round loop ported from omumu, run as
  unrolled post-drain **Feature dispatch**es in the style of ADR-0009). Deferred, not rejected: with one consumer it
  would turn omumu's choices (three reviewers, bar `minor`, three rounds, the Proof's sections) into Formann
  defaults. Revisit when a second **Consumer** wants a branch review.
- **One framework `branch-review.md` prompt running the whole loop in one Dispatch.** Rejected: the transport and
  window retries refuse to retry once HEAD has moved, so a fault after the first fix commit aborts the step and the
  Proof is never written; omumu's guarantee that a Proof is always written lives in deterministic, tested code that a
  prompt would replace with prose.
- **A Preview role and a Forge role, with consumer-owned bindings.** Rejected for now after a red-team (Codex,
  Antigravity, Claude): omumu is the only consumer with a UI, so its pages grammar and seed users would become the
  contract; choosing pages needs an agent, not a verb; the Preview scripts write the tracker's and GitHub's comments
  themselves; and a binding folder in the consumer's tree is code a slug branch can rewrite before the gate runs it.
  "Notify only" needs no Forge binding: it is a tracker *Note*.

## Consequences

- A **Post-drain command** treats the feature as data. Code it executes comes from the **Judges checkout** and the
  **Runner's Formann**, never from the feature's tree: a script, module, build or package hook the feature's branch can
  change runs inside a **Feature dispatch** or not at all. The Judges checkout's fallback to the host repo (no
  **Shared remote**, first fetch failed) is not trusted for this; a privileged step without a trusted Judges checkout
  does not run.
- The boundary holds only where the host never runs `git` in a tree the sandbox can write. Today the container mounts
  the **Runner-checkout** read-write, `.git/` included, and the host runs `git status`, `checkout`, `clean` and
  `reset` there, so a Dispatch can plant `core.fsmonitor` or a hook that the host then runs (unexploited, standard git
  behaviour). That has to be closed, independently of this decision.
- The boundary holds only while the sandbox's tracker token cannot push or open pull requests. The github-issues
  binding asks for `repo` scope today.
- A **Feature dispatch** mounts the **Judges checkout**'s hook configuration (`.claude/settings.json`, `.claude/hooks/`) as well as its reviewers, for issue dispatches too: hooks judge a dispatch, so a branch must not weaken its own.
- The meaning of a `.md` post-drain entry changes from a host prompt to a **Feature dispatch**. No consumer declared
  one, so nothing migrates.
