#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Post-drain phase (post-drain.sh, #10): host-side steps named in the
# consumer's `runner/post-drain.md`, run once a feature has drained, while
# the runner still holds the feature's Claim.
#
# The drain is driven through the real drain_one_feature / run_claimed_loop
# with a bare repository as the Shared remote; the per-issue loop, the
# snapshot and the mvn cache are stood in for, so no docker runs. Steps are
# real host processes.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER_SCRIPT="$HERE/../run-the-queue.sh"
  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_SCRIPT"
  RUNNER_DISABLE_LIVENESS=1
  unset RUNNER_SHARED_REMOTE RUNNER_FORMANN_SHA RUNNER_HOST_CLAUDE ARG_MODEL

  HOST_REPO="$BATS_TEST_TMPDIR/host"
  git init --quiet --initial-branch=main "$HOST_REPO"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m init
  SHARED="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$SHARED"
  git -C "$HOST_REPO" remote add origin "$SHARED"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  git init --quiet --initial-branch=main "$HOST_CHECKOUT"
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m init
  HOST_ABORT_DIR="$HOST_REPO/.runner-state/aborted"
  HOST_BLOCKED_DIR="$HOST_REPO/.runner-state/blocked"
  mkdir -p "$HOST_ABORT_DIR" "$HOST_REPO/runner"
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN_DIR"
  RUN_TS="20261108-120000"
  RUN_MODE="drain"
  RUN_LOG_LAYOUT="nested"
  RUN_PASS_DIR=""
  RUNNER_MACHINE="m1"
  RUNNER_INTERRUPTED=0
  RUNNER_CLAIM_LOST=""
  CLAIM_HELD_FEATURE=""
  CLAIM_HELD_SHA=""
  RUN_DISPATCHES=()
  RUN_FEATURE_OUTCOMES=()
  RUN_POST_DRAIN=()
  RUN_STOP_REASON=""
  RESOLVED_POST_DRAIN=""

  # Recorded by the step stand-ins.
  STEPS_FILE="$BATS_TEST_TMPDIR/steps"
  : >"$STEPS_FILE"
  LOOPS_FILE="$BATS_TEST_TMPDIR/loops"
  : >"$LOOPS_FILE"

  # The tracker: every issue done unless a test plants another snapshot.
  SNAP_FILE="$BATS_TEST_TMPDIR/snap.json"
  snapshot_with '[{"ref":"#1","nn":"01","status":"done","type":"AFK","blocked_by":[],"eligible":false}]'
  # The drain gate's snapshot (the first of each drain) shows the issue still
  # eligible, as before its dispatch; every later one reads $SNAP_FILE. Set
  # GATE_ELIGIBLE=0 for a gate that sees the plain $SNAP_FILE too.
  GATE_ELIGIBLE=1
  SNAP_CALLS_FILE="$BATS_TEST_TMPDIR/snap-calls"
  : >"$SNAP_CALLS_FILE"
  take_snapshot() {
    echo x >>"$SNAP_CALLS_FILE"
    if [ "$GATE_ELIGIBLE" -eq 1 ] && [ "$(wc -l <"$SNAP_CALLS_FILE" | tr -d ' ')" = "1" ]; then
      printf '{"feature":"alpha","issues":[{"ref":"#1","nn":"01","status":"ready-for-agent","type":"AFK","blocked_by":[],"eligible":true}]}'
      return 0
    fi
    cat "$SNAP_FILE"
  }
  # A new drain starts with the gate again.
  _real_drain_one_feature="$(declare -f drain_one_feature)"
  eval "${_real_drain_one_feature/drain_one_feature/_drain_one_feature_real}"
  drain_one_feature() { : >"$SNAP_CALLS_FILE"; _drain_one_feature_real "$@"; }
  ensure_runner_checkout_on_branch() { return 0; }
  ensure_mvn_cache_for() { MVN_VOLUME="v"; return 0; }
  post_claim_note() { return 0; }

  # The per-issue loop: one dispatch, then the queue is empty. Set
  # LOOP_DISPATCHES=0 for a loop that finds nothing to do.
  LOOP_DISPATCHES=1
  run_loop() {
    echo "$TARGET_FEATURE" >>"$LOOPS_FILE"
    if [ "$LOOP_DISPATCHES" -gt 0 ]; then
      record_dispatch "$TARGET_FEATURE" "01" "#1" "done" 5
    fi
    RUN_STOP_REASON="${LOOP_STOP_REASON:-queue-empty}"
    return 0
  }
}

