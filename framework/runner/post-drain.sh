#!/usr/bin/env bash
# post-drain.sh — the Post-drain phase of the AFK runner.
#
# Sourced by run-the-queue.sh. Once every issue of a feature is done or
# wontfix, and while the runner holds the feature's Claim, it runs the host-side steps
# named in the consumer's post-drain manifest (`runner/post-drain.md`): a
# branch review, opening a pull request — work that needs the host's
# credentials and so cannot run in the sandbox. Steps run on the host, in the
# consumer root, never in a container.
#
# Manifest: same line format as the post-implement manifest (resolve_manifest
# in resolve-manifest.sh). The manifest file is looked up in the consumer's
# `runner/` first, then the framework root; the framework ships none, so a
# consumer without one has no post-drain steps. Each entry resolves against
# the consumer's `runner/` first, then the framework's `steps/`.
#
# A step is a prompt or a command, by what its entry resolves to:
#   - `*.md`      → a prompt: `claude -p "<prompt>\n<feature>"` on the host
#                   (streamed events to <log>.stdout.jsonl, closing message to
#                   <log>.summary.md).
#   - anything else → a command, executed with the feature slug as $1 and
#                   RUNNER_FEATURE set (stdout to <log>.stdout.log). It must be
#                   executable.
# Both get stdin from /dev/null and run with the host's environment, so host
# credentials (git, gh, keychain) are available to them.
#
# Outcome (classify_post_drain_step): `ok` (exit 0), `failed` (non-zero exit,
# or a prompt whose stream has no clean result), or `blocked (<dependency>)`
# when a clean step's last non-blank line is `BLOCKED: <dependency>` — the
# step contract of the post-implement phase. The phase stops at the first
# step that does not end `ok`.
#
# When the phase runs (ADR-0013): whenever the Post-drain due rule
# (post_drain_due) says `due` — every issue of the feature is `done` or
# `wontfix`, and neither Post-drain mark (post-drain-marks.sh) is at the
# feature's tip — on whichever machine holds the feature's Claim, whether or
# not this pass dispatched. A drain pass takes a finished feature with
# nothing eligible too (drain_pass_features, drain_one_feature);
# maybe_run_post_drain runs the phase after the feature's per-issue loop
# stopped with `queue-empty`. `--issue` never runs it.
#
# How it ends, recorded as a mark at the tip so every machine sees it:
#   - every step ok  → the ok mark at the tip as it stands when the phase
#                      ends (a step may have pushed commits).
#   - a step failed  → the failed mark at the tip, and a Note on the
#                      feature's parent naming the step, its outcome and its
#                      log.
#   - a step Blocked → a `Blocked` comment on the feature's parent naming the
#                      step and the dependency; no mark, so the next pass runs
#                      the phase again. When the parent's Blocked count (the
#                      binding's `blocked-passes`) reaches a multiple of 3,
#                      it is treated as failed: failed mark plus Note.
#   - interrupted, or the Claim lost → nothing recorded; the next pass runs
#                      the phase again.
# The phase always starts at its first step at the current tip — nothing
# resumes from a local marker or a run folder — so every post-drain step must
# be idempotent. Each step outcome goes on a progress line and into the
# Post-drain section of SUMMARY.md (format_post_drain_section).

# Resolved post-drain manifest (label<TAB>path pairs), set at pre-flight by
# check_post_drain_manifest. Empty = no post-drain steps.
RESOLVED_POST_DRAIN=""

# Post-drain step records for SUMMARY.md: `feature|label|outcome|duration|log`
# (log relative to the run or pass dir). Cleared with the dispatch records at
# the end of every idle pass.
RUN_POST_DRAIN=()

# Pick the post-drain manifest text: the consumer's file first, then the
# framework's. Prints nothing when neither exists (no post-drain steps).
#
# Args: $1 = consumer manifest path  $2 = framework manifest path
post_drain_manifest_text() {
  local consumer_file="$1" framework_file="$2"
  if [ -f "$consumer_file" ]; then
    cat "$consumer_file"
  elif [ -f "$framework_file" ]; then
    cat "$framework_file"
  fi
}

