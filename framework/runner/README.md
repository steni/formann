# AFK runner

Bash-driven runner that drains a feature's `ready-for-agent + AFK` queue by
dispatching `/implement` per issue inside a sandboxed Docker container.

`run-the-queue.sh` has three invocation forms, each accepting an optional `--model <id>` flag:

- **Bare invocation** (`run-the-queue.sh`, no args) — **drain mode**. Walks every active feature returned by `tracker-snapshot --list` (the discovery output, persisted to `<run-dir>/discovery.json`) and drains the ones it's allowed to touch. Features skipped for per-feature reasons (`fetch-failed`, `feature-snapshot-failed`, `queue-empty`) produce a SUMMARY row and the run continues. This is the scheduled-job shape: fire the runner regardless of which branch you have checked out; every authorized AFK queue advances.
- **`--feature <slug>`** — **loop mode**. Narrows to one feature; refuses loudly on a structural gate failure (`unknown-feature`).
- **`--issue <feature>/<NN>`** — **single-dispatch mode**. Dispatches one ref; refuses loudly on eligibility gate failures.

`--model <id>` overrides the model for every dispatch in the run (implement stage and each post-implement walk item). An unknown id is rejected by the CLI inside the container and surfaces as a normal dispatch failure — the runner keeps no model whitelist. Without the flag, the `RUNNER_MODEL` environment variable (when set) supplies the model — export it in your shell profile to pin a default model for every run; `--model` still overrides it. When a model is chosen either way, it appears in the SUMMARY.md run line and `runner.log`; with neither, behavior is byte-identical to prior runs.

