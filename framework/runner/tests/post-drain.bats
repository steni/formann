#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Post-drain phase (post-drain.sh, #10, #38): host-side steps named in the
# consumer's `runner/post-drain.md`, run while the runner holds the feature's
# Claim, whenever the Post-drain due rule says the finished feature is due;
# how the phase ended is a Post-drain mark on the Shared remote.
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
  DISCOVERY_JSON='["alpha"]'
  POST_DRAIN_MARKS_SEEN_FEATURE=""

  # The feature's branch on the Shared remote: its tip is what a mark records.
  git -C "$HOST_REPO" push --quiet origin main:refs/heads/alpha

  # The binding's comment verbs: comment-on-feature appends the comment to
  # $COMMENTS_FILE and prints the parent's ref (`--locate` only prints it);
  # blocked-passes counts the parent's Blocked comments there since the
  # latest Post-drain comment. With $COMMIT_COMMENTS_FLAG present, every
  # comment is also a commit on alpha's branch on the Shared remote — what a
  # local-markdown comment is once post_feature_comment has propagated it.
  COMMENTS_FILE="$BATS_TEST_TMPDIR/comments"
  : >"$COMMENTS_FILE"
  COMMIT_COMMENTS_FLAG="$BATS_TEST_TMPDIR/comments-commit"
  local bdir="$HOST_REPO/docs/formann/issue-tracker"
  mkdir -p "$bdir"
  cat >"$bdir/comment-on-feature" <<SCRIPT
#!/usr/bin/env bash
[ "\$1" = "--locate" ] && { echo '#7'; exit 0; }
{ printf '=== %s %s\n' "\$1" "\$2"; cat; } >>'$COMMENTS_FILE'
if [ -f '$COMMIT_COMMENTS_FLAG' ]; then
  tip="\$(git -C '$SHARED' rev-parse refs/heads/\$1)"
  new="\$(git -C '$SHARED' -c user.email=t@t -c user.name=t commit-tree -p "\$tip" -m "tracker: \$2 on \$1" "\$(git -C '$SHARED' mktree </dev/null)")"
  git -C '$SHARED' update-ref "refs/heads/\$1" "\$new" "\$tip"
fi
echo '#7'
SCRIPT
  cat >"$bdir/blocked-passes" <<SCRIPT
#!/usr/bin/env bash
[ "\$1" = "#7" ] || { echo "blocked-passes: unexpected ref \$1" >&2; exit 2; }
awk '/^=== alpha Post-drain\$/ { n = 0 } /^=== alpha Blocked\$/ { n++ } END { print n + 0 }' '$COMMENTS_FILE'
SCRIPT
  chmod +x "$bdir/comment-on-feature" "$bdir/blocked-passes"

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

# The feature's tip and its marks on the Shared remote.
alpha_tip() {
  git -C "$SHARED" rev-parse --verify --quiet refs/heads/alpha || true
}
ok_mark() {
  git -C "$SHARED" rev-parse --verify --quiet "refs/formann/post-drained/$1" || true
}
failed_mark() {
  git -C "$SHARED" rev-parse --verify --quiet "refs/formann/post-drain-failed/$1" || true
}

# A new commit on the feature branch of the Shared remote (the maintainer's
# fix, a reworked issue). Prints the new tip.
advance_tip() {
  local new
  new="$(git -C "$HOST_REPO" -c user.email=t@t -c user.name=t commit-tree \
    -p "$(alpha_tip)" -m "next" "$(git -C "$HOST_REPO" mktree </dev/null)")"
  git -C "$HOST_REPO" push --quiet origin "$new:refs/heads/alpha"
  printf '%s\n' "$new"
}

# Comments of a kind posted on alpha's parent.
comments_of() {
  grep -c "^=== alpha $1\$" "$COMMENTS_FILE" || true
}

# The text of every comment of a kind on alpha's parent.
comment_text_of() {
  awk -v want="=== alpha $1" '/^=== / { on = ($0 == want); next } on' "$COMMENTS_FILE"
}

