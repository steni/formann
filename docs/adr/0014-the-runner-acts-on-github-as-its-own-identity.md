---
status: accepted
---

# The runner acts on GitHub as its own identity, with one narrow token per side

The github-issues binding gave the sandbox the maintainer's `repo`-scope token, and the host pushed and would open the
Proof with the maintainer's credentials. That has three costs. The sandbox could push and open or merge pull requests
itself, so ADR-0012's "only the push and the pull request on the host" protected nothing. GitHub never notifies a
person of their own activity, so a Note on the feature issue and a newly opened Proof reached the maintainer in
silence. And a pull request the maintainer authored is one the maintainer cannot approve, so a required review could
never be satisfied. We decided that the **Runner** writes to GitHub as a **Runner identity** of its own (a GitHub App,
or a machine user where an App is not possible), with two tokens: the sandbox's may write issues and read contents and
nothing more; the host's may also push and write pull requests. The maintainer is then told the way GitHub tells
anyone (a mention in the Note, a review request on the Proof) and can approve what the runner opened.

## Considered options

- **Keep the maintainer's token and add a notify hook** (a consumer command wired to ntfy, email or Slack). Rejected:
  the token stays broad and the maintainer still cannot approve the Proof. A hook stays possible for a **Consumer**
  not on GitHub; it is not what a GitHub consumer relies on.

## Consequences

- An App is preferred because its installation tokens are minted per use, with exactly the permissions asked for, and
  expire within the hour; the host holds the App's private key, the sandbox only ever a minted token.
- The push is the **Runner identity**'s too, so "the last pusher may not approve" protection rules see the runner,
  not the maintainer, as the pusher.
- The github-issues binding's `sandbox-env` mints or reads the **Runner identity**'s sandbox token instead of the
  maintainer's; a consumer without a **Runner identity** keeps today's behaviour, and the binding says plainly that the
  sandbox can then push.