snapshot_with() {
  printf '{"feature":"alpha","issues":%s}' "$1" >"$SNAP_FILE"
}

# Write a consumer step script runner/<name> with body $2; make it executable.
consumer_step() {
  local name="$1" body="$2"
  mkdir -p "$(dirname "$HOST_REPO/runner/$name")"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$HOST_REPO/runner/$name"
  chmod +x "$HOST_REPO/runner/$name"
}

# Write runner/post-drain.md with the given lines and resolve it as pre-flight
# would.
post_drain_manifest() {
  printf '# Post-drain steps.\n' >"$HOST_REPO/runner/post-drain.md"
  printf '%s\n' "$@" >>"$HOST_REPO/runner/post-drain.md"
  check_post_drain_manifest
}

claim_sha() {
  git -C "$SHARED" rev-parse --verify --quiet "refs/formann/claims/$1" || true
}

# === Manifest resolution =====================================================

@test "resolve_post_drain_manifest — no manifest anywhere: no steps, success" {
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$BATS_TEST_TMPDIR/fw" "$BATS_TEST_TMPDIR/fw/steps"
  assert_success
  assert_output ""
}

@test "resolve_post_drain_manifest — the framework ships no post-drain manifest" {
  [ ! -e "$HERE/../post-drain.md" ]
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$HERE/.." "$HERE/../steps"
  assert_success
  assert_output ""
}

@test "resolve_post_drain_manifest — comments and blank lines only: no steps" {
  printf '# nothing yet\n\n   \n' >"$HOST_REPO/runner/post-drain.md"
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$BATS_TEST_TMPDIR/fw" "$BATS_TEST_TMPDIR/fw/steps"
  assert_success
  assert_output ""
}

@test "resolve_post_drain_manifest — entries resolve in the consumer's runner/ first, then the framework steps root" {
  local fw="$BATS_TEST_TMPDIR/fw"
  mkdir -p "$fw/steps"
  printf 'fw\n' >"$fw/steps/review-branch.md"
  printf 'fw\n' >"$fw/steps/open-pr.md"
  printf 'consumer\n' >"$HOST_REPO/runner/open-pr.md"
  consumer_step "scripts/push-tag.sh" "true"
  printf 'review-branch.md\nopen-pr.md\nscripts/push-tag.sh\n' >"$HOST_REPO/runner/post-drain.md"

  run resolve_post_drain_manifest "$HOST_REPO/runner" "$fw" "$fw/steps"
  assert_success
  assert_line --index 0 "review-branch	$fw/steps/review-branch.md"
  assert_line --index 1 "open-pr	$HOST_REPO/runner/open-pr.md"
  assert_line --index 2 "push-tag.sh	$HOST_REPO/runner/scripts/push-tag.sh"
}

@test "resolve_post_drain_manifest — the consumer's manifest wins over a framework one" {
  local fw="$BATS_TEST_TMPDIR/fw"
  mkdir -p "$fw/steps"
  printf 'x\n' >"$fw/steps/a.md"
  printf 'x\n' >"$fw/steps/b.md"
  printf 'a.md\n' >"$fw/post-drain.md"
  printf 'b.md\n' >"$HOST_REPO/runner/post-drain.md"
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$fw" "$fw/steps"
  assert_success
  assert_output "b	$fw/steps/b.md"
  rm "$HOST_REPO/runner/post-drain.md"
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$fw" "$fw/steps"
  assert_output "a	$fw/steps/a.md"
}

@test "resolve_post_drain_manifest — an unresolved or traversing entry fails with every diagnostic" {
  printf 'missing.md\n../escape.sh\n' >"$HOST_REPO/runner/post-drain.md"
  run resolve_post_drain_manifest "$HOST_REPO/runner" "$BATS_TEST_TMPDIR/fw" "$BATS_TEST_TMPDIR/fw/steps"
  assert_failure
  assert_output --partial 'unresolved reference "missing.md"'
  assert_output --partial '.. segment not allowed'
}

@test "check_post_drain_manifest — no manifest: RESOLVED_POST_DRAIN empty, no abort" {
  check_post_drain_manifest
  [ -z "$RESOLVED_POST_DRAIN" ]
  [ -z "$RUN_PREFLIGHT_INVARIANT" ]
}