# One drain pass with the binding listing no feature as eligible: whatever
# runs, runs because the finished feature is due. The gate snapshot shows
# the plain $SNAP_FILE (every issue done).
finished_pass() {
  GATE_ELIGIBLE=0
  LOOP_DISPATCHES=0
  RUN_FEATURE_OUTCOMES=()
  RUN_POST_DRAIN=()
  RUN_STOP_REASON=""
  eligible_features_check() { ELIGIBLE_FEATURES_JSON='[]'; }
  : >"$SNAP_CALLS_FILE"
  run_drain
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

# === The due rule ============================================================

snap_of() {
  local s out='{"feature":"alpha","issues":['
  local sep=""
  for s in "$@"; do
    out="$out$sep{\"ref\":\"#1\",\"nn\":\"01\",\"status\":\"$s\",\"type\":\"AFK\",\"eligible\":false}"
    sep=","
  done
  printf '%s]}' "$out"
}

@test "post_drain_due — every issue done or wontfix and no mark at the tip: due" {
  [ "$(post_drain_due "$(snap_of done)" "" "" T1)" = "due" ]
  [ "$(post_drain_due "$(snap_of done wontfix done)" "" "" T1)" = "due" ]
  [ "$(post_drain_due "$(snap_of wontfix)" "" "" T1)" = "due" ]
}

@test "post_drain_due — any issue not done or wontfix: not-due" {
  local st
  for st in in-review ready-for-agent ready-for-human needs-info needs-triage; do
    [ "$(post_drain_due "$(snap_of done "$st")" "" "" T1)" = "not-due" ] || fail "$st should be not-due"
    [ "$(post_drain_due "$(snap_of "$st")" "" "" T1)" = "not-due" ] || fail "$st alone should be not-due"
  done
}

@test "post_drain_due — the ok mark or the failed mark at the tip: not-due" {
  [ "$(post_drain_due "$(snap_of done)" T1 "" T1)" = "not-due" ]
  [ "$(post_drain_due "$(snap_of done)" "" T1 T1)" = "not-due" ]
  [ "$(post_drain_due "$(snap_of done)" T1 T1 T1)" = "not-due" ]
}

@test "post_drain_due — either mark at an older tip: due" {
  [ "$(post_drain_due "$(snap_of done)" T0 "" T1)" = "due" ]
  [ "$(post_drain_due "$(snap_of done)" "" T0 T1)" = "due" ]
  [ "$(post_drain_due "$(snap_of done)" T0 T0 T1)" = "due" ]
}

@test "post_drain_due — no tip, or no issue at all: not-due" {
  [ "$(post_drain_due "$(snap_of done)" "" "" "")" = "not-due" ]
  [ "$(post_drain_due '{"feature":"alpha","issues":[]}' "" "" T1)" = "not-due" ]
}

@test "post_drain_due — does no I/O: no git, no tracker, no file, from anywhere" {
  local bin="$BATS_TEST_TMPDIR/only-jq"
  mkdir -p "$bin"
  ln -s "$(command -v jq)" "$bin/jq"
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  # Only jq (to parse the snapshot it is given) on PATH, an empty working
  # directory, no host repo, no remote: the verdicts are unchanged.
  run env -i PATH="$bin" HOME="$empty" /bin/bash -c "
    cd '$empty'
    source '${RUNNER_SCRIPT%/*}/post-drain.sh'
    HOST_REPO=/nonexistent
    post_drain_due '$(snap_of done wontfix)' '' '' T1
    post_drain_due '$(snap_of done in-review)' '' '' T1
    post_drain_due '$(snap_of done)' T1 '' T1
    post_drain_due '$(snap_of done)' T0 T0 T1
  "
  assert_success
  assert_output "$(printf 'due\nnot-due\nnot-due\ndue')"
  [ -z "$(ls -A "$empty")" ]
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

  git -C "$HOST_REPO" branch alpha main
  run_claimed_loop

  [ "$(cat "$STEPS_FILE")" = "ran" ]
  [ "$(git -C "$HOST_REPO" rev-parse refs/formann/post-drained/alpha)" = "$(git -C "$HOST_REPO" rev-parse alpha)" ]
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

@test "post-drain (#38): loop mode runs the phase of a finished feature even when the loop dispatched nothing" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  RUN_MODE="loop"; RUN_LOG_LAYOUT="flat"; TARGET_FEATURE="alpha"; GATE_ELIGIBLE=0
  LOOP_DISPATCHES=0

  run_claimed_loop

  [ "$(cat "$STEPS_FILE")" = "ran" ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ -z "$(claim_sha alpha)" ]

  # The next loop pass finds the ok mark at the tip: no step, no snapshot.
  : >"$SNAP_CALLS_FILE"
  run_claimed_loop
  [ "$(cat "$STEPS_FILE")" = "ran" ]
  [ ! -s "$SNAP_CALLS_FILE" ]
}

@test "post-drain (#38): an unfinished feature (an issue not done or wontfix) does not run the phase" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  local st
  for st in ready-for-agent in-review ready-for-human needs-info needs-triage; do
    snapshot_with "[{\"ref\":\"#1\",\"nn\":\"01\",\"status\":\"done\",\"type\":\"AFK\",\"blocked_by\":[],\"eligible\":false},{\"ref\":\"#2\",\"nn\":\"02\",\"status\":\"$st\",\"type\":\"AFK\",\"blocked_by\":[],\"eligible\":false}]"
    maybe_run_post_drain alpha queue-empty
  done
  [ ! -s "$STEPS_FILE" ]
  [ -z "$(ok_mark alpha)" ]

  snapshot_with '[{"ref":"#1","nn":"01","status":"done","type":"AFK","blocked_by":[],"eligible":false},{"ref":"#2","nn":"02","status":"wontfix","type":"AFK","blocked_by":[],"eligible":false}]'
  maybe_run_post_drain alpha queue-empty
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

@test "post-drain (#38): a failing step sets the failed mark at the tip, posts one Note naming the step and the log, stops the phase, and undoes nothing" {
  consumer_step "review-branch.sh" "echo reviewing; exit 4"
  consumer_step "open-pr.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "review-branch.sh" "open-pr.sh"

  drain_one_feature alpha

  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  [ -z "$(ok_mark alpha)" ]
  [ "$(comments_of Note)" = "1" ]
  grep -qF 'Step: `review-branch.sh`' "$COMMENTS_FILE"
  grep -qF 'Outcome: failed (exit 4)' "$COMMENTS_FILE"
  grep -qF "alpha/post-drain-01-review-branch.sh.stdout.log" "$COMMENTS_FILE"
  grep -qF "Tip: \`$(alpha_tip)\`" "$COMMENTS_FILE"
  # No local abort flag remembers it.
  [ ! -e "$HOST_ABORT_DIR/alpha/post-drain-review-branch.sh" ]
  [ ! -s "$STEPS_FILE" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|review-branch.sh|failed (exit 4)|"* ]]
  [ "${#RUN_POST_DRAIN[@]}" = "1" ]
  # The dispatch stays recorded; the feature still drained.
  [ "${#RUN_DISPATCHES[@]}" = "1" ]
  [ "$(drain_outcome alpha)" = "drained" ]
  [ -z "$(claim_sha alpha)" ]
}

@test "post-drain (#38): a feature at its failed mark is not due; deleting the mark makes it due without a new commit" {
  consumer_step "review-branch.sh" "echo try >>'$STEPS_FILE'; exit 4"
  post_drain_manifest "review-branch.sh"

  finished_pass
  [ "$(cat "$STEPS_FILE")" = "try" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]

  # The next pass does not even snapshot it.
  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ ! -s "$SNAP_CALLS_FILE" ]
  [ "$(cat "$STEPS_FILE")" = "try" ]

  # The maintainer deletes the failed mark: due again, same tip.
  git -C "$HOST_REPO" push --quiet origin :refs/formann/post-drain-failed/alpha
  finished_pass
  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "try try " ]
  [ "$(comments_of Note)" = "2" ]
}

