---
status: accepted
---

# Post-drain progress is a mark on the shared remote, and the phase restarts rather than resumes

The **Post-drain phase** ran only when the pass had just dispatched on the feature, or when the same machine held a
local Blocked marker. A runner restarted after a feature's last issue went `done` (#32), or a second machine, saw
nothing to do, so a branch pushed with no pull request looked exactly like a finished one. We decided that the phase's
progress is a **Post-drain mark** on the **Shared remote**: a ref at the feature tip the phase last finished `ok` for,
and one at the tip it last failed on. The phase is due whenever every issue of the feature is `done` or `wontfix` and neither mark is at its
tip, on whichever machine holds the **Claim**. It always starts from the top at the current tip, and its steps are
idempotent by contract (fix commits already on the tip, filings deduplicated, the pull request created or updated by
its branch), so a half-done end completes on the next pass and nothing resumes from one machine's run folder.

## Considered options

- **Ask the consumer** (a `--due` mode on the post-drain command, e.g. "does the open Proof name this tip?").
  Rejected: every consumer reimplements the check, and one without a Proof has nothing to ask.
- **Tracker state** (a label or comment on the feature issue). Rejected for the reason ADR-0011 gives for the
  **Claim**: not atomic, and different under every **Binding**. A Note on the feature issue still tells the
  maintainer when the phase fails; it is information, not the record.
- **Resume from the run folder** (skip reads and rounds an earlier attempt finished). Rejected: the folder is on one
  machine, and restarting at the tip already carries the earlier attempt's commits.

## Consequences

- A new commit on the feature (the maintainer's fix, a reworked issue) moves the tip off both marks, so the phase
  re-runs by itself; deleting the failed mark retries a failure without a new commit.
- A restart gives a consumer's loop its full round budget again; the three-**Blocked**-passes rule bounds that.