@test "check_post_drain_manifest — an invalid manifest is preflight-abort: post-drain-manifest" {
  printf 'missing.md\n' >"$HOST_REPO/runner/post-drain.md"
  run check_post_drain_manifest
  [ "$status" -ne 0 ]
  assert_output --partial 'post-drain-manifest'
  assert_output --partial 'missing.md'
}

# === Pure helpers ============================================================

@test "classify_post_drain_step — exit 0 ok, non-zero failed, a Blocked line blocked" {
  [ "$(classify_post_drain_step 0 "")" = "ok" ]
  [ "$(classify_post_drain_step 3 "")" = "failed" ]
  [ "$(classify_post_drain_step 3 "gh")" = "failed" ]
  [ "$(classify_post_drain_step 0 "preview service")" = "blocked" ]
}

@test "post_drain_command_blocked_dep — only the last non-blank stdout line counts" {
  local f="$BATS_TEST_TMPDIR/out"
  printf 'working\nBLOCKED:  preview service  \n\n' >"$f"
  [ "$(post_drain_command_blocked_dep "$f")" = "preview service" ]
  printf 'BLOCKED: x\nthen recovered\n' >"$f"
  [ -z "$(post_drain_command_blocked_dep "$f")" ]
}

@test "post_drain_step_kind — .md is a prompt, anything else a command" {
  [ "$(post_drain_step_kind /a/review.md)" = "prompt" ]
  [ "$(post_drain_step_kind /a/open-pr.sh)" = "command" ]
}

@test "feature_has_drained — no eligible issue and none Blocked" {
  local done_snap='{"issues":[{"nn":"01","status":"done","type":"AFK","eligible":false},{"nn":"02","status":"in-review","type":"AFK","eligible":false}]}'
  feature_has_drained alpha "$done_snap"
  # An eligible issue (even one with an abort flag) means not drained.
  ! feature_has_drained alpha '{"issues":[{"nn":"01","status":"ready-for-agent","type":"AFK","eligible":true}]}'
  # A Blocked issue (marker, still in-review) means not drained.
  write_blocked_marker alpha 02 review preview
  ! feature_has_drained alpha "$done_snap"
}

# === The phase in the drain ==================================================

