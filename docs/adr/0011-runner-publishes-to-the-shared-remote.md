---
status: accepted
---

# The runner publishes to the shared remote, from the host, and claims features there

ADR-0007 rejected "runner pushes through `origin`" because it widened the sandbox's credentials and made runner work public whether or not that was wanted. With runners on more than one machine, a commit that stays on one machine's **Parking ref** is invisible to every other machine and to any service that builds by ref, so we reverse that one option: after every **Dispatch**, the host side of the **Runner** (never the sandbox) fast-forwards the commit onto the **Shared remote**'s feature branch before the **Post-implement phase** runs, and a refused fast-forward leaves the work parked and stops the drain on that feature until the maintainer reconciles. Coordination between machines lives in the same place: a **Claim** is a ref on the **Shared remote**, taken with an atomic push, because git gives compare-and-swap for free under every tracker **Binding**, and a tracker label does not.

## Considered options

- **Push to a runner namespace on the remote (`runner/<feature>`), leave `<feature>` to the maintainer.** Rejected: two branches per feature on the remote, and every consumer of the work (the next runner, a Preview service, the PR) has to know which one to read.
- **Claim as a tracker verb (label, assignee, frontmatter).** Rejected as the lock: not atomic on GitHub, and every **Binding** would have to get a race right. A tracker comment may announce a **Claim**, as information.

## Consequences

- ADR-0007's credential objection stays satisfied: the push uses host credentials the sandbox never sees. Its visibility objection is accepted: runner work is on the remote as soon as it is committed.
- A **Consumer** without a **Shared remote** keeps ADR-0007's one-machine behaviour unchanged.
- A consumer's post-implement step may rely on the dispatch's commit being fetchable by ref from the **Shared remote**.