# Resolve the post-drain manifest into label<TAB>path pairs.
#
# Args: $1 = consumer prompts dir (<host>/runner)
#       $2 = framework dir holding the framework's post-drain.md
#       $3 = framework steps root (entries resolve here after the consumer dir)
# Stdout: the pairs (empty when there is no manifest or it lists nothing).
# Exit:   1 with resolve_manifest's diagnostics on stderr when an entry is
#         invalid or unresolved.
resolve_post_drain_manifest() {
  local consumer_dir="$1" fw_dir="$2" fw_steps="$3"
  local text
  text="$(post_drain_manifest_text "$consumer_dir/post-drain.md" "$fw_dir/post-drain.md")"
  [ -n "$text" ] || return 0
  resolve_manifest "$text" "$fw_steps" "$consumer_dir"
}

# Pre-flight invariant 4c: the post-drain manifest, when there is one,
# resolves. Sets RESOLVED_POST_DRAIN.
check_post_drain_manifest() {
  if ! RESOLVED_POST_DRAIN="$(resolve_post_drain_manifest \
      "$(judges_dir)/$RUNNER_CONSUMER_PROMPTS_DIR" "$HERE" "$HERE/steps" 2>&1)"; then
    fail_invariant "post-drain-manifest" "$RESOLVED_POST_DRAIN"
  fi
}

# `prompt` for a `.md` entry, `command` for anything else. Pure.
post_drain_step_kind() {
  case "$1" in
    *.md) echo "prompt" ;;
    *)    echo "command" ;;
  esac
}

# The dependency named by a command's closing `BLOCKED: <dependency>` line
# (the last non-blank line of its stdout), or empty. Pure — reads the file.
post_drain_command_blocked_dep() {
  local file="$1" last
  [ -f "$file" ] || return 0
  last="$(sed -e 's/[[:space:]]*$//' "$file" | awk 'NF { l = $0 } END { print l }')"
  case "$last" in
    BLOCKED:*)
      last="${last#BLOCKED:}"
      last="$(printf '%s' "$last" | sed 's/^[[:space:]]*//')"
      printf '%s' "$last"
      ;;
  esac
}

# Map a step's exit code and Blocked dependency to its outcome. Pure.
#   $1 = exit code  $2 = dependency from the BLOCKED: line (may be empty)
# Stdout: ok | failed | blocked
classify_post_drain_step() {
  local rc="$1" dep="${2:-}"
  if [ "$rc" != "0" ]; then
    echo "failed"
  elif [ -n "$dep" ]; then
    echo "blocked"
  else
    echo "ok"
  fi
}

