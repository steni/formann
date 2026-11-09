# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `tracker-snapshot --any-eligible` in both bindings prints `yes` or `no`: does any active feature
  have an eligible issue? github-issues answers with one GraphQL query (plus pages); local-markdown
  from the files, including each feature's committed branch. The AFK runner asks it before every
  drain pass: on `no`, with no Blocked re-walk pending, the pass ends at once (stop reason
  `nothing-eligible`) without snapshotting or syncing any feature, so an idle runner on a large
  github-issues tracker no longer spends hundreds of API calls per quiet pass. A failed check is
  logged once and the pass walks every feature as before.
- AFK runner runs a post-drain phase: host-side steps named in an optional consumer manifest
  `runner/post-drain.md` (same format as `runner/manifest.md`; a `.md` entry is a prompt for the
  host's `claude -p`, anything else a command given the feature slug), run once a feature has
  drained and before its Claim is released — for a branch review or opening a pull request with
  host credentials. Outcomes (`ok`, `failed`, `blocked`) go into the progress line and a
  `## Post-drain` section of `SUMMARY.md`; a failed step writes the abort flag
  `post-drain-<label>`, a Blocked one is re-run on the next pass. No manifest: nothing changes.
- AFK runner keeps its own Formann checkout (`RUNNER_FORMANN_DIR`, a git clone, separate from the
  sessions' `.formann`) and fast-forwards it to `RUNNER_FORMANN_REF` (default `origin/main`) at the
  start of every run and every idle pass, re-executing itself from the updated checkout, so every
  machine runs the same Formann without anyone pulling. Local changes, divergence, an rsync copy or
  an unreachable ref refuse the drain with the reason (`preflight-abort: runner-formann`; idle pass
  `formann-refused`) before any claim is taken. The sha is recorded in the Claim and `SUMMARY.md`.
- AFK runner heart-beats its Claim between dispatches (before each `/implement` and each
  post-implement step). A claim without a heartbeat for thirty minutes (`RUNNER_CLAIM_STALE_AFTER`,
  default 1800 s, judged by each reader's own clock) is stale and is taken over with a lease push on
  its sha, so a crashed runner no longer holds a feature forever. A runner whose claim was taken over
  finishes its current dispatch, stops on the feature, and reports `taken-over-by <machine>`.
- AFK runner takes a Claim on each feature it drains — the ref `refs/formann/claims/<feature>`
  on the Shared remote, taken with a lease push that expects it absent — so two runners on two
  machines never drain the same feature. A feature another runner holds is skipped (`held-by
  <machine>` in `SUMMARY.md`) and the next one drained; the claim is released when the drain
  ends, including on interrupt. Taking a claim posts an informational `Note` on the feature's
  parent through each binding's new `comment-on-feature` script. No Shared remote: no claims.
- AFK runner publishes every dispatch's commit to the Shared remote's feature branch (from the
  host, fast-forward only) before the post-implement steps run. `RUNNER_SHARED_REMOTE` names the
  remote (default `origin`); a refused push parks the work and stops the runner on that feature.
  The `propagation` column reads `published`, `parked` or `local-only`.
- AFK runner starts a feature from the Shared remote's branch when that is ahead of the host
  branch and parking ref, or the only copy, so a feature begun on one machine continues on
  another. A feature branch the runner creates from the default branch is pushed to the Shared
  remote before the first dispatch, and both bindings' "Create a feature" push the new branch.
- AFK runner gives each consumer repo its own sandbox image and rebuilds it when
  the repo's `runner/` changes. `RUNNER_IMAGE_NAME` overrides the image name.
- AFK runner passes the output of an optional, consumer-owned `runner/sandbox-env` into every
  dispatch container, beside the binding's env. It can add variables but never replace one the
  runner or the binding sets, nor set any `ANTHROPIC_*` or `CLAUDE_CODE_*` variable.
- A post-implement step that can't reach a dependency outside the run (a consumer's service, a
  preview environment) can end Blocked: it posts a `Blocked` comment and ends with
  `BLOCKED: <dependency>`. The runner leaves the issue's state alone, writes no abort flag, shows
  `blocked (<dependency>)` and moves on. The next run re-runs the walk from the blocked step,
  without re-running `/implement`, and the third Blocked pass leaves the issue for a human. The
  pass count is read from the tracker through each binding's new `blocked-passes` script.
- AFK runner `--idle <seconds>` (drain and `--feature` modes): instead of exiting when nothing is
  left to do, the runner sleeps and starts a fresh pass, dispatching work that became ready
  meanwhile and re-running steps that ended Blocked on the previous pass. Each pass that dispatched
  anything writes `pass-<NNNN>/SUMMARY.md`; SIGINT/SIGTERM stops it cleanly. The runner README
  has launchd and systemd recipes for running it as a service.
- Module maps: a one-page structural description of an area of code (modules,
  responsibilities, primary flow, structural claims with their checks), kept as the
  `README.md` beside the code. Contract in `framework/domain.md`; term in `GLOSSARY.md`.

### Changed
- `/to-prd` presents the module table and primary flow to the maintainer as their own
  message and gets them approved before any PRD text is written; the PRD's Implementation
  Decisions open with that design.
- `/implement` reads the module maps of the areas it touches, writes a deterministic check
  for each structural claim it realises, and creates or updates the module map of each area
  whose modules changed.
- `review-issue` and `review-feature` gain a map-check: a module map that no longer
  describes the code, or a structural claim the code violates, is a finding.
- Agent briefs and issue slices name modules by their names in the PRD's module table.

### Fixed
- Runner Dockerfile template installs Node.js 22 (NodeSource `setup_22.x`) instead of 20. On Node 20,
  npm quietly installed the last Claude Code whose `engines` still allowed it (2.1.197), too old for
  Opus 5.5, so every dispatch failed with an API 400. The install layer now compares `claude
  --version` with `npm view @anthropic-ai/claude-code version` and fails the image build, naming
  both versions and the Node version, if they differ. **Migration:** the installer never overwrites
  an existing `runner/Dockerfile`, so existing consumers must refresh theirs: delete
  `runner/Dockerfile` and re-run `installer/install.sh` (or, if you have customised it, port the
  Node / Claude CLI `RUN` layer from `installer/templates/Dockerfile` by hand). The changed file
  changes the image's build-context hash, so the runner rebuilds the image on its next dispatch.
- AFK runner keeps its Claim fresh while a dispatch runs, not only between dispatches: a companion
  process heart-beats it every `RUNNER_CLAIM_HEARTBEAT_SECONDS` (default a third of the stale-after
  time, 600 s) for the life of each `/implement` or post-implement container and each post-drain
  step, so a dispatch longer than thirty minutes is no longer taken over by another runner while it
  is still being worked. The companion is stopped on every way out of the dispatch, and stops on its
  own when its runner is killed outright; a takeover it sees stops the feature after the dispatch in
  flight. Pre-flight (`claim-knobs`) refuses a heartbeat interval that is not a whole number above 0
  or not below the stale-after time.
- AFK runner no longer pushes an empty branch to the Shared remote for every feature it merely
  checks. In drain mode and on every `--idle` pass, a feature with no branch anywhere gets its
  branch created from the default branch and pushed only once its snapshot shows an eligible issue
  or a pending Blocked re-walk; a feature with nothing to dispatch is recorded `queue-empty` and
  gets no branch, local or remote. `--feature` and `--issue` still create the branch up front.
  Branches pushed by an earlier version are not deleted.
- AFK runner puts the runner-checkout's `origin` back to the host repo before every sync and logs
  the repair, so a dispatch that rewrote or removed the remote to push can no longer halt the next
  run with `preflight-abort: runner-checkout`. Every dispatch is told that the runner publishes
  its commits and that it must not push or change remotes.
- AFK dispatches can no longer end their turn waiting on a background build: background Bash is disabled in the sandbox and foreground Bash may run for up to an hour.
- AFK dispatches no longer hang waiting on a process they detached themselves (`nohup … &`): the sandbox container runs with `--init`, so a finished orphan is reaped instead of lingering as a zombie that a `kill -0` wait never sees exit.

## [0.6.0] - 2026-08-20

### Added
- AFK runner offers an opt-in `find-and-fix` step that runs `/code-review --fix` over an issue's change-set before the gate, commits the fixes, and posts a note.
- AFK runner holds a macOS wake assertion for the whole run (`caffeinate -i -s` tied to the runner pid) so an unattended host doesn't idle-sleep or timer-throttle a multi-hour run. `--no-caffeinate` skips it; non-macOS hosts log a note and continue.

### Changed
- `review-issue` reviews — and the AFK gate comments that paste them — now present findings in a fixed, severity-ordered block format, not a loose list.

### Fixed
- AFK runner no longer refuses the first run after a propagated dispatch with `snapshot-failed`; a pre-flight abort's SUMMARY.md now also lists swept parking refs.
- AFK runner no longer reports `left-for-human` on a post-implement step that isn't the walk's last; an intermediate step now reads `in-review`.
- AFK runner's usage-window and transport-backoff waits poll a wall-clock deadline instead of counting `sleep 1` iterations, so OS timer throttling or a suspend/resume can no longer strand a dispatch past the window reset while it holds the run lock (issue #80).
- AFK dispatches can no longer strand uncommitted work behind a `ScheduleWakeup` that never fires under `claude -p` — the runner removes that and the `Cron*` tools from every dispatch.

## [0.5.0] - 2026-06-12

### Added
- Maven builds inside the AFK sandbox resolve artifacts that exist only in the host's `~/.m2/repository` (mounted read-only); downloads still land in the per-feature cache volume.

### Changed
- Runner Dockerfile template installs Maven 3.9 from the Apache archive instead of Debian's apt package, and sets a UTF-8 locale.

### Fixed
- AFK runner no longer skips features created after the runner-checkout was cloned (`queue-empty`). `RUNNER_DEFAULT_BRANCH` overrides the default branch.

## [0.4.0] - 2026-06-10

### Added
- AFK runner accepts `run-the-queue.sh --model <id>` to run every dispatch on the chosen model instead of the CLI default.
- AFK runner shows a live status line in the terminal while a dispatch is running. `RUNNER_DISABLE_LIVENESS=1` disables it.

### Changed
- AFK runner saves dispatch logs split per stream (`<NN>.stdout.jsonl`, `<NN>.stderr.log`, `<NN>.summary.md`) instead of one raw capture.
- AFK runner retries transient transport faults instead of failing the dispatch; genuine request errors still fail fast. `RUNNER_TRANSPORT_RETRY_*` env knobs tune the budget and backoffs.
- AFK runner waits out an exhausted usage window and retries the dispatch instead of failing it. `RUNNER_WINDOW_RETRY_*` knobs tune the budget; `RUNNER_DISABLE_WINDOW_RETRY=1` disables it.
- Runner Dockerfile template scaffolds Eclipse Temurin JDK 25 instead of 21 and sets `TERM=dumb`. Existing consumers are unaffected — the installer never overwrites an existing `runner/Dockerfile`.

## [0.3.0] - 2026-06-04

### Added
- Installer runs each binding's optional install-time setup hook after binding selection. For the `github-issues` binding, the hook seeds the `formann:*` label namespace and prompts for the GH-token macOS Keychain entry when missing. Local-markdown ships no hook; that path is unchanged.
- `build-image.sh --fresh` rebuilds the runner image with every bundled tool — including the Claude CLI — re-resolved to its current published version, instead of reusing the versions baked into the cached image.
- `/improve-codebase-architecture` skill — finds deepening opportunities (shallow modules, leaky seams, hard-to-test interfaces) using the project's `GLOSSARY.md` and `docs/adr/`, then grills a chosen candidate toward a deeper, more testable module. Consumer-side engineering skill alongside `/grill-with-docs`.
- Customizable post-implement phase — the AFK runner's behaviour after `/implement` is now a Consumer-owned ordered list of steps in `runner/manifest.md`, composed from framework-supplied building blocks and/or your own prompts. The installer seeds a default that reproduces the prior review-and-gate behaviour; **existing consumers must re-run `installer/install.sh` once after upgrading**, or the runner refuses to start.

### Changed
- Installer prompts default to the consumer's current binding on re-install; press Enter to keep it.
- Installer suppresses the CLAUDE.md snippet banner when the consumer's root `CLAUDE.md` already contains the snippet verbatim; emits one stderr confirmation line instead.

### Fixed
- **`/implement` no longer marks an operator-attended acceptance criterion as verified** — a criterion whose check can't run in the dispatch environment (Docker-in-Docker, a credential, a manual or operator-attended step), or whose test was skipped, is now classified `[human]` and left for the maintainer instead of ticked off as done.
- **AFK runner dispatches under the github-issues binding no longer run without GitHub auth** — the binding's `GH_TOKEN`/`GH_REPO` env failed to reach the sandbox container, so every dispatch ran but aborted with `gh` unauthenticated.
- **`/triage` no longer fails on sub-issues under the github-issues binding** — Previously refused with a missing-slug error before transitioning to `ready-for-agent`.

## [0.2.0] - 2026-05-27

### Added
- The issue-tracker contract is codified in `framework/bindings/issue-tracker/CONTRACT.md`. Both `github-issues` and `local-markdown` bindings realize the same canonical 13-verb set.
- AFK runner sweeps stale parking refs and their runner-checkout source branches on startup. Both sides are only removed when git proves their tips are reachable from another host ref, so no committed work can be lost.
- `/gist` skill — produce a short plain-English summary of whatever you point it at: the previous response, the conversation, an artifact, or each item in a list. Consumer-side utility skill alongside `/handoff`.
- Sandbox container image bundles `gh` and `bats`, so agents can drive the GitHub issues binding and run framework test suites without installing them first.
- Standalone issues — a Formann feature can be a single slug-named issue with no PRD. Create one conversationally ("create a standalone for slug X about Y"), add follow-ups the same way ("add a follow-up under slug X about ..."), or open an issue in the GitHub web UI with `formann:status:needs-triage` — `/triage` assigns the slug and the rest at the `ready-for-agent` transition.
- AFK runner lazily creates `refs/heads/<slug>` from the host's default branch on first dispatch when the host has no branch for the slug, instead of skipping with `branch-missing`. `/to-prd` still creates branches eagerly for PRD-led features.

### Changed
- Runner renders dispatch durations as `Xs` / `Xm Ys` / `Xh Ym` across the mid-run progress line, the terminal stop table, and SUMMARY.md. On-disk records still use integer seconds.
- Runner reads the consumer's `docs/formann/` view live from the host instead of re-running the installer on every pass to populate it. Fixes a preflight crash on consumers without an `installer/` directory and a drain-mode bug where the runner fell back to the wrong binding between iterations.
- Runner pins the sandbox git commit identity to `Claude <claude@anthropic.com>` so agent commits land with a deterministic author regardless of host git config. Override with `RUNNER_GIT_USER_NAME` / `RUNNER_GIT_USER_EMAIL`.
- `Feature` broadened to any slug-named work unit — PRD-bearing and standalone (PRD-less) features are both first-class.
- `/triage` prompts for a slug and applies `formann:feature` (github-issues binding) before transitioning an issue to `ready-for-agent` or `ready-for-human`, so issues opened in the GitHub web UI become runner-ready.
- The github-issues binding stores blocker relationships as GitHub's native issue dependencies. Blockers now appear in GitHub's sidebar instead of in a `## Blocked by` body section; local-markdown is unaffected.

### Fixed
- AFK runner can invoke `gh` against the host's GitHub repo from inside the sandbox under the github-issues binding. Previously `gh` failed with "remote points to a local path" because the runner-checkout's `origin` was a local mirror.
- AFK runner no longer marks a clean review as `gate-failed` under the github-issues binding. The binding closes the just-reviewed issue on a clean verdict, dropping it from the post-gate snapshot; the classifier now treats that absence as the binding-native `done` signal.
- AFK runner no longer silently loses agent commits when a dispatch ends in a mid-dispatch snapshot failure or a gate-failed / review-aborted verdict — the commit is parked to the host parking ref before the runner bails out, and a lazy-init guard refuses to overwrite a runner-checkout branch with unpublished commits if propagation is ever bypassed.
- Runner captures core-dump files left in untracked subdirectories of the runner-checkout (previously only root-level cores).
- Runner recovers from a dirty runner-checkout working tree before syncing the branch, instead of refusing the checkout. The leaked changes are logged to stderr before being scrubbed.
- AFK runner no longer aborts with a spurious "slug collision" error on the github-issues binding when two or more Formann features are open concurrently.
- AFK runner no longer silently skips every dispatch after a parking-ref sweep leaves the runner-checkout in an unborn-HEAD state — the checkout self-heals before sync.

## [0.1.0] - 2026-05-20

### Added
- Initial release. Methodology and tooling for running autonomous coding agents against tracked issues.
- Issue lifecycle as Claude Code skills: `/triage` for grooming, `/implement` for delivery.
- AFK runner that drains a feature's queue in sandboxed containers, so work continues while you're away from keyboard.
- Pluggable issue tracker via bindings; ships with `github-issues` and `local-markdown`.
- Symlink-based consumer adoption — a project adopts Formann by linking framework content through a single `.formann` indirection.
- Optional inbox for pre-lifecycle capture of deferred thoughts.