@test "post-drain (#38): a non-executable command step fails: failed mark, no abort flag" {
  printf 'echo hi\n' >"$HOST_REPO/runner/plain.sh"
  post_drain_manifest "plain.sh"

  drain_one_feature alpha 2>/dev/null

  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  [ ! -e "$HOST_ABORT_DIR/alpha/post-drain-plain.sh" ]
  [[ "${RUN_POST_DRAIN[0]}" == "alpha|plain.sh|failed (exit 126)|"* ]]
}

@test "post-drain (#38): a Blocked step posts a Blocked comment and stops; the next pass runs the phase again from its first step" {
  local gate="$BATS_TEST_TMPDIR/preview-up"
  consumer_step "first.sh" "echo first >>'$STEPS_FILE'"
  consumer_step "review-branch.sh" "if [ -f '$gate' ]; then echo review >>'$STEPS_FILE'; else echo 'BLOCKED: preview service'; fi"
  consumer_step "open-pr.sh" "echo pr >>'$STEPS_FILE'"
  post_drain_manifest "first.sh" "review-branch.sh" "open-pr.sh"

  drain_one_feature alpha

  [ "$(cat "$STEPS_FILE")" = "first" ]
  [[ "${RUN_POST_DRAIN[1]}" == "alpha|review-branch.sh|blocked (preview service)|"* ]]
  [ "$(comments_of Blocked)" = "1" ]
  grep -qF 'Post-drain step `review-branch.sh` ended Blocked' "$COMMENTS_FILE"
  grep -qF 'Dependency: preview service' "$COMMENTS_FILE"
  [ -z "$(failed_mark alpha)" ]
  [ -z "$(ok_mark alpha)" ]
  [ ! -e "$HOST_BLOCKED_DIR/alpha/post-drain" ]
  [ -z "$(claim_sha alpha)" ]

  # Next pass: nothing to dispatch, but the finished feature is still due;
  # the phase runs from its first step and ends ok.
  : >"$STEPS_FILE"
  : >"$gate"
  finished_pass

  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "first review pr " ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ -z "$(claim_sha alpha)" ]
}