# The Post-drain due rule. Pure: no I/O — everything it decides from is
# passed in.
#
# Args: $1 = feature snapshot JSON  $2 = ok-mark sha  $3 = failed-mark sha
#       $4 = the feature's tip sha (a mark is empty when absent)
# Stdout: `due` when the feature has a tip, its snapshot lists at least one
#         issue, every issue is `done` or `wontfix`, and neither mark is at
#         the tip; `not-due` otherwise. (#41 adds `waiting`.)
post_drain_due() {
  local snap="$1" ok="${2:-}" failed="${3:-}" tip="${4:-}"
  if [ -z "$tip" ] || [ "$ok" = "$tip" ] || [ "$failed" = "$tip" ]; then
    echo "not-due"
    return 0
  fi
  if jq -e '(.issues // []) | length > 0
      and all(.[]; (.status // "") == "done" or (.status // "") == "wontfix")' \
      >/dev/null 2>&1 <<<"$snap"; then
    echo "due"
  else
    echo "not-due"
  fi
}

# Host-side system prompt for prompt steps.
RUNNER_POST_DRAIN_PREAMBLE="This is a one-shot headless post-drain step of the AFK runner: a single claude -p turn on the host, not in the sandbox, run once every issue of the feature named at the end of the prompt is done or wontfix. It runs in the consumer's repository with the host's credentials. Carry out the step within this run; do not wait to be resumed. If something outside the run that the step needs is unreachable, end your final message with the line 'BLOCKED: <dependency>'."

# Run one post-drain step on the host. Writes <log_base>.stdout.jsonl (prompt)
# or <log_base>.stdout.log (command), <log_base>.stderr.log and
# <log_base>.summary.md. Sets POST_DRAIN_STEP_DEP to the Blocked dependency
# (empty when not Blocked) and POST_DRAIN_STEP_LOG to the stdout artifact.
#
# Args: $1 = feature  $2 = label  $3 = resolved path  $4 = log base
# Return: the step's exit code (non-zero also for a prompt step whose stream
#         has no clean terminal result, and for a non-executable command).
run_post_drain_step() {
  local feature="$1" label="$2" path="$3" log_base="$4"
  local rc=0
  POST_DRAIN_STEP_DEP=""
  if [ "$(post_drain_step_kind "$path")" = "prompt" ]; then
    POST_DRAIN_STEP_LOG="$log_base.stdout.jsonl"
    local prompt_text model_args=()
    prompt_text="$(cat "$path")"$'\n'"$feature"
    [ -n "${ARG_MODEL:-}" ] && model_args=(--model "$ARG_MODEL")
    ( cd "$HOST_REPO" && RUNNER_FEATURE="$feature" "${RUNNER_HOST_CLAUDE:-claude}" -p "$prompt_text" \
        --output-format stream-json --verbose --dangerously-skip-permissions \
        --append-system-prompt "$RUNNER_POST_DRAIN_PREAMBLE" \
        "${model_args[@]+"${model_args[@]}"}" ) \
      </dev/null >"$POST_DRAIN_STEP_LOG" 2>"$log_base.stderr.log" || rc=$?
    extract_result_summary "$POST_DRAIN_STEP_LOG" >"$log_base.summary.md"
    if [ "$rc" -eq 0 ]; then
      local result_line
      result_line="$(_terminal_result_line "$POST_DRAIN_STEP_LOG")"
      if [ -z "$result_line" ] \
          || [ "$(printf '%s' "$result_line" | jq -r '.is_error // false' 2>/dev/null)" = "true" ]; then
        rc=1
      fi
    fi
    [ "$rc" -eq 0 ] && POST_DRAIN_STEP_DEP="$(blocked_dependency "$POST_DRAIN_STEP_LOG")"
  else
    POST_DRAIN_STEP_LOG="$log_base.stdout.log"
    if [ ! -x "$path" ]; then
      echo "runner: post-drain step '$label': $path is not executable (a non-.md entry is run as a command)" \
        | tee "$log_base.stderr.log" >&2
      : >"$POST_DRAIN_STEP_LOG"
      rc=126
    else
      ( cd "$HOST_REPO" && RUNNER_FEATURE="$feature" "$path" "$feature" ) \
        </dev/null >"$POST_DRAIN_STEP_LOG" 2>"$log_base.stderr.log" || rc=$?
    fi
    [ "$rc" -eq 0 ] && POST_DRAIN_STEP_DEP="$(post_drain_command_blocked_dep "$POST_DRAIN_STEP_LOG")"
    tail -n 20 "$POST_DRAIN_STEP_LOG" >"$log_base.summary.md"
  fi
  # `|` is the record delimiter.
  POST_DRAIN_STEP_DEP="${POST_DRAIN_STEP_DEP//|//}"
  return "$rc"
}

record_post_drain() {
  local feature="$1" label="$2" outcome="$3" duration="$4" log="${5:-}"
  RUN_POST_DRAIN+=("$feature|$label|$outcome|$duration|$log")
}

# Blocked passes on a feature's parent at which the phase is treated as
# failed.
POST_DRAIN_BLOCKED_PASS_LIMIT=3

# Run the post-drain steps of a finished feature, in manifest order, from the
# first step, then record how the phase ended (post_drain_conclude).
# Heartbeats the claim before every step; a lost claim stops the phase
# before its next step.
#
# Args: $1 = feature  $2 = run or pass dir
# Return: always 0 — a post-drain outcome never stops the drain.
run_post_drain_phase() {
  local feature="$1" run_dir="$2"
  [ -n "$RESOLVED_POST_DRAIN" ] || return 0

  local log_dir="$run_dir"
  [ "${RUN_LOG_LAYOUT:-flat}" = "nested" ] && log_dir="$run_dir/$feature"
  mkdir -p "$log_dir"

  echo "[$(now_clock)] runner: $feature is finished — post-drain phase"

  local label path idx=0 ended="ok" ended_step="" ended_outcome="" ended_log="" ended_dep=""
  while IFS=$'\t' read -r label path; do
    [ -z "$label" ] && continue
    idx=$((idx + 1))

    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      ended="interrupted"
      break
    fi

    heartbeat_claim
    if [ -n "${RUNNER_CLAIM_LOST:-}" ]; then
      echo "[$(now_clock)] runner: '$feature' was $RUNNER_CLAIM_LOST; not running post-drain step $label"
      record_post_drain "$feature" "$label" "not run ($RUNNER_CLAIM_LOST)" 0 ""
      ended="claim-lost"
      break
    fi

    local suffix log_base started rc=0 duration outcome
    suffix="post-drain-$(printf '%02d' "$idx")-$label"
    log_base="$log_dir/$suffix"
    format_progress_start "$(now_clock)" "$feature" "post-drain:$label"
    started=$(date +%s)
    with_claim_refresher run_post_drain_step "$feature" "$label" "$path" "$log_base" || rc=$?
    duration=$(( $(date +%s) - started ))
    local rel_log="${POST_DRAIN_STEP_LOG#$run_dir/}"

    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "interrupted" "$duration"
      record_post_drain "$feature" "$label" "interrupted" "$duration" "$rel_log"
      ended="interrupted"
      break
    fi

    outcome="$(classify_post_drain_step "$rc" "$POST_DRAIN_STEP_DEP")"
    case "$outcome" in
      ok)
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "ok" "$duration"
        record_post_drain "$feature" "$label" "ok" "$duration" "$rel_log"
        ;;
      blocked)
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "blocked ($POST_DRAIN_STEP_DEP)" "$duration"
        record_post_drain "$feature" "$label" "blocked ($POST_DRAIN_STEP_DEP)" "$duration" "$rel_log"
        ended="blocked"; ended_step="$label"; ended_dep="$POST_DRAIN_STEP_DEP"
        ended_outcome="blocked ($POST_DRAIN_STEP_DEP)"; ended_log="$POST_DRAIN_STEP_LOG"
        break
        ;;
      *)
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "failed (exit $rc)" "$duration"
        echo "[$(now_clock)] runner: post-drain step $label failed for $feature; stopping the post-drain phase"
        record_post_drain "$feature" "$label" "failed (exit $rc)" "$duration" "$rel_log"
        ended="failed"; ended_step="$label"; ended_outcome="failed (exit $rc)"; ended_log="$POST_DRAIN_STEP_LOG"
        break
        ;;
    esac
  done <<< "$RESOLVED_POST_DRAIN"

  post_drain_conclude "$feature" "$ended" "$ended_step" "$ended_outcome" "$ended_log" "$ended_dep"
  return 0
}

