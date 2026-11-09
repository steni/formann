#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# The runner on its own Formann (#9): run-the-queue.sh fast-forwards
# $RUNNER_FORMANN_DIR to $RUNNER_FORMANN_REF before a drain, re-executes from
# it, refuses to drain when it can't, and records the sha in the claim and
# SUMMARY.md. A bare repository stands in for the Formann remote; the
# runner's own code (this checkout's framework/runner) is what it carries.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  TESTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SRC_RUNNER="$(cd "$TESTS/.." && pwd)"

  unset RUNNER_FORMANN_DIR RUNNER_FORMANN_REF RUNNER_FORMANN_REEXEC \
        RUNNER_FORMANN_SHA RUNNER_SHARED_REMOTE RUNNER_DEFAULT_BRANCH
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  # The Formann remote, carrying this checkout's runner code as v1.
  UPSTREAM="$BATS_TEST_TMPDIR/formann.git"
  git init --quiet --bare --initial-branch=main "$UPSTREAM"
  DEV="$BATS_TEST_TMPDIR/dev"
  git init --quiet --initial-branch=main "$DEV"
  git -C "$DEV" remote add origin "$UPSTREAM"
  mkdir -p "$DEV/framework/runner"
  (cd "$SRC_RUNNER" && tar cf - --exclude=./tests .) | (cd "$DEV/framework/runner" && tar xf -)
  git -C "$DEV" add -A
  git -C "$DEV" commit --quiet -m v1
  git -C "$DEV" push --quiet origin main
  V1="$(git -C "$DEV" rev-parse HEAD)"

  # The sessions' checkout (what `.formann` points at) and the runner's own.
  SESSIONS="$BATS_TEST_TMPDIR/sessions-formann"
  git clone --quiet "$UPSTREAM" "$SESSIONS"
  export RUNNER_FORMANN_DIR="$BATS_TEST_TMPDIR/runner-formann"
  git clone --quiet "$UPSTREAM" "$RUNNER_FORMANN_DIR"

  # A consumer with no tracker: once the Formann step is past, pre-flight
  # stops at `discovery`, before the lock's sibling invariants need Docker.
  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER"
  git init --quiet --initial-branch=main "$CONSUMER"
  ln -s "$SESSIONS/framework" "$CONSUMER/.formann"
}

# Push a new Formann version whose runner announces itself. Prints its sha.
push_marked_version() {
  local marker="$1" f="$DEV/framework/runner/run-the-queue.sh"
  { head -n 1 "$f"; printf 'echo "%s running" >&2\n' "$marker"; tail -n +2 "$f"; } >"$f.new"
  mv "$f.new" "$f"
  chmod +x "$f"
  git -C "$DEV" commit --quiet -am "$marker"
  git -C "$DEV" push --quiet origin main
  git -C "$DEV" rev-parse HEAD
}

# Every path, and every file's bytes, under $1 (its .git included).
tree_digest() {
  (cd "$1" && find . | LC_ALL=C sort | shasum \
    && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum | shasum)
}

latest_summary() {
  local d
  d="$(ls -1d "$CONSUMER/.runner-state/runs/"*/ | tail -n 1)"
  cat "$d/SUMMARY.md"
}

# Start the runner the way a service does: through the sessions' `.formann`.
start_runner() {
  run --separate-stderr bash -c 'cd "$1" && shift && exec bash .formann/runner/run-the-queue.sh --no-caffeinate "$@"' _ "$CONSUMER" "$@"
}

@test "runner-formann — a commit pushed to the configured ref is what the next drain runs, without anyone pulling; the summary shows its sha" {
  local v2
  v2="$(push_marked_version formann-v2)"
  start_runner
  # Past the Formann step, the drain stopped at discovery (no tracker here).
  [ "$status" -eq 2 ] || fail "status $status; stderr: $stderr; stdout: $output"
  [[ "$stderr$output" == *"formann-v2 running"* ]] || fail "the new code did not run: $stderr $output"
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" = "$v2" ]
  local summary
  summary="$(latest_summary)"
  [[ "$summary" == *"- Formann: $v2 (origin/main)"* ]] || fail "$summary"
  [[ "$summary" == *"preflight-abort: discovery"* ]] || fail "$summary"
  grep -q "Formann $v2 (origin/main)" "$(ls -1d "$CONSUMER/.runner-state/runs/"*/ | tail -n 1)/runner.log"
}