@test "post-drain (#38): a step Blocked on three consecutive passes posts three Blocked comments, then the failed mark and one Note" {
  consumer_step "review-branch.sh" "echo try >>'$STEPS_FILE'; echo 'BLOCKED: preview service'"
  post_drain_manifest "review-branch.sh"

  finished_pass
  finished_pass
  [ "$(comments_of Blocked)" = "2" ]
  [ -z "$(failed_mark alpha)" ]
  [ "$(comments_of Note)" = "0" ]

  finished_pass
  [ "$(comments_of Blocked)" = "3" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  [ "$(comments_of Note)" = "1" ]
  grep -qF 'Step: `review-branch.sh`' "$COMMENTS_FILE"
  grep -qF 'Outcome: blocked (preview service) on 3 consecutive passes' "$COMMENTS_FILE"
  comment_text_of Note | grep -qF 'Step: `review-branch.sh`'
  comment_text_of Note | grep -qF "alpha/post-drain-01-review-branch.sh.stdout.log"
  # A count at the limit has just failed: no reset comment.
  [ "$(comments_of Post-drain)" = "0" ]

  # Not due any more: the fourth pass runs nothing.
  finished_pass
  [ "$(wc -l <"$STEPS_FILE" | tr -d ' ')" = "3" ]
  [ "$(comments_of Blocked)" = "3" ]
}

@test "post-drain (#38): comments that are commits on the branch — a failing step's failed mark is at the tip after the Note, and the next pass does not run it" {
  : >"$COMMIT_COMMENTS_FLAG"
  consumer_step "review-branch.sh" "echo try >>'$STEPS_FILE'; exit 4"
  post_drain_manifest "review-branch.sh"
  # The claim Note is a commit too.
  post_claim_note() { printf 'claimed\n' | "$HOST_REPO/docs/formann/issue-tracker/comment-on-feature" "$1" Note >/dev/null; }
  local before
  before="$(alpha_tip)"

  finished_pass
  [ "$(cat "$STEPS_FILE")" = "try" ]
  [ "$(alpha_tip)" != "$before" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  # The Note names the tip the step ran at: the one before the Note's commit.
  comment_text_of Note | grep -qF "Tip: \`$(git -C "$SHARED" rev-parse "$(alpha_tip)^")\`"

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ ! -s "$SNAP_CALLS_FILE" ]
  [ "$(cat "$STEPS_FILE")" = "try" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
}

@test "post-drain (#38): comments that are commits on the branch — three Blocked passes end at the failed mark on the final tip, and a fourth pass runs nothing" {
  : >"$COMMIT_COMMENTS_FLAG"
  consumer_step "review-branch.sh" "echo try >>'$STEPS_FILE'; echo 'BLOCKED: preview service'"
  post_drain_manifest "review-branch.sh"

  finished_pass
  finished_pass
  [ "$(comments_of Blocked)" = "2" ]
  [ -z "$(failed_mark alpha)" ]
  finished_pass
  [ "$(comments_of Blocked)" = "3" ]
  [ "$(comments_of Note)" = "1" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ "$(wc -l <"$STEPS_FILE" | tr -d ' ')" = "3" ]
}

@test "post-drain (#38): comments that are commits on the branch — an ok after a Blocked pass posts the reset first, and the ok mark is at the tip after it" {
  : >"$COMMIT_COMMENTS_FLAG"
  local gate="$BATS_TEST_TMPDIR/preview-up"
  consumer_step "review-branch.sh" "[ -f '$gate' ] && echo review >>'$STEPS_FILE' || echo 'BLOCKED: preview service'"
  post_drain_manifest "review-branch.sh"

  finished_pass
  [ "$(comments_of Blocked)" = "1" ]
  : >"$gate"
  finished_pass
  [ "$(cat "$STEPS_FILE")" = "review" ]
  [ "$(comments_of Post-drain)" = "1" ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ "$(cat "$STEPS_FILE")" = "review" ]
}

@test "post-drain (#38): the Blocked count restarts after an ok — two Blocked, ok, then only the third consecutive Blocked pass fails" {
  local gate="$BATS_TEST_TMPDIR/preview-up"
  consumer_step "review-branch.sh" "[ -f '$gate' ] && echo ok >>'$STEPS_FILE' || echo 'BLOCKED: preview service'"
  post_drain_manifest "review-branch.sh"

  finished_pass
  finished_pass
  [ "$(comments_of Blocked)" = "2" ]
  : >"$gate"
  finished_pass
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ "$(comments_of Post-drain)" = "1" ]
  comment_text_of Post-drain | grep -qF "after 2 Blocked pass(es)"

  # A later tip: Blocked again, counted from 1.
  rm "$gate"
  advance_tip >/dev/null
  finished_pass
  advance_tip >/dev/null
  finished_pass
  [ "$(comments_of Blocked)" = "4" ]
  [ -z "$(failed_mark alpha)" ]
  [ "$(comments_of Note)" = "0" ]
  finished_pass
  [ "$(comments_of Blocked)" = "5" ]
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  [ "$(comments_of Note)" = "1" ]
}

@test "post-drain (#38): the Blocked count restarts after a failed step — two Blocked, a failure, then one Blocked pass is not a failure" {
  local mode="$BATS_TEST_TMPDIR/mode"
  echo blocked >"$mode"
  consumer_step "review-branch.sh" "case \$(cat '$mode') in blocked) echo 'BLOCKED: preview service' ;; fail) exit 4 ;; esac"
  post_drain_manifest "review-branch.sh"

  finished_pass
  finished_pass
  echo fail >"$mode"
  finished_pass
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
  [ "$(comments_of Post-drain)" = "1" ]
  [ "$(comments_of Note)" = "1" ]

  echo blocked >"$mode"
  advance_tip >/dev/null
  finished_pass
  [ "$(comments_of Blocked)" = "3" ]
  [ "$(comments_of Note)" = "1" ]
  [ "$(failed_mark alpha)" != "$(alpha_tip)" ]
}

@test "post-drain (#38): a phase that was never Blocked posts no Post-drain comment" {
  consumer_step "step.sh" "true"
  post_drain_manifest "step.sh"
  finished_pass
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ ! -s "$COMMENTS_FILE" ]
}