@test "post-drain (#10): a consumer step runs on the host after the feature's last dispatch, in the consumer root, with the host's environment" {
  export HOST_ONLY_SECRET="s3cret"
  consumer_step "open-pr.sh" "printf '%s|%s|%s|%s\n' \"\$1\" \"\$RUNNER_FEATURE\" \"\$PWD\" \"\$HOST_ONLY_SECRET\" >>'$STEPS_FILE'"
  post_drain_manifest "open-pr.sh"

  drain_one_feature alpha

  [ "$(cat "$LOOPS_FILE")" = "alpha" ]
  [ "$(cat "$STEPS_FILE")" = "alpha|alpha|$HOST_REPO|s3cret" ]
  [ "$(drain_outcome alpha)" = "drained" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|open-pr.sh|ok|"*"|alpha/post-drain-01-open-pr.sh.stdout.log" ]]
  [ -f "$RUN_DIR/alpha/post-drain-01-open-pr.sh.stdout.log" ]
}

drain_outcome() {
  local rec
  for rec in "${RUN_FEATURE_OUTCOMES[@]}"; do
    [ "${rec%%|*}" = "$1" ] && { echo "${rec#*|}"; return; }
  done
}

@test "post-drain (#10): host credentials — gh auth status succeeds inside a step when it does on the host" {
  command -v gh >/dev/null || skip "gh not installed on this host"
  gh auth status >/dev/null 2>&1 || skip "gh is not authenticated on this host"
  consumer_step "auth.sh" "gh auth status >/dev/null 2>&1; echo \"rc=\$?\" >>'$STEPS_FILE'"
  post_drain_manifest "auth.sh"

  drain_one_feature alpha

  [ "$(cat "$STEPS_FILE")" = "rc=0" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|auth.sh|ok|"* ]]
}

@test "post-drain (#10): the claim ref exists while the step runs and is gone afterwards" {
  consumer_step "probe.sh" "git -C '$SHARED' rev-parse --verify --quiet refs/formann/claims/alpha >>'$STEPS_FILE' || echo none >>'$STEPS_FILE'"
  post_drain_manifest "probe.sh"

  drain_one_feature alpha

  local seen
  seen="$(cat "$STEPS_FILE")"
  [ "$seen" != "none" ]
  [ -n "$seen" ]
  [ -z "$(claim_sha alpha)" ]
  [ -z "$CLAIM_HELD_FEATURE" ]
}

@test "post-drain (#10): the claim is heart-beaten before each step" {
  consumer_step "one.sh" "git -C '$SHARED' log -1 --format=%B refs/formann/claims/alpha | sed -n 's/^heartbeat: //p' >>'$STEPS_FILE'; sleep 1"
  consumer_step "two.sh" "git -C '$SHARED' log -1 --format=%B refs/formann/claims/alpha | sed -n 's/^heartbeat: //p' >>'$STEPS_FILE'"
  post_drain_manifest "one.sh" "two.sh"

  drain_one_feature alpha

  [ "$(wc -l <"$STEPS_FILE" | tr -d ' ')" = "2" ]
  [ "$(sed -n 1p "$STEPS_FILE")" != "$(sed -n 2p "$STEPS_FILE")" ]
}

@test "post-drain (#10): loop mode (--feature) runs the phase under the claim, then releases it" {
  RUN_MODE="loop"
  RUN_LOG_LAYOUT="flat"
  TARGET_FEATURE="alpha"
  GATE_ELIGIBLE=0
  consumer_step "probe.sh" "git -C '$SHARED' rev-parse --verify --quiet refs/formann/claims/alpha >/dev/null && echo held >>'$STEPS_FILE'"
  post_drain_manifest "probe.sh"

  run_claimed_loop

  [ "$RUN_STOP_REASON" = "queue-empty" ]
  [ "$(cat "$STEPS_FILE")" = "held" ]
  [ -z "$(claim_sha alpha)" ]
  [ -f "$RUN_DIR/post-drain-01-probe.sh.stdout.log" ]
}

@test "post-drain (#10): loop mode without a Shared remote runs the phase too" {
  git -C "$HOST_REPO" remote remove origin
  RUN_MODE="loop"
  RUN_LOG_LAYOUT="flat"
  TARGET_FEATURE="alpha"
  GATE_ELIGIBLE=0
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"

  run_claimed_loop

  [ "$(cat "$STEPS_FILE")" = "ran" ]
}

@test "post-drain (#10): no manifest — no step, no Post-drain section, drained as before" {
  check_post_drain_manifest

  drain_one_feature alpha

  [ "$(drain_outcome alpha)" = "drained" ]
  [ "${#RUN_POST_DRAIN[@]}" = "0" ]
  [ -z "$(format_post_drain_section)" ]
  # Only the gate's snapshot: the phase takes none of its own.
  [ "$(wc -l <"$SNAP_CALLS_FILE" | tr -d ' ')" = "1" ]
  [ -z "$(claim_sha alpha)" ]
  [ ! -d "$HOST_BLOCKED_DIR" ] || [ -z "$(ls -A "$HOST_BLOCKED_DIR")" ]
}

@test "post-drain (#10): no manifest — a stray post-drain marker does not make a queue-empty feature drain" {
  check_post_drain_manifest
  write_blocked_marker alpha post-drain review-branch preview
  snapshot_with '[]'
  GATE_ELIGIBLE=0

  drain_one_feature alpha

  [ "$(drain_outcome alpha)" = "skip:queue-empty" ]
  [ ! -s "$LOOPS_FILE" ]
}

@test "post-drain (#10): a loop that dispatched nothing does not run the phase" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  RUN_MODE="loop"; RUN_LOG_LAYOUT="flat"; TARGET_FEATURE="alpha"; GATE_ELIGIBLE=0
  LOOP_DISPATCHES=0

  run_claimed_loop

  [ ! -s "$STEPS_FILE" ]
}

@test "post-drain (#10): a feature that has not drained (eligible issue left, or one Blocked) does not run the phase" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  snapshot_with '[{"ref":"#2","nn":"02","status":"ready-for-agent","type":"AFK","blocked_by":[],"eligible":true}]'
  # The eligible issue carries an abort flag, so the loop stopped queue-empty.
  mkdir -p "$HOST_ABORT_DIR/alpha"; : >"$HOST_ABORT_DIR/alpha/02"
  RUN_DISPATCHES=("alpha|01|#1|done|5|||")
  maybe_run_post_drain alpha queue-empty 0
  [ ! -s "$STEPS_FILE" ]

  snapshot_with '[{"ref":"#2","nn":"02","status":"in-review","type":"AFK","blocked_by":[],"eligible":false}]'
  write_blocked_marker alpha 02 review preview
  maybe_run_post_drain alpha queue-empty 0
  [ ! -s "$STEPS_FILE" ]

  clear_blocked_marker alpha 02
  maybe_run_post_drain alpha queue-empty 0
  [ "$(cat "$STEPS_FILE")" = "ran" ]
}