# Record how the phase ended (see the header): the ok mark, the failed mark
# plus a Note, or a Blocked comment (a failure at every third Blocked pass).
# Interrupted or claim-lost: nothing.
#
# Args: $1 = feature  $2 = ok | failed | blocked | interrupted | claim-lost
#       $3 = step  $4 = step outcome  $5 = step log  $6 = Blocked dependency
post_drain_conclude() {
  local feature="$1" ended="$2" step="${3:-}" outcome="${4:-}" log="${5:-}" dep="${6:-}"
  case "$ended" in
    ok)
      post_drain_set_mark ok "$feature" >/dev/null
      ;;
    failed)
      post_drain_fail "$feature" "$step" "$outcome" "$log"
      ;;
    blocked)
      local passes=""
      if post_feature_comment "$feature" "Blocked" "$(post_drain_blocked_body "$step" "$dep" "$log")"; then
        if passes="$(read_blocked_passes "$FEATURE_COMMENT_REF")"; then
          echo "[$(now_clock)] runner: post-drain step $step for $feature is Blocked on $dep (Blocked pass $passes on the feature's parent)"
        else
          echo "[$(now_clock)] runner: could not count the Blocked passes on $feature's parent (see above); the next pass runs the phase again"
          passes=""
        fi
      else
        echo "[$(now_clock)] runner: could not post the Blocked comment on $feature (see above); the next pass runs the phase again"
      fi
      if [ -n "$passes" ] && [ "$passes" -gt 0 ] \
          && [ $(( passes % POST_DRAIN_BLOCKED_PASS_LIMIT )) -eq 0 ]; then
        post_drain_fail "$feature" "$step" "$outcome on $POST_DRAIN_BLOCKED_PASS_LIMIT consecutive passes" "$log"
      fi
      ;;
    *)
      echo "[$(now_clock)] runner: post-drain phase for $feature ended $ended; nothing recorded — the next pass runs it again from its first step"
      ;;
  esac
}