@test "post-drain (#38): a phase interrupted after its first step re-runs from its first step on the next pass" {
  consumer_step "first.sh" "echo first >>'$STEPS_FILE'"
  consumer_step "second.sh" "echo second >>'$STEPS_FILE'"
  post_drain_manifest "first.sh" "second.sh"
  eval "_real_run_post_drain_step() $(declare -f run_post_drain_step | sed 1d)"
  run_post_drain_step() {
    local rc=0
    _real_run_post_drain_step "$@" || rc=$?
    [ "$2" = "first.sh" ] && [ -n "${INTERRUPT_AFTER_FIRST:-}" ] && RUNNER_INTERRUPTED=1
    return "$rc"
  }

  INTERRUPT_AFTER_FIRST=1
  finished_pass
  [ "$(cat "$STEPS_FILE")" = "first" ]
  [ -z "$(ok_mark alpha)" ]
  [ -z "$(failed_mark alpha)" ]

  INTERRUPT_AFTER_FIRST=""
  RUNNER_INTERRUPTED=0
  : >"$STEPS_FILE"
  finished_pass
  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "first second " ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
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
  advance_tip >/dev/null
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
  [ "$(failed_mark alpha)" = "$(alpha_tip)" ]
}

# === Restarts and other machines =============================================

@test "post-drain (#38): a finished feature whose pass dispatched nothing takes the Claim, runs its steps, sets the ok mark at the tip and releases the Claim; the next pass does not snapshot it" {
  consumer_step "probe.sh" "git -C '$SHARED' rev-parse --verify --quiet refs/formann/claims/alpha >/dev/null && echo held >>'$STEPS_FILE'"
  post_drain_manifest "probe.sh"

  finished_pass

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(cat "$STEPS_FILE")" = "held" ]
  [ ! -s "$LOOPS_FILE" ] || [ "$(cat "$LOOPS_FILE")" = "alpha" ]
  [ "${#RUN_DISPATCHES[@]}" = "0" ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ -z "$(claim_sha alpha)" ]
  [ -z "$CLAIM_HELD_FEATURE" ]

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ ! -s "$SNAP_CALLS_FILE" ]
  [ "$(cat "$STEPS_FILE")" = "held" ]
}