@test "post-drain (#10): the phase does not run when the loop stopped for any reason but an empty queue" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  local reason
  for reason in interrupted snapshot-failed publish-parked fetch-failed "taken-over-by m2"; do
    LOOP_STOP_REASON="$reason"
    drain_one_feature alpha
  done
  [ ! -s "$STEPS_FILE" ]
}

@test "post-drain (#10): a failing step writes an abort flag keyed by its label, stops the phase, and undoes nothing" {
  consumer_step "review-branch.sh" "echo reviewing; exit 4"
  consumer_step "open-pr.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "review-branch.sh" "open-pr.sh"

  drain_one_feature alpha

  local flag="$HOST_ABORT_DIR/alpha/post-drain-review-branch.sh"
  [ -f "$flag" ]
  grep -qx 'dispatch: post-drain:review-branch.sh' "$flag"
  grep -qx 'exit: 4' "$flag"
  [ ! -s "$STEPS_FILE" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|review-branch.sh|failed (exit 4)|"* ]]
  [ "${#RUN_POST_DRAIN[@]}" = "1" ]
  # The dispatch stays recorded; the feature still drained.
  [ "${#RUN_DISPATCHES[@]}" = "1" ]
  [ "$(drain_outcome alpha)" = "drained" ]
  [ -z "$(claim_sha alpha)" ]

  # While the flag exists, a later phase stops at that step.
  RUN_POST_DRAIN=()
  drain_one_feature alpha
  [ ! -s "$STEPS_FILE" ]
  [ "${RUN_POST_DRAIN[0]}" = "alpha|review-branch.sh|skipped (aborted)|0|" ]
}

@test "post-drain (#10): a non-executable command step fails with an abort flag" {
  printf 'echo hi\n' >"$HOST_REPO/runner/plain.sh"
  post_drain_manifest "plain.sh"

  drain_one_feature alpha 2>/dev/null

  [ -f "$HOST_ABORT_DIR/alpha/post-drain-plain.sh" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|plain.sh|failed (exit 126)|"* ]]
}

@test "post-drain (#10): a Blocked step stops the phase with no abort flag; the next pass claims the feature and re-runs from that step" {
  local gate="$BATS_TEST_TMPDIR/preview-up"
  consumer_step "first.sh" "echo first >>'$STEPS_FILE'"
  consumer_step "review-branch.sh" "if [ -f '$gate' ]; then echo review >>'$STEPS_FILE'; else echo 'BLOCKED: preview service'; fi"
  consumer_step "open-pr.sh" "echo pr >>'$STEPS_FILE'"
  post_drain_manifest "first.sh" "review-branch.sh" "open-pr.sh"

  drain_one_feature alpha

  [ "$(cat "$STEPS_FILE")" = "first" ]
  [[ "${RUN_POST_DRAIN[1]}" == "alpha|review-branch.sh|blocked (preview service)|"* ]]
  [ ! -e "$HOST_ABORT_DIR/alpha/post-drain-review-branch.sh" ]
  [ "$(post_drain_pending_step alpha)" = "review-branch.sh" ]
  [ -z "$(claim_sha alpha)" ]

  # Next pass: nothing to dispatch, but the pending step makes the feature
  # worth claiming; the phase resumes from the Blocked step.
  : >"$STEPS_FILE"
  : >"$gate"
  LOOP_DISPATCHES=0
  GATE_ELIGIBLE=0
  RUN_POST_DRAIN=()
  RUN_FEATURE_OUTCOMES=()
  snapshot_with '[{"ref":"#1","nn":"01","status":"done","type":"AFK","blocked_by":[],"eligible":false}]'
  drain_one_feature alpha

  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "review pr " ]
  [ -z "$(post_drain_pending_step alpha)" ]
  [ -z "$(claim_sha alpha)" ]
}

@test "post-drain (#10): a prompt step runs claude -p on the host with the prompt and the feature; a closing BLOCKED line is Blocked" {
  local fake="$BATS_TEST_TMPDIR/claude"
  cat >"$fake" <<SCRIPT
#!/usr/bin/env bash
printf '%s\n' "\$2" >>'$STEPS_FILE'
if grep -q blockme <<<"\$2"; then res='done\nBLOCKED: github'; else res='reviewed'; fi
printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "\$res"
SCRIPT
  chmod +x "$fake"
  RUNNER_HOST_CLAUDE="$fake"
  printf 'Review the whole branch.\n' >"$HOST_REPO/runner/review-branch.md"
  post_drain_manifest "review-branch.md"

  drain_one_feature alpha

  [ "$(sed -n 1p "$STEPS_FILE")" = "Review the whole branch." ]
  [ "$(sed -n 2p "$STEPS_FILE")" = "alpha" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|review-branch|ok|"*"|alpha/post-drain-01-review-branch.stdout.jsonl" ]]
  [ "$(cat "$RUN_DIR/alpha/post-drain-01-review-branch.summary.md")" = "reviewed" ]

  printf 'blockme\n' >"$HOST_REPO/runner/review-branch.md"
  RUN_POST_DRAIN=()
  drain_one_feature alpha
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|review-branch|blocked (github)|"* ]]
}

@test "post-drain (#10): a prompt step with no clean result event fails" {
  local fake="$BATS_TEST_TMPDIR/claude"
  printf '#!/usr/bin/env bash\nprintf %s\\\\n "{\\"type\\":\\"result\\",\\"is_error\\":true,\\"result\\":\\"x\\"}"\n' >"$fake"
  chmod +x "$fake"
  RUNNER_HOST_CLAUDE="$fake"
  printf 'p\n' >"$HOST_REPO/runner/review-branch.md"
  post_drain_manifest "review-branch.md"

  drain_one_feature alpha

  [[ "${RUN_POST_DRAIN[0]}" == "alpha|review-branch|failed (exit 1)|"* ]]
  [ -f "$HOST_ABORT_DIR/alpha/post-drain-review-branch" ]
}

# === SUMMARY.md ==============================================================

@test "post-drain (#10): outcomes appear in SUMMARY.md's Post-drain section" {
  consumer_step "review-branch.sh" "true"
  consumer_step "open-pr.sh" "exit 2"
  post_drain_manifest "review-branch.sh" "open-pr.sh"

  drain_one_feature alpha

  local summary
  summary="$( { print_multi_feature_records | format_multi_feature_summary_md \
    "$RUN_TS" "12:00:00" "12:01:00" "ended" "completed"; format_post_drain_section; } )"
  [[ "$summary" == *"## alpha — drained"* ]]
  [[ "$summary" == *"## Post-drain"* ]]
  [[ "$summary" == *"| feature | step | outcome | duration | log |"* ]]
  [[ "$summary" == *"| alpha | review-branch.sh | ok | 0s | [alpha/post-drain-01-review-branch.sh.stdout.log](alpha/post-drain-01-review-branch.sh.stdout.log) |"* ]]
  [[ "$summary" == *"| alpha | open-pr.sh | failed (exit 2) |"* ]]
}

@test "post-drain (#10): finalize_run appends the Post-drain section to the run's SUMMARY.md" {
  consumer_step "review-branch.sh" "true"
  post_drain_manifest "review-branch.sh"
  RUN_START_CLOCK="12:00:00"

  run bash -c "
    source '$RUNNER_SCRIPT'
    HOST_REPO='$HOST_REPO'; HOST_CHECKOUT='$HOST_CHECKOUT'; HOST_ABORT_DIR='$HOST_ABORT_DIR'
    HOST_BLOCKED_DIR='$HOST_BLOCKED_DIR'; RUN_DIR='$RUN_DIR'; RUN_TS='$RUN_TS'
    RUN_START_CLOCK=12:00:00; RUN_MODE=drain; RUN_STOP_REASON=completed
    RUNNER_LOCK_FILE=''; release_lock() { :; }
    RUN_FEATURE_OUTCOMES=('alpha|drained')
    RUN_POST_DRAIN=('alpha|review-branch.sh|ok|3|alpha/post-drain-01-review-branch.sh.stdout.log')
    finalize_run
  "
  grep -q '^## Post-drain$' "$RUN_DIR/SUMMARY.md"
  grep -qF '| alpha | review-branch.sh | ok | 3s |' "$RUN_DIR/SUMMARY.md"
}

@test "post-drain (#10): progress lines name the feature and the step" {
  consumer_step "review-branch.sh" "true"
  post_drain_manifest "review-branch.sh"

  run drain_one_feature alpha

  assert_output --regexp '\] alpha post-drain:review-branch.sh → starting'
  assert_output --regexp '\] alpha post-drain:review-branch.sh → ok \(0s\)'
}
