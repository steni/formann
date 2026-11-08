#!/usr/bin/env bash
# post-drain.sh — the Post-drain phase of the AFK runner.
#
# Sourced by run-the-queue.sh. Once a feature has drained, and while the
# runner still holds the feature's Claim, the runner runs the host-side steps
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
# step that does not end `ok`:
#   - failed  → abort flag `.runner-state/aborted/<feature>/post-drain-<label>`
#               (write_abort_flag). Dispatches are not undone. While the flag
#               exists, later phases for the feature stop at that step.
#   - blocked → Blocked marker `.runner-state/blocked/<feature>/post-drain`
#               naming the step; no abort flag. The next pass re-runs the phase
#               from that step, even when the feature has nothing to dispatch.
# Each outcome goes on a progress line and into SUMMARY.md's "## Post-drain"
# section (format_post_drain_section).
#
# When the phase runs (maybe_run_post_drain): after a feature's per-issue loop
# stopped with `queue-empty`, provided it dispatched in that loop (or a
# post-drain step is pending from a Blocked pass), and a fresh snapshot says
# the feature has drained (feature_has_drained): no eligible issue left and no
# issue Blocked. `--issue` never runs it.

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
      "$HOST_REPO/$RUNNER_CONSUMER_PROMPTS_DIR" "$HERE" "$HERE/steps" 2>&1)"; then
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

# Whether a feature has drained: its snapshot has no eligible issue and no
# issue that is Blocked (an AFK issue at in-review with a Blocked marker,
# which a later pass retries). Returns 0 when drained.
#
# Args: $1 = feature  $2 = snapshot JSON
feature_has_drained() {
  local feature="$1" snap="$2"
  local nn eligible status type
  while IFS=$'\t' read -r nn eligible status type; do
    [ -z "$nn" ] && continue
    [ "$eligible" = "true" ] && return 1
    if [ "$status" = "in-review" ] && [ "$type" = "AFK" ] \
        && [ -n "$(blocked_marker_step "$feature" "$nn")" ]; then
      return 1
    fi
  done < <(jq -r '.issues[]
    | "\(.nn)\t\(.eligible == true)\t\(.status // "-")\t\(.type // "-")"' <<<"$snap")
  return 0
}

# The step a Blocked post-drain pass left to retry, or nothing.
post_drain_pending_step() {
  blocked_marker_step "$1" "post-drain"
}

# Host-side system prompt for prompt steps.
RUNNER_POST_DRAIN_PREAMBLE="This is a one-shot headless post-drain step of the AFK runner: a single claude -p turn on the host, not in the sandbox, run after the feature named at the end of the prompt has drained. It runs in the consumer's repository with the host's credentials. Carry out the step within this run; do not wait to be resumed. If something outside the run that the step needs is unreachable, end your final message with the line 'BLOCKED: <dependency>'."

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

# Run the post-drain steps of a drained feature, in manifest order, from
# $3 (a Blocked retry) or from the first step. Heartbeats the claim before
# every step; a lost claim stops the phase before its next step.
#
# Args: $1 = feature  $2 = run or pass dir  $3 = start label (optional)
# Return: always 0 — a post-drain outcome never stops the drain.
run_post_drain_phase() {
  local feature="$1" run_dir="$2" start_label="${3:-}"
  [ -n "$RESOLVED_POST_DRAIN" ] || return 0

  if [ -n "$start_label" ] \
      && ! printf '%s\n' "$RESOLVED_POST_DRAIN" | cut -f1 | grep -Fxq -- "$start_label"; then
    echo "[$(now_clock)] runner: Blocked post-drain step '$start_label' is no longer in the manifest; running the whole post-drain phase for $feature"
    start_label=""
  fi

  local log_dir="$run_dir"
  [ "${RUN_LOG_LAYOUT:-flat}" = "nested" ] && log_dir="$run_dir/$feature"
  mkdir -p "$log_dir"

  echo "[$(now_clock)] runner: $feature has drained — post-drain phase${start_label:+ (retrying from $start_label)}"

  local label path idx=0 skipping=0
  [ -n "$start_label" ] && skipping=1
  while IFS=$'\t' read -r label path; do
    [ -z "$label" ] && continue
    idx=$((idx + 1))
    if [ "$skipping" -eq 1 ]; then
      [ "$label" = "$start_label" ] || continue
      skipping=0
    fi

    local flag="$HOST_ABORT_DIR/$feature/post-drain-$label"
    if [ -f "$flag" ]; then
      echo "[$(now_clock)] runner: post-drain step $label for $feature is aborted — rm $flag to resume; stopping the post-drain phase"
      record_post_drain "$feature" "$label" "skipped (aborted)" 0 ""
      break
    fi

    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      break
    fi

    heartbeat_claim
    if [ -n "${RUNNER_CLAIM_LOST:-}" ]; then
      echo "[$(now_clock)] runner: '$feature' was $RUNNER_CLAIM_LOST; not running post-drain step $label"
      record_post_drain "$feature" "$label" "not run ($RUNNER_CLAIM_LOST)" 0 ""
      break
    fi

    local suffix log_base started rc=0 duration outcome
    suffix="post-drain-$(printf '%02d' "$idx")-$label"
    log_base="$log_dir/$suffix"
    format_progress_start "$(now_clock)" "$feature" "post-drain:$label"
    started=$(date +%s)
    run_post_drain_step "$feature" "$label" "$path" "$log_base" || rc=$?
    duration=$(( $(date +%s) - started ))
    local rel_log="${POST_DRAIN_STEP_LOG#$run_dir/}"

    if [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ]; then
      format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "interrupted" "$duration"
      record_post_drain "$feature" "$label" "interrupted" "$duration" "$rel_log"
      break
    fi

    outcome="$(classify_post_drain_step "$rc" "$POST_DRAIN_STEP_DEP")"
    case "$outcome" in
      ok)
        clear_blocked_marker "$feature" "post-drain"
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "ok" "$duration"
        record_post_drain "$feature" "$label" "ok" "$duration" "$rel_log"
        ;;
      blocked)
        write_blocked_marker "$feature" "post-drain" "$label" "$POST_DRAIN_STEP_DEP"
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "blocked ($POST_DRAIN_STEP_DEP)" "$duration"
        record_post_drain "$feature" "$label" "blocked ($POST_DRAIN_STEP_DEP)" "$duration" "$rel_log"
        break
        ;;
      *)
        clear_blocked_marker "$feature" "post-drain"
        write_abort_flag "$feature" "post-drain-$label" "post-drain:$label" "$rc" "$POST_DRAIN_STEP_LOG"
        format_progress_outcome "$(now_clock)" "$feature" "post-drain:$label" "failed (exit $rc)" "$duration"
        echo "[$(now_clock)] runner: post-drain step $label failed for $feature — abort flag $flag; stopping the post-drain phase"
        record_post_drain "$feature" "$label" "failed (exit $rc)" "$duration" "$rel_log"
        break
        ;;
    esac
  done <<< "$RESOLVED_POST_DRAIN"
  return 0
}