Drain and loop mode also accept `--idle <seconds>`: instead of exiting when there is nothing left to do, the runner sleeps and starts a fresh pass — see [Idle loop](#idle-loop). It is refused with `--issue`.

Every form also accepts `--no-caffeinate`. By default the runner holds a macOS wake assertion for the whole run (`caffeinate -i -s` tied to the runner pid, released automatically on any exit) so an unattended host doesn't idle-sleep or timer-throttle a multi-hour run — the flag skips it for operators who manage power assertions themselves. On hosts without `caffeinate` (non-macOS) the runner logs a note and continues; either way `runner.log` records whether an assertion was held.

Drain mode stops on: every feature considered (`completed`); Ctrl-C (`interrupted`); or `tracker-snapshot --list` itself failing (`preflight-abort: discovery`).

Narrowed modes stop on: queue empty; Ctrl-C (the in-flight container receives SIGTERM, then SIGKILL after `RUNNER_KILL_GRACE_SECONDS` if it lingers); or a mid-loop `tracker-snapshot` crash (`snapshot-failed`, exit 1). The full stop-reason vocabulary — including the pre-flight-phase stops — is enumerated below the per-issue table.

## Idle loop

`run-the-queue.sh --idle <seconds>` (with or without `--feature <slug>`) keeps the runner alive. Each **pass** is one drain (or one loop over the feature) exactly as a run without `--idle` would do it; when the pass ends — queue empty, every feature considered, a feature parked, or a tracker or fetch outage — the runner sleeps `<seconds>` and starts the next pass:

- **Fresh state every pass.** Drain mode re-runs discovery (`tracker-snapshot --list`; on failure it keeps the previous list), and every feature is re-synced and re-snapshotted, so an issue made ready — or a feature created — while the runner slept is dispatched on the next pass, without a restart. Loop mode re-syncs the runner-checkout before its snapshot (a sync failure skips that pass).
- **Blocked steps are re-run every pass.** A step that ended `blocked (<dependency>)` is re-run, from that step, on the next pass (never twice in one pass). The pass count is read from the tracker each time, so passes made by another machine count; the third leaves the issue for a human.
- **One summary per pass.** A pass that dispatched anything writes `pass-<NNNN>/SUMMARY.md` in the run dir, and its per-issue artifacts land beside it, so a later pass never overwrites an earlier one's logs. A pass with nothing to do leaves no directory. The run's own `SUMMARY.md` ends with a `## Passes` index linking each pass.
- **Stopping.** Ctrl-C or SIGTERM — during a dispatch or during the sleep (honoured within a second) — stops the runner with stop reason `interrupted`, exit 0, and the usual summary. A `propagation-error` or `runaway-halt` stops it with exit 1, as it would stop a single drain. A pre-flight failure exits 2 before the first pass.

Without `--idle`, nothing changes: the runner makes one pass and exits.

## Running as a service

On an unattended machine, start the runner with `--idle` from the OS service manager so it starts with the machine and comes back after a crash. Both recipes below run it as **your user** (it needs your git credentials, your Docker access and your OAuth token), from the consumer repo root, restart it only when it exits non-zero, and append its terminal output to `.runner-state/service.log`. Each run still writes its own `runner.log` and `SUMMARY.md` under `.runner-state/runs/<ts>/`; `service.log` adds whatever happened before a run dir existed (a pre-flight abort, a crash).

Replace `/path/to/consumer` with the consumer repo's absolute path, and set `PATH` to include `docker`, `git`, `jq` and (for the github-issues binding) `gh`. Add `RUNNER_FORMANN_DIR` (and `RUNNER_FORMANN_REF` if not `origin/main`) to the unit's environment so the service runs — and keeps updating — its own Formann; see [The Runner's Formann](#the-runners-formann). A crashed runner leaves its pidfile lock behind; the next start finds the owner gone and reclaims it.

**macOS — launchd.** Save as `~/Library/LaunchAgents/dev.formann.runner.plist`. A LaunchAgent runs in your login session, so the Keychain entry holding the OAuth token is readable; the runner's own wake assertion keeps the machine awake while it runs.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.formann.runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/path/to/consumer/.formann/runner/run-the-queue.sh</string>
    <string>--idle</string>
    <string>300</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/path/to/consumer</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>60</integer>
  <key>ExitTimeOut</key>
  <integer>60</integer>
  <key>StandardOutPath</key>
  <string>/path/to/consumer/.runner-state/service.log</string>
  <key>StandardErrorPath</key>
  <string>/path/to/consumer/.runner-state/service.log</string>
</dict>
</plist>
```

```sh
mkdir -p /path/to/consumer/.runner-state
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.formann.runner.plist   # start now and at every login
launchctl print gui/$(id -u)/dev.formann.runner                                    # state, pid, last exit code
launchctl kickstart -k gui/$(id -u)/dev.formann.runner                             # restart (e.g. after pulling a new Formann)
launchctl bootout gui/$(id -u)/dev.formann.runner                                  # stop (SIGTERM → interrupted) and unload
```

`KeepAlive` → `SuccessfulExit: false` restarts the runner after a non-zero exit (a crash, `propagation-error`, a pre-flight abort) but not after a clean stop; `ThrottleInterval` spaces restarts a minute apart. `bootout` sends SIGTERM, and `ExitTimeOut` gives an in-flight dispatch time to stop before launchd escalates to SIGKILL. A LaunchAgent starts at login: on a Mac that must run after a reboot with nobody at the screen, enable automatic login for that user.

**Linux — systemd (user unit).** Save as `~/.config/systemd/user/formann-runner.service`:

```ini
[Unit]
Description=Formann AFK runner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/path/to/consumer
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/bash /path/to/consumer/.formann/runner/run-the-queue.sh --idle 300
Restart=on-failure
RestartSec=60
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=60
StandardOutput=append:/path/to/consumer/.runner-state/service.log
StandardError=append:/path/to/consumer/.runner-state/service.log

[Install]
WantedBy=default.target
```

```sh
mkdir -p /path/to/consumer/.runner-state
sudo loginctl enable-linger "$USER"                # start your user units at boot, without a login
systemctl --user daemon-reload
systemctl --user enable --now formann-runner       # start now and at every boot
systemctl --user status formann-runner             # state, pid, last exit code
systemctl --user restart formann-runner            # restart (e.g. after pulling a new Formann)
systemctl --user stop formann-runner               # stop (SIGTERM → interrupted)
```

`Restart=on-failure` restarts the runner after a non-zero exit or a kill, not after a clean stop; `RestartSec` spaces restarts a minute apart. `KillMode=mixed` sends SIGTERM to the runner alone, so it stops its in-flight container itself, and `TimeoutStopSec` bounds that before systemd sends SIGKILL. Your user must be in the `docker` group. The OAuth token must be readable without a desktop session: on a headless box with no unlocked GNOME Keyring, libsecret lookups fail, and the kernel keyring's `@s` session keyring does not survive into a service — store the token where the service can read it before relying on the unit (check with `systemctl --user start formann-runner` and `.runner-state/service.log`: a token failure is a `preflight-abort: oauth-token`).

## The Runner's Formann

The runner runs from a Formann checkout of its own, never from the one your interactive sessions read through `.formann`. At the start of every run — and, with `--idle`, before every pass after the first — it fast-forwards that checkout to a configured ref and runs the code there, so every machine runs the same Formann without anyone pulling on each one, and an update never changes skills under a live session.

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_FORMANN_DIR` | _(unset)_ | Path of the runner's own Formann checkout: a **git clone** of the Formann remote, used by nothing else. Unset: the runner runs from wherever it was started, updates nothing, and records that checkout's sha as `<sha> (not self-updated: RUNNER_FORMANN_DIR is unset)`. |
| `RUNNER_FORMANN_REF` | `origin/main` | `<remote>/<branch>` the checkout follows — upstream `main`, or your own integration branch (e.g. `fork/integration`, after `git -C "$RUNNER_FORMANN_DIR" remote add fork <url>`). |

**Setting it up.** Clone the Formann remote somewhere of its own and point the runner at it — in the service unit's environment, or your shell profile:

```sh
git clone https://github.com/<owner>/formann.git ~/formann-runner     # the runner's Formann; never edit it
export RUNNER_FORMANN_DIR=~/formann-runner
export RUNNER_FORMANN_REF=origin/main                                 # or <remote>/<your-integration-branch>
```

Keep starting the runner as before (`.formann/runner/run-the-queue.sh`, or the service recipes above): the copy you start only updates the runner's checkout and then re-executes `$RUNNER_FORMANN_DIR/framework/runner/run-the-queue.sh` with the same arguments, so the drain runs the checkout's code. The sandbox still sees the consumer's `.formann` (read-only) for the skills it runs.

**An rsync copy must become a clone.** A checkout copied from another machine with `rsync` (as on smia today) has no git history the runner can fast-forward — or carries the other machine's local state — and is refused as `not a git clone`. Replace it: move it aside, `git clone` the configured remote into `RUNNER_FORMANN_DIR`, and start the runner. Never edit the clone in place: carry your own changes on a branch of a remote and point `RUNNER_FORMANN_REF` at it.

**What happens at each drain:**

- **Fast-forward.** `formann_self_update` (`formann-update.sh`) fetches `<branch>` from `<remote>` and fast-forwards the checkout to it. When the sha moved, or the runner was started from another copy, the runner re-executes itself from the checkout before it takes the lock or any claim. In the idle loop a pass that finds the ref moved ends the run (stop reason `formann-updated`; summary, claims and lock released as usual) and the same process re-executes on the new code, which starts a fresh run.
- **Refusal.** Local changes (modified, staged or untracked files), divergence (commits the ref lacks — the checkout is ahead of it or has diverged), a missing directory, a directory that is not a git clone, or a ref that cannot be fetched refuse the drain with the reason, before any claim is taken: at startup `preflight-abort: runner-formann` (exit 2; the reason is the line `runner: runner-formann: refusing to drain: <reason>` in `runner.log`); in the idle loop the pass is skipped as `formann-refused` and the runner tries again after the sleep. Reconcile the checkout by hand (`git -C "$RUNNER_FORMANN_DIR" status`, `reset --hard <remote>/<branch>` if the local state is not wanted) — the runner never discards it for you.
- **Record.** The sha is the `formann:` line of the **Claim** and the `- Formann: <sha> (<ref>)` line of `SUMMARY.md` (every variant, including a pre-flight abort and each pass's summary), and `runner.log` opens with `runner: Formann <sha> (<ref>)`. A bad run points straight at the version that produced it.

## Per-run output

Every invocation — including pre-flight aborts — creates a fresh run dir
at `.runner-state/runs/<YYYYMMDD-HHMMSS>/` containing:

| File | Role |
|------|------|
| `runner.log` | Everything the runner emits to stdout/stderr, captured via `tee` (terminal still receives the live stream). |
| `discovery.json` | The JSON array returned by `tracker-snapshot --list`. Written immediately after the `discovery` pre-flight invariant passes; same lifecycle as `runner.log`. Forensics for "why didn't the runner consider feature X?". |
| `<NN>.stdout.jsonl` (narrowed) / `<feature>/<NN>.stdout.jsonl` (drain) | The implement dispatch's stdout: the full streamed structured-event trace (one JSON object per line — tool calls, results, the terminal `result` event). What the transport-crash classifier and the readable-summary extraction read. Drain mode nests under a per-feature subdir so per-issue artifacts don't collide across features that share `<NN>`. |
| `<NN>.stderr.log` / `<feature>/<NN>.stderr.log` | The implement dispatch's stderr (diagnostic/crash text). Retained for forensics only — the classifier never reads it (the spike proved it carries no transport signal). |
| `<NN>.summary.md` / `<feature>/<NN>.summary.md` | The implement dispatch's readable closing message, extracted from the terminal `result` event — the skim-the-outcome artifact. This is what the SUMMARY table links. |
| `<NN>.exit` / `<feature>/<NN>.exit` | Per-issue implement-dispatch exit code (a bare integer). |
| `<NN>-<step>-<label>.{stdout.jsonl,stderr.log,summary.md}` (narrowed) / `<feature>/…` (drain) | The same three per-dispatch artifacts for each post-implement walk step, e.g. `01-01-review.stdout.jsonl` for the default single `review` step. One set per step that ran; absent when the implement stage failed and the walk never started. |
| `pass-<NNNN>/` (`--idle` only) | One directory per pass that dispatched anything: its own `SUMMARY.md` (same shape as the run's), and that pass's per-issue artifacts (the rows above) inside it instead of directly in the run dir. |
| `SUMMARY.md` | Markdown end-of-run summary. With `--idle`, it ends with a `## Passes` index linking every `pass-<NNNN>/SUMMARY.md`. Narrowed modes: feature heading + flat per-issue table. Drain mode: `# AFK runner — multi-feature drain` heading + per-feature sections (`## <feature> — drained` or `## <feature> — parked (Shared remote refused the fast-forward)` with nested per-issue table, or `## <feature> — skipped: <reason>` / `## <feature> — held-by <machine>` / `## <feature> — feature-snapshot-failed` one-liner; `## <feature> — taken-over-by <machine> (stopped after its current dispatch)` with the table of what it dispatched before). Pre-flight aborts replace the table with a single line naming the failing invariant. |

Stdout while a run is in flight uses per-stage progress lines. A typical
iteration produces four (implement starting/outcome, review starting/outcome):

```
[09:12:45] afk-runner/06 implement → starting
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:27] afk-runner/06 review → starting
[09:13:31] afk-runner/06 review → clean → done (4s)
```

A multi-step manifest contributes one pair per step. A step's outcome
names what that step did, not the iteration's verdict: `in-review` means
the issue is still open and the walk is advancing to the next step. Only
the last step can read `left-for-human`, and there it matches the
combined outcome in the end-of-run table:

```
[13:36:40] afk-runner/06 find-and-fix → starting
[13:46:08] afk-runner/06 find-and-fix → in-review (9m 28s)
[13:46:08] afk-runner/06 review-and-gate → starting
[13:52:11] afk-runner/06 review-and-gate → left-for-human (6m 3s)
```

When a parking-ref publish fails after a stage, the original outcome
line is preserved (the dispatch step itself succeeded; the failure is
downstream) and a follow-up `halt → <recorded outcome>` line is emitted
so the visible record matches the SUMMARY.md row:

```
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:28] afk-runner/06 implement → halt → FAIL (43s)
```

## Liveness line

Between a stage's two progress lines, the runner paints a single
transient **liveness line** in place on the controlling terminal,
showing what the in-flight dispatch is doing right now and for how
long:

```
afk-runner/06 implement 12m 34s | Bash: bats -p framework/runner/tests (1m 2s)
```

The phase is derived from the latest relevant streamed event (see
GLOSSARY.md, *Dispatch phase*): an assistant tool-use event names the
running tool, a tool-result event reads `thinking`, and a
`system`/`api_retry` event reads `retry <attempt>/<max> (<reason>)` —
the CLI retrying a transport fault internally, where an advancing
attempt counter is liveness and a frozen one with a climbing timer is a
genuinely wedged retry loop. The line repaints every second, so the
time-in-phase climbs even when no event arrives: a changing phase with
a resetting timer means progress; a frozen phase with a climbing timer
means stuck. The label truncates to the terminal width, and the line is
cleared when the dispatch ends (including on Ctrl-C).

The line is painted directly to `/dev/tty`, bypassing the `runner.log`
capture: it never appears in `runner.log` or any saved artifact, a
redirected stdout stays clean while the terminal still shows the line,
and on a fully-detached run (no controlling terminal) the machinery
silently does nothing. The renderer is a read-only observer of the
dispatch's event-stream artifact — every failure mode degrades to a
missing or partial line and can never terminate, delay, or alter a
dispatch or its classified outcome. Set `RUNNER_DISABLE_LIVENESS=1` to
turn the line off entirely.

The end-of-run table prints one row per iteration, with a single
combined-outcome column. The combined-outcome vocabulary is:

| Outcome | Meaning |
|---------|---------|
| `done` | Gate found no Critical findings; status flipped to `done`. |
| `left-for-human` | Post-implement walk exhausted with the issue still at `in-review` (e.g. the review step found ≥1 🔴 Critical and appended findings as a comment). No abort flag; the maintainer picks it up. |
| `gate-failed` | Gate dispatch errored or landed on an off-mission status. Runner writes a `type: technical` abort flag and continues. |
| `review-aborted` | Gate subprocess transport-crashed (empty log, API 5xx/429, network error) and exhausted its retries. Runner writes a `type: transport` abort flag and continues. |
| `dispatch-aborted` | Implement subprocess transport-crashed and exhausted its retries. Runner writes a `type: transport` abort flag and continues. |
| `window-exhausted` | The dispatch (implement or walk item — the abort flag's `dispatch:` field names the stage) still died usage-window-rejected after `RUNNER_WINDOW_RETRY_MAX_WAITS` window-waits. The quota is structurally insufficient for this dispatch, not a blip to `rm` and re-run. Runner writes a `type: window` abort flag and continues. |
| `in-review` | AFK iteration interrupted between implement-finish and the start of the post-implement walk: implement landed `in-review`, the interrupt pre-empted the first walk step, and the iteration is recorded at its implement outcome. |
| `FAIL` | Implement-stage failure (classifier verdict, container error, or parking-ref publish failure). Any `tracker:` work the dispatch did commit (notably the comment `/implement` posts on a bail) is still propagated to the host so it shows up on your branch when you return. |
| `blocked (<dependency>)` | A post-implement step couldn't reach a dependency outside the run and ended `BLOCKED: <dependency>` after posting a Blocked comment. The issue keeps its state, no abort flag is written, and the run moves on to the next eligible issue; the next run (with `--idle`, the next pass) re-runs the walk from the blocked step (`.runner-state/blocked/<feature>/<NN>` names it), without re-running `/implement`. |
| `left-for-human (blocked: <dependency>)` | The third Blocked pass (counted from the issue's Blocked comments since its latest Implementation comment). The issue is left for you with those comments as the reason. No abort flag. |
| `halt → runaway` | A post-implement step drove the issue back to `ready-for-agent` (eligible) — a misconfigured manifest that would otherwise re-dispatch the same ref forever. The runner halts the entire run immediately. No abort flag (the issue is eligible, not stuck); the maintainer fixes the manifest. |

The trailing `stop reason:` line varies by mode.

**Drain mode (bare invocation):**

- `completed` — every feature in discovery output considered (the multi-feature analogue of single-feature mode's `queue-empty` at the run level).
- `interrupted` — Ctrl-C during the outer loop.
- `propagation-error` — parking-ref publish failed inside a feature loop; the entire drain halts (exit 1).
- A feature whose Shared-remote push was refused is not a run-level stop: its section reads `## <feature> — parked (Shared remote refused the fast-forward)` and the drain continues with the next feature.
- A feature another runner holds a **Claim** on is not a stop either: its section reads `## <feature> — held-by <machine>` and the drain continues with the next feature. A claim that can't be taken at all (Shared remote unreachable) reads `skipped: claim-failed`.
- A feature whose claim another runner took over mid-drain stops after its current dispatch, its section reading `## <feature> — taken-over-by <machine> (stopped after its current dispatch)`; the drain continues with the next feature.
- `preflight-abort: discovery` — `tracker-snapshot --list` exited non-zero or returned unparseable JSON.

**Narrowed modes (`--feature`, `--issue`):**

- `queue-empty` / `interrupted` / `snapshot-failed` / `propagation-error` — the per-issue loop's stop reasons (see "The dispatch loop" in `afk-runner.md`).
- `publish-parked` (`--feature`) — the Shared remote refused a fast-forward; the work is on the parking ref and the loop stopped on the feature.
- `held-by <machine>` (`--feature`) — another runner holds the feature's Claim; nothing was dispatched (with `--idle`, the next pass tries again). `claim-failed` — the claim couldn't be taken (Shared remote unreachable).
- `taken-over-by <machine>` (`--feature`) — a heartbeat found the feature's claim taken over by another runner; the loop stopped after the dispatch in flight.
- `feature-restricted (refused: <reason>)` (`--feature`) — `<reason>` is `unknown-feature` (slug not in discovery output).
- `single-dispatch (success|failure)` (`--issue`); or `single-dispatch (refused: <reason>)` — `<reason>` is one of: HITL type, wrong status, unmet blockers, `unknown-feature`, `snapshot-failed`.

**All modes — pre-flight-phase:**

- `interrupted-during-preflight` — Ctrl-C arrived before the loop started.
- `preflight-abort: <invariant>` — a pre-flight invariant tripped before the loop began. `preflight-abort: runner-formann` — the Runner's Formann could not be fast-forwarded to its ref (see [The Runner's Formann](#the-runners-formann)); nothing was locked or claimed.

**With `--idle`, per pass:** `formann-refused` — the Runner's Formann update refused; the pass drained nothing and the runner tries again after the sleep. `formann-updated` — the ref moved; the run ends (exit 0) and the runner re-executes on the new Formann.

## Transport-class retry

When a dispatch container exits with a transport-class failure (API 5xx or 429, network error, or an empty log with no model output), the runner retries the dispatch automatically before recording an abort flag.

**Default schedule** (overridable via env vars):

| Attempt | Wait before next attempt |
|---------|--------------------------|
| 1 → 2   | 30 s                     |
| 2 → 3   | 90 s                     |
| 3 → 4   | 240 s                    |
| (max 4 attempts total) | —          |

The wait is a 1-second poll loop so `Ctrl-C` / `SIGTERM` exits immediately rather than blocking until the sleep expires.

**Defensive guard:** if the runner-checkout's `HEAD` advances between attempts (a prior attempt committed partial work), retries are suppressed and the original failure is propagated. The intent is to avoid double-applying work. The check inspects the runner-checkout under `.runner-state/checkout/`, not the host repo.

**Per-attempt logs:** each failed attempt's log is preserved as `<log>.attempt-<N>` alongside the primary log file, so the maintainer can inspect what each attempt produced.

**Escape hatch:**

```sh
RUNNER_DISABLE_TRANSPORT_RETRY=1 ./run-the-queue.sh ...
```

Set `RUNNER_DISABLE_TRANSPORT_RETRY=1` to skip the retry layer entirely (useful when debugging or when the upstream API quota issue is known to be persistent).

**Knobs:**

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS` | `4` | Maximum total attempts (including the first) |
| `RUNNER_TRANSPORT_RETRY_BACKOFFS` | `"30 90 240"` | Space-separated list of wait seconds for attempts 1→2, 2→3, 3→4, … If the list is shorter than the attempt budget, the last entry is reused for the remaining gaps |
| `RUNNER_DISABLE_TRANSPORT_RETRY` | `0` | Set to `1` to bypass all retry logic |

## Window-exhausted retry

An exhausted usage window (e.g. the account's five-hour window with no overage credit) is a distinct retryable class, not a transport blip: the dispatch dies in under a second with a well-formed event stream whose `rate_limit_event` carries `status:"rejected"` (and usually a `resetsAt` epoch), dressed as a 429 terminal result. Detection reads only that structured event — never the assistant/result text, whose wording varies across CLI versions — and skips unparseable `rate_limit_event` lines (they can be injected mid-NDJSON-line, corrupting adjacent lines).

When a failed dispatch's stream ends window-rejected, the runner — instead of burning the transport backoff budget against a quota that is hours from returning — sleeps until `resetsAt` plus a fixed 60-second slack (a `resetsAt` already in the past degrades to the bare 60s; no cap on a single sleep) and re-dispatches. When the rejected event carries no `resetsAt`, it waits `RUNNER_WINDOW_RETRY_FALLBACK_WAIT` seconds instead. At most `RUNNER_WINDOW_RETRY_MAX_WAITS` window-waits per dispatch; a further rejection past that budget records the combined outcome `window-exhausted` and a `type: window` abort flag.

**Defensive guard:** if the runner-checkout's `HEAD` advances between rounds (a prior round committed partial work before dying window-rejected), the wait is suppressed and the runner gives up immediately with the same `window-exhausted` outcome and `type: window` abort flag as the wait-budget give-up. The intent is to avoid double-applying work — replaying `/implement` over a half-committed checkout is exactly what the transport-retry guard refuses, and the window path refuses it too. A give-up line naming the advanced `HEAD` is printed in place of the wait-start line, so `runner.log` explains why no wait happened. The check inspects the runner-checkout under `.runner-state/checkout/`, not the host repo.

Window-waits do not consume the transport-retry budget, and the transport attempt counter resets after each window-wait; archived per-attempt logs continue the same `.attempt-<N>` numbering, and the SUMMARY's `(N attempts)` suffix counts all rounds. The wait is a 1-second poll loop, so `Ctrl-C` exits immediately (stop reason `interrupted`, no abort flag). No liveness line is painted during the wait; the operator surface is two static progress lines, mirrored into `runner.log`:

```
[09:25:57] runner: usage window exhausted (five_hour) — waiting until 13:17:00 (3h 51m; wait 1 of 2)
[13:17:00] runner: usage window reset — retrying dispatch
```

(the parenthesized type is the event's `rateLimitType`; when the event carries no `resetsAt` the first line reads `— resetsAt absent; waiting 3600s (fallback; wait 1 of 2)`).

**Knobs** (the numeric ones get the same pre-flight non-numeric refusal as the transport knobs):

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_WINDOW_RETRY_FALLBACK_WAIT` | `3600` | Seconds to wait when the rejected event carries no `resetsAt` |
| `RUNNER_WINDOW_RETRY_MAX_WAITS` | `2` | Window-waits allowed per dispatch before giving up with `window-exhausted` |
| `RUNNER_DISABLE_WINDOW_RETRY` | `0` | Set to `1` to skip the rejected-event check entirely — a window-exhausted 429 then degrades to the transport path |

## Default-branch resolution

When a feature's branch exists on the Shared remote but not on host, the runner starts from the remote's branch (see *Publishing to the Shared remote*). When it doesn't exist anywhere yet, the runner lazy-initializes it from the repo's default branch — based on that branch's *current host tip*, fetched at sync time — and pushes it to the Shared remote at once. The same resolution drives the lazy-init preserve-commits guard and the unborn-HEAD recovery. The default branch is resolved deliberately (`resolve_default_branch`), in precedence order:

1. `RUNNER_DEFAULT_BRANCH` — operator override.
2. The host repo's own `refs/remotes/origin/HEAD` — when the host was cloned from a real upstream, this is the upstream's default branch.
3. `refs/heads/main`, then `refs/heads/master`, on host.
4. Loud failure naming the override knob. Never a silent fallback.

Two sources are explicitly forbidden: the host's currently-checked-out branch and the runner-checkout's clone-time `origin/HEAD`. Both are accidents of timing — for a clone of a local non-bare repo, `origin/HEAD` is whatever branch the host happened to have checked out at clone time, never an authoritative default-branch signal.

**Knob:**

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_DEFAULT_BRANCH` | (empty) | Override the resolved default branch; empty means auto-resolve per the precedence above |

## Publishing to the Shared remote

After every dispatch that commits, the host side of the runner fast-forwards the commit onto the **Shared remote**'s feature branch — after the parking ref and the host fast-forward, before the first post-implement step starts (ADR-0011). The push runs in the host repo with the host's git credentials; nothing changes in the sandbox. It is fast-forward only: never `--force`, never a `+` refspec.

The `propagation` column of `SUMMARY.md` and the end-of-run table, and the per-dispatch progress line, lead with the publish state:

| Indicator | Meaning |
|-----------|---------|
| `published → <remote>/<branch>` | The Shared remote's branch is at the dispatch's commit. |
| `parked → runner/<branch>` | The push was refused (the remote branch has commits the runner lacks) or failed (auth, network — git's stderr is in `runner.log`). The remote is untouched; the work is on the parking ref; the runner stops on this feature. Listed under `## Unpulled parked work`. |
| `local-only (propagated → host)` / `local-only (parked → runner/<branch>)` | The host repo has no remote of that name: nothing is pushed, and the parenthesised host outcome is exactly the one-machine behaviour. |

**Starting from the Shared remote.** Before every dispatch the host repo reads `<remote>/<branch>` and the runner-checkout is synced to the most advanced of the Shared remote's branch, the host branch and the parking ref that the others are ancestors of. A feature begun on another machine therefore continues from its published tip, even on a machine that never had the branch. When the remote branch and the parking ref have diverged, the runner builds on the parking ref and the publish parks the feature. A feature branch the runner creates from the default branch, because it exists nowhere yet, is pushed to the Shared remote before the first dispatch. A Shared remote the host cannot reach fails the sync (`skip:fetch-failed` in drain mode); with no remote of that name, nothing is read or pushed.

To recover from `parked`, bring the two chains together by hand — `git pull runner <branch>`, merge or rebase onto `<remote>/<branch>`, push — and re-run.

**Knob:**

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_SHARED_REMOTE` | `origin` | Name of the host repo's git remote the runner publishes to. A name with no matching remote means `local-only`. |

## Claims across machines

Two runners on two machines never drain the same feature: before a feature's first dispatch (drain mode and `--feature`), the runner takes a **Claim** on it, a ref on the Shared remote, and releases it when the feature's drain ends (ADR-0011). `--issue` takes no claim.

- **The claim ref.** `refs/formann/claims/<feature>` on the Shared remote, pointing at a parentless commit (empty tree) whose message reads `machine: <hostname>`, `run: <run id>`, `formann: <sha or unknown>`, `heartbeat: <UTC ISO-8601>`. Inspect one with `git fetch <remote> refs/formann/claims/<feature> && git log -1 FETCH_HEAD`.
- **Take** is `git push --force-with-lease=refs/formann/claims/<feature>: <remote> <commit>:refs/formann/claims/<feature>` — the lease expects the ref absent, so of two runners starting the same second exactly one wins. The loser reads the claim and skips the feature: `held-by <machine>` in `SUMMARY.md`, and the drain moves on to the next eligible feature.
- **Heartbeat.** Between dispatches — before each `/implement` dispatch and before each post-implement step — the holder replaces its claim commit with one carrying a fresh `heartbeat:`, a lease push on the sha it last wrote. A heartbeat that fails for a network reason is logged and tried again at the next heartbeat point; the drain goes on.
- **Stale and takeover.** A claim whose heartbeat is more than `RUNNER_CLAIM_STALE_AFTER` seconds old (default 1800, thirty minutes) by the reader's own clock is stale; nobody writes "stale". A runner that finds a stale claim takes it over with a lease push on the stale claim's sha — logged and announced with a Note like a take (`taken-over-from <machine>`). A refused lease means the holder heart-beat meanwhile: the newcomer backs off as `held-by <machine>`. Of a takeover and a late heartbeat racing, exactly one wins.
- **Lost claim.** A holder whose heartbeat lease is refused, and whose re-read shows another runner's claim, has lost it: it finishes the dispatch in flight (including that dispatch's remaining post-implement steps), takes no further issue on the feature, does not release the claim, and reports `taken-over-by <machine>` in `SUMMARY.md` (or as the `--feature` stop reason). Its last commit reaches the Shared remote by the Publisher's fast-forward, or parks. A heartbeat is only taken between dispatches, so a single dispatch longer than the stale-after time can be taken over while it runs.
- **Release** is a lease delete on the sha the runner wrote. It runs when the feature's drain ends, however it ends, and again from the EXIT trap (`finalize_run`) — which every interrupt and abort reaches — for a claim still held. A release whose lease is refused (the ref moved) leaves the ref alone.
- **The rule.** Every claim write is a lease push on the sha the writer last read; a refused lease is never retried as a plain or forced push. `claim.sh` is the only code that writes claim refs, from the host with the host's credentials.
- **The Note.** On taking a claim, the runner posts a `Note` on the feature's parent through the binding's `comment-on-feature` script — which machine and run claimed it. It is information only: a Note that can't be posted is logged and the drain goes on. Under local-markdown the Note is a `tracker:` commit on the feature's `PRD.md`, propagated (and published) at once.
- **No Shared remote:** no claims, no Note; the local lock is the only guard, as before. The local lock stays in every case.
- `RUNNER_MACHINE` overrides the hostname recorded in the claim.

A claim left behind by a runner that was killed outright (`kill -9`, power loss) goes stale thirty minutes after its last heartbeat, and the next runner to reach the feature takes it over. To free it sooner, delete it by hand — `git push <remote> :refs/formann/claims/<feature>`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `RUNNER_CLAIM_STALE_AFTER` | `1800` | Seconds after its last heartbeat at which a claim is stale and may be taken over. |

## Resuming after a technical failure

When a dispatch fails and the issue could otherwise be re-picked (implement failure with the issue still eligible, or gate failure), the runner writes a plain-text abort flag at `.runner-state/aborted/<feature>/<NN>`. Eligibility selection skips flagged refs on every subsequent run, preventing infinite re-dispatch across restarts.

The flag's first line identifies the failure class:

```
type: technical   # model error, bad brief, or other non-transport cause
type: transport   # transport-class crash: API 5xx/429, network error, or empty log
type: window      # usage window still rejected after the window-wait budget
```

A `type: transport` flag means the dispatch hit a transport-class fault — the terminal `result` event reported a retryable error (HTTP 429 / 5xx, or a connection-layer fault with no HTTP status), or the dispatch died with no recoverable result event and a nonzero exit. The failure is infrastructure, not a problem with the brief or implementation. A `type: technical` flag means the dispatch produced a result event indicating a genuine failure (e.g. a non-transport 4xx). A `type: window` flag means the dispatch was still usage-window-rejected after `RUNNER_WINDOW_RETRY_MAX_WAITS` window-waits — the account's quota is structurally insufficient for this dispatch, so re-running without more quota (or a smaller slice) will hit the same wall. The `log` field points at the dispatch's event-stream artifact; its `.stderr.log` sibling holds diagnostics. Sample flag with the full layout:

```
type: transport
dispatch: review
at: 2026-05-16T19:58:37Z
exit: 1
log: .runner-state/runs/20260516-195837/f/01-01-review.stdout.jsonl
```

The `dispatch` field carries the manifest item's label (e.g. `review` for the default single-entry manifest). An interrupted dispatch (Ctrl-C or SIGTERM during an active implement or item run) does not write an abort flag — the maintainer's intent is to stop, not to mark the issue as stuck. The next run re-dispatches the issue normally without any `rm` recipe required.

Single-dispatch (`--issue <ref>`) shares the same eligibility gate as loop mode but reacts differently when the named ref fails it: instead of silently skipping (loop mode's response — the ref isn't in the eligible set, so it never gets picked), single-dispatch exits 2 with `single-dispatch (refused: <reason>)` and prints a stderr diagnostic naming the cause (HITL, wrong status, unmet blockers, missing from snapshot, or `snapshot-failed` if `tracker-snapshot` itself crashed). No container runs and no abort flag is written — the maintainer corrects the invocation (target an eligible AFK ref, or re-triage the named one) and re-runs.

To inspect what is stuck:

```sh
# List all aborted issues for the current feature
ls .runner-state/aborted/<feature>/

# Read an abort flag (dispatch, timestamp, exit code, artifact path)
cat .runner-state/aborted/<feature>/<NN>

# Skim the agent's closing message, or read the full event trace / diagnostics
cat .runner-state/runs/<ts>/<NN>.summary.md       # readable closing message
cat .runner-state/runs/<ts>/<NN>.stdout.jsonl     # full streamed-event trace
cat .runner-state/runs/<ts>/<NN>.stderr.log       # diagnostics (forensics)
```

To resume (re-include the ref in eligibility selection):

```sh
rm .runner-state/aborted/<feature>/<NN>
```

After removal, the next `run-the-queue.sh` invocation will see the ref as eligible again. Typical workflow: read the abort flag to find the log, diagnose the failure (wrong brief, expired token, infra issue), fix the underlying cause, then `rm` the flag and restart the runner.

## Post-implement walk (AFK)

After a successful AFK `/implement` shipping, the runner walks a
Consumer-owned **post-implement manifest** of follow-on steps, each
dispatched in its own fresh sandbox container. The manifest lives at
`runner/manifest.md`; each non-blank, non-comment line is a prompt path
resolved against the consumer root (`runner/`) first, then the framework root
(`framework/runner/steps/`). The step label is the filename without `.md`.

The default manifest is a single entry `review-and-gate.md`, which runs the
fused review-and-gate prompt at `framework/runner/steps/review-and-gate.md`.
That prompt instructs the dispatched claude session to:

1. Read the issue file.
2. Spawn the `review-issue` agent for an independent review.
3. Classify by 🔴 Critical findings — clean if none, blocked otherwise.
4. Comment with Review (AFK gate) on the issue, with the findings verbatim.
5. On a clean verdict only, set the state to `done`.
6. Land a single `tracker:` commit and emit a `verdict:` line on stdout.

A Consumer can replace the default with a custom manifest composed from the
framework's single-purpose **building-block steps** in `framework/runner/steps/`
— `review.md` (review and post findings, no state change), `gate.md` (read the
latest findings and promote on no-Critical, runs no review of its own),
`fix.md` (read the latest findings and commit fixes), and `find-and-fix.md`
(run `/code-review --fix` over the change-set, commit the fixes, and note them;
soft-fails without blocking). Compose them for review-without-gate
(`[review.md]`), a separate review reusing the framework gate
(`[review.md, gate.md]`), automatic bug-fixing before the gate
(`[find-and-fix.md, review-and-gate.md]`), or an unrolled iterate loop
(`[review-and-gate.md, fix.md, review-and-gate.md, …]`).
The review→gate handoff is the severity-marker convention in the posted
findings comment, so any review that emits it interoperates with the
framework `gate`. See `afk-runner.md` for the walk model and the
building-block steps, and GLOSSARY.md (*Building-block step*, *Review↔gate
contract*) for the term definitions.

The runner classifies the step's outcome from the snapshot delta and the
dispatch exit code (`classify_item_action` in `run-the-queue.sh`, called
per walk step by `walk_post_implement_steps`) — it does not parse the
verdict line. The one result line it does read is a closing
`BLOCKED: <dependency>`: the step couldn't reach something outside the run.
The runner then reads the issue's Blocked pass count through the binding's
`blocked-passes` script (`docs/formann/issue-tracker/blocked-passes <ref>`)
and records `blocked (<dependency>)`, or `left-for-human (blocked: …)` at
the third pass. See "Blocked steps" in `afk-runner.md`. A terminal status (`done`) and an issue left at `in-review`
both return 0 from `dispatch_one` (operational health is fine; the
verdict is independent); a failed step returns 1 and writes an abort flag.

## Sandbox primitives

| File | Role |
|------|------|
| `Dockerfile` | **Consumer-owned** (lives at `<consumer>/runner/Dockerfile`, not in the framework — see ADR-0002). The installer scaffolds an initial Debian-slim image with JDK 25, Maven, git, the `claude` CLI, a non-root user (UID/GID 1000), workdir `/repo`, and an inlined entrypoint that suppresses kernel core dumps (`ulimit -c 0`). The consumer edits it for their project. |
| `build-image.sh` | Builds the consumer's image idempotently from `<consumer>/runner/Dockerfile`. Walks `$PWD` upward to find the consumer root (`.formann` ancestor), so it works from anywhere inside the consumer repo. Builds when no image exists under the consumer's image name or when the image's `formann.runner.context-hash` label no longer matches the hash of `<consumer>/runner/` (any file edited, added, removed, renamed or made (non-)executable); that build reuses the layer cache, so an unchanged recipe costs nothing. Otherwise reuses the image. `--rebuild` forces a build that still reuses the layer cache (cheap; keeps installed tools at their cached versions). `--fresh` forces a build with no layer cache and a base-image re-pull, so every tool — apt packages, the JDK, Node, and the Claude CLI — re-resolves to its current published version. Prints the image name on stdout. |
| `sandbox-env` | **Consumer-owned, optional** (lives at `<consumer>/runner/sandbox-env`). An executable that prints `KEY=value` lines to add to every dispatch container's environment — credentials the consumer's own agents need, read on the host (e.g. from Keychain). Same contract as the binding's `docs/formann/issue-tracker/sandbox-env`: non-zero exit or a malformed line fails the dispatch. It may only add variables; a key the runner (OAuth token, git identity, dispatch env) or the binding already sets is refused, as is any `ANTHROPIC_*` or `CLAUDE_CODE_*` key, since those configure the dispatch's `claude`. It is tracked and runs on the host, so an agent's change to it runs there once pulled: review it as host-side code. Being under `runner/`, editing it rebuilds the image on the next run. |
| `setup-network.sh` | Creates the sandbox bridge network and applies the RFC1918-deny outbound policy. Idempotent. Prints the network name on stdout. |
| `retrieve-secret.sh` | Verbatim vendor of `arne/claude-code-api-key-setup`'s generic Keychain/libsecret/keyctl reader. Provenance in `NOTES.md`. |
| `retrieve-token.sh` | Wraps `retrieve-secret.sh` with the OAuth-token service/account constants from `lib.sh`. Prints the token on stdout, fails fast with a populate-the-Keychain hint on stderr. Token never echoed beyond stdout. |
| `ensure-mvn-cache.sh` | Per-feature mvn cache helper. Creates `runner-mvn-cache-<slug>` on first use (and chowns it to uid 1000 so the non-root container can write); idempotent on re-invocation. Prints the volume name on stdout. |
| `lib.sh` | Shared constants (network, bridge, subnet, iptables chain, OAuth keychain coords, mvn-cache prefix, container `~/.m2` path) and the helpers that derive the per-consumer image name (`runner_image_name`) and the `runner/` context hash (`runner_context_hash`). Source of truth for the names below. |
| `NOTES.md` | Provenance of vendored files (currently `retrieve-secret.sh`). Re-vendor instructions live there. |
| `tests/` | `bats` suite covering `tracker-snapshot` (including `--list`), the runner's pure-logic functions (`classify_outcome`, `next_eligible_ref`, `next_eligible_feature`, `classify_item_action`, `walk_post_implement_steps`, `propagate_feature`, `format_multi_feature_summary_md`), the outer drain loop (`run_drain`, `drain_one_feature`), and `run_loop` mechanics (drain / interrupt / abort-flag skipping / feature-gate refusals) with mocked dispatch. Real-Docker exercising is the job of slice 08's smoke test. |
| `tests/fixtures/synthetic-drain/` | Two-issue micro-feature template the maintainer installs into `.features/synthetic-drain/` for the loop's live demo. Reused by slice 08. See its README for the runbook. |

## Stable Docker asset names

The network, bridge, subnet and iptables chain are shared by every consumer on
the host and have fixed names. The image is per-consumer (see
[Per-consumer image name](#per-consumer-image-name)). The Linux bridge
interface name is shorter to fit `IFNAMSIZ` (15 chars). All values live in
`lib.sh`.

| Asset | Name |
|-------|------|
| Image | `formann-runner-<dir>-<pathhash>` (per consumer) |
| Docker network | `afk-runner-sandbox` |
| Linux bridge interface | `afk-rnr-br0` |
| Bridge subnet | `192.168.219.0/24` |
| iptables chain | `AFK-RUNNER-SANDBOX-FW` |

## Network policy

The bridge gives sandboxed containers public-internet access while denying
outbound traffic to private (RFC1918) destinations:

- `10.0.0.0/8` — corporate / VPN ranges.
- `172.16.0.0/12` — common LAN range, also Docker's default bridge subnets.
- `192.168.0.0/16` — common home LAN range.

Implementation: `setup-network.sh` creates the bridge, then runs a
privileged sidecar (`alpine` with `iptables`) on the Docker host network
namespace to install rules in a dedicated chain that `DOCKER-USER` jumps to
for packets arriving on `afk-rnr-br0`. Intra-bridge traffic (the bridge's
own subnet) is allowed before the deny rules so containers can still talk
to each other.

The rules persist for as long as the Docker daemon's iptables state is
intact. After a Docker Desktop restart they are cleared; re-running
`setup-network.sh` re-applies them.

## OAuth token

The runner needs a long-lived Claude Code OAuth token to dispatch
`/implement` inside the sandbox. The token lives in macOS Keychain (or
libsecret/keyctl on Linux); `retrieve-token.sh` reads it at dispatch
time into a shell variable that is passed to `docker run --env-file
<(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN")` — a bash process
substitution (kernel pipe, no on-disk file) — and never written anywhere
else. This keeps the token out of `docker run`'s argv and
`/proc/<pid>/cmdline`. The only residual exposure is the `$TOKEN` bash
variable in the runner's own process environment, readable as
`/proc/<runner-pid>/environ` by the same Unix UID for the duration of a
dispatch.

One-time setup:

```sh
claude setup-token   # follow the URL; copy the printed long-lived token
```

Then store the printed token under service `claude-code-oauth`, account
`anthropic`, in whichever backend your OS uses:

```sh
# macOS Keychain (paste the token at the prompt; add -U to overwrite)
security add-generic-password -s claude-code-oauth -a anthropic -w

# Linux — libsecret (GNOME Keyring, KWallet, …)
secret-tool store --label=claude-code-oauth service claude-code-oauth account anthropic

# Linux — kernel keyring (fallback when libsecret isn't available)
keyctl padd user claude_code_oauth_anthropic @s   # type/paste the token, then Ctrl-D
```

The service/account live in `lib.sh` as
`RUNNER_OAUTH_KEYCHAIN_SERVICE` / `RUNNER_OAUTH_KEYCHAIN_ACCOUNT`. The
token is valid for ~1 year; rotate by re-running `claude setup-token`
and overwriting the entry (e.g. `security ... -U` on macOS, re-run
`secret-tool store` or `keyctl padd` on Linux).

### Alternate accounts

Both coordinates are env-overridable at invoke time, so a second
long-lived token (e.g. another Anthropic account for when the primary's
usage window is exhausted) can be stored under a different account name
and selected per run without editing anything:

```sh
# one-time: store the second account's token
security add-generic-password -s claude-code-oauth -a <alt-account-name> -w

# per run: select it
RUNNER_OAUTH_KEYCHAIN_ACCOUNT=<alt-account-name> run-the-queue.sh --feature <slug> …
```

Plain invocations keep using the default `anthropic` entry.

## Per-consumer image name

Each consumer gets its own image, so two consumer repos on one host, each with
its own `runner/Dockerfile`, never run in each other's image. The default name
is `formann-runner-<dir>-<pathhash>`:

- `<dir>` is the basename of the consumer root (the `.formann` ancestor),
  lowercased and cleaned to Docker's tag rules: anything outside
  `[a-z0-9._-]` becomes `-`, runs of separators collapse to one `-`, edge
  separators are stripped, and the result is cut to 40 characters. A basename
  that cleans to nothing leaves `formann-runner-<pathhash>`.
- `<pathhash>` is the first 8 hex characters of the SHA-256 of the consumer
  root's physical path (symlinks resolved), so one checkout always yields one
  name and two checkouts with the same basename yield different ones.

`build-image.sh` and the runner resolve the name the same way, so the image
built is the image dispatched in. `RUNNER_IMAGE_NAME`, when set, overrides the
default:

```sh
# build and run against a named image instead of the per-consumer default
RUNNER_IMAGE_NAME=my-project-runner .formann/runner/build-image.sh
RUNNER_IMAGE_NAME=my-project-runner .formann/runner/run-the-queue.sh --feature <slug> …
```

### When the image is rebuilt

Every build labels the image `formann.runner.context-hash` with a SHA-256 over
everything under `<consumer>/runner/` (each file's relative path, content and
executable bit; a symlink is hashed by its target path, not followed).
`build-image.sh` builds when:

- no image exists under the name (a consumer's first run);
- the image's label differs from the current hash, i.e. a file under `runner/`
  was edited, added, removed, renamed or had its executable bit flipped; or
- `--rebuild` or `--fresh` is given.

Only `--fresh` bypasses the layer cache (and re-pulls the base image), so an
unchanged recipe costs nothing otherwise. With no change and no flag,
pre-flight builds nothing. Tool freshness without a `runner/` change (apt
packages, the JDK, the Claude CLI) stays `--fresh`'s job.

The runner records the image it dispatched in as one line of `runner.log`,
right after the image pre-flight check: `Runner image: <name> (context-hash
<12 hex>)`. The hash is read from the image itself.

A pre-existing `afk-runner-sandbox` image is left alone; each consumer builds
its own on its first run. The bridge network, bridge interface and subnet are
unaffected; consumers share those by design.

## Per-feature mvn cache

Each feature gets its own Docker volume (`runner-mvn-cache-<slug>`) so a
slow, dependency-heavy first build doesn't pay full price every
dispatch. `ensure-mvn-cache.sh <slug>` creates the volume on first use
(initialising ownership for the non-root `runner` user) and is
idempotent thereafter; the volume mounts at
`$RUNNER_CONTAINER_M2_PATH` (`/home/runner/.m2`) inside the container.

## Verification recipe

The runner script in slice 04 invokes these helpers automatically. To
verify them by hand:

```sh
# Build the image if it is missing or runner/ has changed since it was built.
# Run from anywhere inside the consumer repo; the script locates the consumer
# root via the .formann indirection symlink and prints the image name.
IMG="$(.formann/runner/build-image.sh)"
# .formann/runner/build-image.sh --rebuild   # rebuild, reusing the layer cache
# .formann/runner/build-image.sh --fresh     # rebuild from scratch; re-resolves
#                                             # every tool (incl. the Claude CLI)
#                                             # to its current published version

# Create the sandbox network and apply the deny-RFC1918 policy.
.formann/runner/setup-network.sh

# Sanity-check the image:
docker run --rm "$IMG" id          # uid=1000(runner) ...
docker run --rm "$IMG" mvn --version
docker run --rm "$IMG" claude --version

# Sanity-check the network policy:
docker run --rm --network afk-runner-sandbox "$IMG" \
  curl -sSf -m 10 -o /dev/null https://repo.maven.apache.org && echo PUBLIC_OK
docker run --rm --network afk-runner-sandbox "$IMG" \
  curl -sS -m 5 -o /dev/null http://10.0.0.1 && echo LEAK || echo BLOCKED
```

## Token argv leakage probe

To verify that the OAuth token is absent from all process arguments while a
dispatch is in flight, run this probe in a second terminal during an active
dispatch:

```sh
# Probe: token must NOT appear in any process argv on the host.
# Run while a dispatch is in flight (the docker run is running in another terminal).
ps -eo pid,args | grep CLAUDE_CODE_OAUTH_TOKEN | grep -v grep && echo "LEAK DETECTED" || echo "argv clean"
```

Expected result: `argv clean` — the token value is delivered to the container
via a kernel pipe (process substitution), not via `docker run`'s command-line
arguments.

On Linux you can also confirm via `/proc`:

```sh
# Check every process's cmdline for the token string (requires same UID).
for f in /proc/*/cmdline; do
  tr '\0' ' ' < "$f" 2>/dev/null
done | grep -F CLAUDE_CODE_OAUTH_TOKEN && echo "LEAK" || echo "argv clean"
```

## Smoke test

The `bats` suite under `tests/` covers pure-logic surfaces with mocked
dispatch. To exercise the *real* path — image, network policy, token
passing, dispatch container, classifier, fast-forward — there's a
guarded end-to-end smoke test that drains a synthetic single-issue
micro-feature in a throwaway workspace.

Slow (~1–2 min) and expensive, so opt in via the `RUNNER_SMOKE` env
var. Default `bats` invocations skip it.

```sh
# Default — pure-logic suite only (smoke test reports as 'skipped'):
bats framework/runner/tests/

# Opt-in — runs the smoke test too:
RUNNER_SMOKE=1 bats framework/runner/tests/smoke.bats
```

Run it manually before milestones — anytime something the unit suite
can't see might have drifted:

- Consumer Dockerfile changes (`<consumer>/runner/Dockerfile`, scaffolded by the installer; edited per consumer).
- `setup-network.sh` changes (RFC1918 deny list, bridge config).
- Bumps to the bundled `claude` CLI (`@anthropic-ai/claude-code` in
  the Dockerfile).
- Token-passing or Keychain changes (`retrieve-secret.sh`,
  `retrieve-token.sh`).
- Pre-flight or dispatch loop changes in `run-the-queue.sh`.
- `tracker-snapshot` contract changes (binding-doc revisions or
  fixture migrations).

Pre-requisites: Docker Desktop running, the OAuth token populated in
Keychain (see "OAuth token" above). Fixture lives at
`tests/fixtures/smoke/` with a manual-reproduction recipe in its
README. Per-feature mvn cache is `runner-mvn-cache-smoke` (persists
across smoke runs; remove with `docker volume rm runner-mvn-cache-smoke`).

## Captured smoke runs

Operator-attended walks against fixtures under `tests/fixtures/` that
cannot run inside the AFK runner's dispatch container (no
Docker-in-Docker) leave intermediate per-walk artifacts under
`.runner-state/smoke-runs/` (gitignored, ephemeral). The durable record
of what was walked and observed lives in the issue's Implementation /
Verification comments; the artifact is scratch the verifier reads during
the walk.