@test "runner-formann — already up to date, started from .formann: re-executes from the runner's own checkout, not the sessions'" {
  # Mark only the runner's own checkout's code (a commit there would diverge,
  # so mark the upstream, then pull it into the runner's checkout only).
  local v2
  v2="$(push_marked_version formann-v2)"
  git -C "$RUNNER_FORMANN_DIR" pull --quiet --ff-only
  start_runner
  [ "$status" -eq 2 ] || fail "status $status; stderr: $stderr"
  [[ "$stderr$output" == *"formann-v2 running"* ]] || fail "ran the sessions' code: $stderr $output"
  [[ "$(latest_summary)" == *"- Formann: $v2 (origin/main)"* ]]
}

@test "runner-formann — the sessions' .formann checkout is byte-for-byte unchanged by an update" {
  local before after
  before="$(tree_digest "$SESSIONS")"
  push_marked_version formann-v2 >/dev/null
  start_runner
  [ "$status" -eq 2 ] || fail "status $status; stderr: $stderr"
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" != "$V1" ]
  after="$(tree_digest "$SESSIONS")"
  [ "$before" = "$after" ]
  [ "$(git -C "$SESSIONS" rev-parse HEAD)" = "$V1" ]
}

@test "runner-formann — a local change refuses the drain, naming the cause; no claim is taken" {
  local shared="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$shared"
  git -C "$CONSUMER" remote add origin "$shared"
  push_marked_version formann-v2 >/dev/null
  echo hack >>"$RUNNER_FORMANN_DIR/framework/runner/lib.sh"
  start_runner
  [ "$status" -eq 2 ]
  [[ "$stderr$output" == *"runner-formann: refusing to drain:"*"local changes"*"framework/runner/lib.sh"* ]] \
    || fail "stderr: $stderr"
  [[ "$stderr$output" != *"formann-v2 running"* ]]
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" = "$V1" ]
  [[ "$(latest_summary)" == *"preflight-abort: runner-formann"* ]]
  [ -z "$(git -C "$shared" for-each-ref refs/formann/)" ]
  # Refused before the lock: no pidfile left behind, nothing else ran.
  [ ! -e "$CONSUMER/.runner-state/lock" ]
}

@test "runner-formann — divergence refuses the drain, naming the cause; no claim is taken" {
  local shared="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$shared"
  git -C "$CONSUMER" remote add origin "$shared"
  push_marked_version formann-v2 >/dev/null
  echo "# local" >>"$RUNNER_FORMANN_DIR/framework/runner/lib.sh"
  git -C "$RUNNER_FORMANN_DIR" commit --quiet -am local
  start_runner
  [ "$status" -eq 2 ]
  [[ "$stderr$output" == *"runner-formann: refusing to drain:"*"diverged from origin/main"* ]] \
    || fail "stderr: $stderr"
  [[ "$(latest_summary)" == *"preflight-abort: runner-formann"* ]]
  [ -z "$(git -C "$shared" for-each-ref refs/formann/)" ]
}

@test "runner-formann — an rsync copy in RUNNER_FORMANN_DIR refuses the drain and says to clone" {
  rm -rf "$RUNNER_FORMANN_DIR/.git"
  start_runner
  [ "$status" -eq 2 ]
  [[ "$stderr$output" == *"not a git clone"* ]] || fail "stderr: $stderr"
}

@test "runner-formann — RUNNER_FORMANN_DIR unset: runs where started, updates nothing, records that checkout's sha" {
  unset RUNNER_FORMANN_DIR
  push_marked_version formann-v2 >/dev/null
  start_runner
  [ "$status" -eq 2 ]
  [[ "$stderr$output" != *"formann-v2 running"* ]]
  [[ "$(latest_summary)" == *"- Formann: $V1 (not self-updated: RUNNER_FORMANN_DIR is unset)"* ]]
}

# --- in-process: the claim and the idle loop ----------------------------------

load_runner_from_formann() {
  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_FORMANN_DIR/framework/runner/run-the-queue.sh"
}

@test "runner-formann — the claim commit carries the Formann sha" {
  load_runner_from_formann
  start_runner_formann
  [ "$RUNNER_FORMANN_SHA" = "$V1" ]
  local shared="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$shared"
  git -C "$CONSUMER" remote add origin "$shared"
  HOST_REPO="$CONSUMER" RUNNER_MACHINE=m1 RUN_TS=20261108-120000
  claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "taken" ]
  local msg
  msg="$(git -C "$shared" log -1 --format=%B refs/formann/claims/alpha)"
  [ "$(claim_field "$msg" formann)" = "$V1" ]
}