# Number of dispatch records for a feature (RUN_DISPATCHES).
feature_dispatch_count() {
  local feature="$1" n=0 rec
  if [ "${#RUN_DISPATCHES[@]}" -gt 0 ]; then
    for rec in "${RUN_DISPATCHES[@]}"; do
      [ "${rec%%|*}" = "$feature" ] && n=$((n + 1))
    done
  fi
  echo "$n"
}

# After a feature's per-issue loop: run the post-drain phase when the loop
# stopped on an empty queue, it dispatched (or a Blocked post-drain step is
# pending), and the feature has drained. Called while the claim is held.
#
# Args: $1 = feature  $2 = the loop's stop reason  $3 = dispatch count before
#       the loop (feature_dispatch_count)
maybe_run_post_drain() {
  local feature="$1" stop_reason="$2" before="$3"
  [ -n "$RESOLVED_POST_DRAIN" ] || return 0
  [ "$stop_reason" = "queue-empty" ] || return 0
  [ "${RUNNER_INTERRUPTED:-0}" -eq 1 ] && return 0
  local pending
  pending="$(post_drain_pending_step "$feature")"
  if [ "$(feature_dispatch_count "$feature")" -le "$before" ] && [ -z "$pending" ]; then
    return 0
  fi
  local snap
  if ! snap="$(take_snapshot "$feature")"; then
    echo "[$(now_clock)] runner: tracker-snapshot failed for $feature; post-drain phase not run"
    return 0
  fi
  if ! feature_has_drained "$feature" "$snap"; then
    echo "[$(now_clock)] runner: $feature has not drained (an issue is still eligible or Blocked); post-drain phase not run"
    return 0
  fi
  run_post_drain_phase "$feature" "${RUN_PASS_DIR:-$RUN_DIR}" "$pending"
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