# A failed phase: the failed mark at the tip, then a Note on the parent
# naming the step, its outcome and its log.
post_drain_fail() {
  local feature="$1" step="$2" outcome="$3" log="$4" tip body
  tip="$(post_drain_set_mark failed "$feature")"
  body="$(cat <<NOTE
> *This was generated by the AFK runner.*

The post-drain phase failed on the runner on \`$(claim_machine)\` (run \`${RUN_TS:-unknown}\`).

- Step: \`$step\`
- Outcome: $outcome
- Tip: \`${tip:-unknown}\`
- Log: \`${log#$HOST_REPO/}\`

The failed mark \`$(post_drain_mark_ref failed "$feature")\` is at that tip, so the phase does not run again until the feature's branch moves or the mark is deleted (\`$(post_drain_mark_delete_recipe failed "$feature")\`).
NOTE
)"
  if post_feature_comment "$feature" "Note" "$body"; then
    echo "[$(now_clock)] runner: posted the post-drain failure Note on $feature"
  else
    echo "[$(now_clock)] runner: could not post the post-drain failure Note on $feature (see above)"
  fi
}

# The body of the Blocked comment a Blocked step posts on the parent.
post_drain_blocked_body() {
  local step="$1" dep="$2" log="$3"
  cat <<BODY
> *This was generated by the AFK runner.*

Post-drain step \`$step\` ended Blocked on the runner on \`$(claim_machine)\` (run \`${RUN_TS:-unknown}\`).

- Dependency: $dep
- Log: \`${log#$HOST_REPO/}\`

The next pass runs the post-drain phase again from its first step; every ${POST_DRAIN_BLOCKED_PASS_LIMIT}rd Blocked pass is treated as a failure.
BODY
}

# Set a mark at the feature's tip as it stands now. Prints the tip (empty
# when there is none) on stdout; logs on stderr. Never fails the drain.
# Args: $1 = ok | failed  $2 = feature
post_drain_set_mark() {
  local kind="$1" feature="$2" tip=""
  if ! tip="$(post_drain_tip "$feature")" || [ -z "$tip" ]; then
    echo "[$(now_clock)] runner: could not read the tip of $feature; the $kind mark is not set" >&2
    return 0
  fi
  post_drain_marks_set "$kind" "$feature" "$tip" || true
  case "$POST_DRAIN_MARKS_RESULT" in
    set)
      echo "[$(now_clock)] runner: post-drain $kind mark of $feature set at ${tip:0:12} ($(post_drain_mark_ref "$kind" "$feature"))" >&2 ;;
    lease-refused)
      echo "[$(now_clock)] runner: the $kind mark of $feature was moved by another writer; left as it is" >&2 ;;
    *)
      echo "[$(now_clock)] runner: could not set the $kind mark of $feature (see above)" >&2 ;;
  esac
  printf '%s\n' "$tip"
}

# The due rule's verdict for a feature now: reads its tip and marks (I/O),
# then applies post_drain_due to the given snapshot. Leaves the marks it
# read as the lease for a later set.
#
# Args: $1 = feature  $2 = snapshot JSON
# Stdout: due | not-due. Returns 1 when the tip or marks can't be read.
post_drain_due_now() {
  local feature="$1" snap="$2" tip
  tip="$(post_drain_tip "$feature")" || return 1
  post_drain_marks_read "$feature" >/dev/null || return 1
  post_drain_due "$snap" "$POST_DRAIN_MARK_OK_SEEN" "$POST_DRAIN_MARK_FAILED_SEEN" "$tip"
}

# After a feature's per-issue loop: run the post-drain phase when the loop
# stopped on an empty queue and the due rule says `due` — whether or not
# this pass dispatched. Called while the claim is held. A tip that already
# carries a mark is settled before any snapshot is taken.
#
# Args: $1 = feature  $2 = the loop's stop reason
maybe_run_post_drain() {
  local feature="$1" stop_reason="$2"
  [ -n "$RESOLVED_POST_DRAIN" ] || return 0
  [ "$stop_reason" = "queue-empty" ] || return 0
  [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ] && return 0
  local tip
  if ! tip="$(post_drain_tip "$feature")" || ! post_drain_marks_read "$feature" >/dev/null; then
    echo "[$(now_clock)] runner: could not read the tip or the post-drain marks of $feature; post-drain phase not run"
    return 0
  fi
  if [ -z "$tip" ]; then
    echo "[$(now_clock)] runner: $feature has no branch; post-drain phase not run"
    return 0
  fi
  if [ "$POST_DRAIN_MARK_OK_SEEN" = "$tip" ] || [ "$POST_DRAIN_MARK_FAILED_SEEN" = "$tip" ]; then
    return 0
  fi
  local snap
  if ! snap="$(take_snapshot "$feature")"; then
    echo "[$(now_clock)] runner: tracker-snapshot failed for $feature; post-drain phase not run"
    return 0
  fi
  if [ "$(post_drain_due "$snap" "$POST_DRAIN_MARK_OK_SEEN" "$POST_DRAIN_MARK_FAILED_SEEN" "$tip")" != "due" ]; then
    echo "[$(now_clock)] runner: $feature is not finished (an issue is not done or wontfix); post-drain phase not run"
    return 0
  fi
  run_post_drain_phase "$feature" "${RUN_PASS_DIR:-$RUN_DIR}"
}

# SUMMARY.md's "## Post-drain" section, from RUN_POST_DRAIN. Prints nothing
# when no post-drain step ran.
format_post_drain_section() {
  [ "${#RUN_POST_DRAIN[@]}" -gt 0 ] || return 0
  printf '\n## Post-drain\n\n'
  printf '| feature | step | outcome | duration | log |\n'
  printf '|---------|------|---------|----------|-----|\n'
  local rec feature label outcome duration log cell
  for rec in "${RUN_POST_DRAIN[@]}"; do
    IFS='|' read -r feature label outcome duration log <<<"$rec"
    if [ -n "$log" ]; then cell="[$log]($log)"; else cell="-"; fi
    printf '| %s | %s | %s | %s | %s |\n' \
      "$feature" "$label" "$outcome" "$(humanize_duration "$duration")" "$cell"
  done
}