@test "runner-formann — idle loop: a later pass that finds the ref moved ends the run to re-execute on the new sha" {
  load_runner_from_formann
  start_runner_formann
  RUN_MODE=drain
  refresh_discovery() { return 0; }
  prepare_idle_pass
  [ "$RUNNER_FORMANN_REEXEC_PENDING" -eq 0 ]

  local v2
  v2="$(push_marked_version formann-v2)"
  ! prepare_idle_pass
  [ "$RUN_STOP_REASON" = "formann-updated" ]
  [ "$RUNNER_FORMANN_REEXEC_PENDING" -eq 1 ]
  [ "$RUNNER_FORMANN_NEXT_SHA" = "$v2" ]
  # The run that ends is still the one v1 built.
  [ "$RUNNER_FORMANN_SHA" = "$V1" ]
}

@test "runner-formann — idle loop: a later pass that can't update is skipped as formann-refused, nothing drained" {
  load_runner_from_formann
  start_runner_formann
  RUN_MODE=drain
  refresh_discovery() { echo refreshed >>"$BATS_TEST_TMPDIR/refreshed"; }
  push_marked_version formann-v2 >/dev/null
  echo hack >>"$RUNNER_FORMANN_DIR/framework/runner/lib.sh"
  run prepare_idle_pass
  assert_failure
  assert_output --partial "refusing this pass"
  assert_output --partial "local changes"
  ! prepare_idle_pass >/dev/null
  [ "$RUN_STOP_REASON" = "formann-refused" ]
  [ "$RUNNER_FORMANN_REEXEC_PENDING" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/refreshed" ]
}

@test "runner-formann — idle loop: run_idle ends after a formann-updated pass and finalize_run re-executes with the same arguments" {
  run bash -c '
    source "$1/framework/runner/run-the-queue.sh"
    CNT="$2/count"
    RUNNER_ARGV=(--idle 5 --no-caffeinate)
    RUN_MODE=drain; ARG_IDLE=5; RUN_DIR="$2/run"; mkdir -p "$RUN_DIR"
    HOST_REPO="$2"; HOST_LOCK="$2/lock"
    start_runner_formann
    refresh_discovery() { :; }
    run_drain() { RUN_STOP_REASON=completed; }
    SLEEPS=0
    idle_sleep() { SLEEPS=$((SLEEPS+1)); [ "$SLEEPS" -lt 10 ] || exit 3; }  # a regression must not loop forever
    runner_formann_reexec() { echo "reexec ${RUNNER_ARGV[*]} on $RUNNER_FORMANN_NEXT_SHA"; }
    # Runs in a $(…) subshell: count calls in a file. Pass 2 sees the old
    # sha, pass 3 a new one.
    formann_self_update() {
      local n; n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$CNT"
      if [ "$n" -ge 2 ]; then echo NEWSHA; else echo "$RUNNER_FORMANN_SHA"; fi
    }
    trap finalize_run EXIT
    run_idle run_drain
    echo "stop: $RUN_STOP_REASON"
  ' _ "$RUNNER_FORMANN_DIR" "$BATS_TEST_TMPDIR"
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/count")" = "2" ]
  assert_output --partial "ending the run to re-execute on Formann NEWSHA"
  assert_output --partial "stop: formann-updated"
  assert_output --partial "reexec --idle 5 --no-caffeinate on NEWSHA"
  grep -q 'Stop reason: formann-updated' "$BATS_TEST_TMPDIR/run/SUMMARY.md"
  grep -q -- "- Formann: $V1 (origin/main)" "$BATS_TEST_TMPDIR/run/SUMMARY.md"
}

@test "runner-formann — SUMMARY formatters: a Formann line after the run line when given, none without" {
  load_runner_from_formann
  run format_summary_md f 20261108-120000 12:00 12:05 ended queue-empty "" "abc123 (origin/main)" </dev/null
  # `lines` drops blank lines: title, run, Formann, stop reason.
  assert_line --index 1 -- "- Run: 20261108-120000 (started 12:00, ended 12:05)"
  assert_line --index 2 -- "- Formann: abc123 (origin/main)"
  run format_multi_feature_summary_md 20261108-120000 12:00 12:05 ended completed "" "abc123 (origin/main)" </dev/null
  assert_line --index 2 -- "- Formann: abc123 (origin/main)"
  run format_preflight_summary_md f 20261108-120000 12:00 12:05 discovery "abc123 (origin/main)"
  assert_line --index 2 -- "- Formann: abc123 (origin/main)"
  run format_summary_md f 20261108-120000 12:00 12:05 ended queue-empty </dev/null
  refute_output --partial "Formann"
}