@test "post-drain (#38): the ok mark is set at the tip as it stands when the phase ends" {
  consumer_step "fix.sh" "git -C '$HOST_REPO' -c user.email=t@t -c user.name=t commit-tree -p \$(git -C '$SHARED' rev-parse refs/heads/alpha) -m fix \$(git -C '$HOST_REPO' mktree </dev/null) >'$BATS_TEST_TMPDIR/fix-sha'; git -C '$HOST_REPO' push --quiet origin \$(cat '$BATS_TEST_TMPDIR/fix-sha'):refs/heads/alpha"
  post_drain_manifest "fix.sh"
  local before
  before="$(alpha_tip)"

  finished_pass

  [ "$(alpha_tip)" != "$before" ]
  [ "$(ok_mark alpha)" = "$(alpha_tip)" ]
  [ "$(ok_mark alpha)" = "$(cat "$BATS_TEST_TMPDIR/fix-sha")" ]
}

@test "post-drain (#38): a second host repo on the same Shared remote sees the ok mark and does not run the phase for that tip" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  finished_pass
  [ "$(cat "$STEPS_FILE")" = "ran" ]

  # Machine two: its own host repo, same Shared remote, no local state.
  local host1="$HOST_REPO"
  HOST_REPO="$BATS_TEST_TMPDIR/host2"
  git init --quiet --initial-branch=main "$HOST_REPO"
  git -C "$HOST_REPO" remote add origin "$SHARED"
  HOST_ABORT_DIR="$HOST_REPO/.runner-state/aborted"
  HOST_BLOCKED_DIR="$HOST_REPO/.runner-state/blocked"
  RUNNER_MACHINE="m2"
  POST_DRAIN_MARKS_SEEN_FEATURE=""
  mkdir -p "$HOST_REPO/docs/formann"
  cp -R "$host1/docs/formann/issue-tracker" "$HOST_REPO/docs/formann/"

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ ! -s "$SNAP_CALLS_FILE" ]
  # Even a feature walked for other work settles on the mark before any step.
  GATE_ELIGIBLE=1
  drain_one_feature alpha
  [ "$(cat "$STEPS_FILE")" = "ran" ]
  [ -z "$(claim_sha alpha)" ]
}

@test "post-drain (#38): a new commit on the feature makes it due again" {
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"
  finished_pass
  local first
  first="$(ok_mark alpha)"
  finished_pass
  [ "$(cat "$STEPS_FILE")" = "ran" ]

  local tip2
  tip2="$(advance_tip)"
  finished_pass
  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "ran ran " ]
  [ "$(ok_mark alpha)" = "$tip2" ]
  [ "$first" != "$tip2" ]
}

@test "post-drain (#38): without a Shared remote the marks are local refs and one machine behaves the same" {
  git -C "$HOST_REPO" remote remove origin
  git -C "$HOST_REPO" branch alpha main
  consumer_step "step.sh" "echo ran >>'$STEPS_FILE'"
  post_drain_manifest "step.sh"

  finished_pass
  [ "$(cat "$STEPS_FILE")" = "ran" ]
  [ "$(git -C "$HOST_REPO" rev-parse refs/formann/post-drained/alpha)" = "$(git -C "$HOST_REPO" rev-parse alpha)" ]
  [ -z "$(git -C "$SHARED" for-each-ref refs/formann)" ]

  finished_pass
  [ "$RUN_STOP_REASON" = "nothing-eligible" ]
  [ ! -s "$SNAP_CALLS_FILE" ]

  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m more
  git -C "$HOST_REPO" branch -f alpha HEAD
  finished_pass
  [ "$(printf '%s ' $(cat "$STEPS_FILE"))" = "ran ran " ]
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
