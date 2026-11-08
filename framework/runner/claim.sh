#!/usr/bin/env bash
# Claim — a runner's exclusive hold on the feature it drains (ADR-0011).
#
# A Claim is the ref `refs/formann/claims/<feature>` on the Shared remote
# ($RUNNER_SHARED_REMOTE, default `origin`), pointing at a small parentless
# commit (empty tree) whose message names the holder:
#
#     formann claim
#
#     machine: <hostname>
#     run: <run id>
#     formann: <sha or unknown>
#     heartbeat: <UTC ISO-8601>
#
# The claim lives in git, never in the tracker, so it behaves the same under
# every binding. The runner announces a claim on the tracker with a Note; the
# comment is information, never the lock.
#
# Interface:
#   claim take <feature>      → `taken` | `taken-over-from <machine>`
#                               | `held-by <machine>`
#   claim heartbeat <feature> → `ok` | `lost-to <machine>` | `error`
#   claim release <feature>   → `released` | `release-refused`
#   claim_verdict <claim-message> <now-epoch> <stale-after-seconds>
#                             → `free` | `held` | `stale` (pure)
#
# Staleness: a claim whose heartbeat is more than stale-after seconds old
# ($RUNNER_CLAIM_STALE_AFTER, default 1800) by the reader's own clock is
# `stale`, and another runner may take it over. Nobody writes "stale"; each
# reader decides it.
#
# `claim` prints its result on stdout and leaves it in CLAIM_RESULT, so a
# caller in the runner's own shell reads the result without a subshell (the
# held claim is shell state: CLAIM_HELD_FEATURE / CLAIM_HELD_SHA).
#
# The rule: this file is the only code that writes claim refs, and every
# write is a lease push on the sha the writer last read. `take` leases on
# "absent"; a takeover leases on the stale claim's sha; `heartbeat` and
# `release` lease on the sha this runner wrote. A refused lease is reported,
# never retried as a plain or forced push.
#
# Every git call runs in $HOST_REPO, with the host's credentials; the sandbox
# never sees a claim.

CLAIM_HELD_FEATURE=""
CLAIM_HELD_SHA=""
CLAIM_RESULT=""

# The claim ref for a feature.
claim_ref() {
  printf 'refs/formann/claims/%s\n' "$1"
}

# The Shared remote's name ($RUNNER_SHARED_REMOTE, default `origin`).
claim_shared_remote() {
  printf '%s\n' "${RUNNER_SHARED_REMOTE:-origin}"
}

# True when the host repo has a Shared remote. Without one there are no
# claims: the local lock is the only guard, as on one machine.
claim_shared_remote_present() {
  git -C "$HOST_REPO" remote get-url "$(claim_shared_remote)" >/dev/null 2>&1
}

# This machine's name in a claim. RUNNER_MACHINE overrides the hostname.
claim_machine() {
  if [ -n "${RUNNER_MACHINE:-}" ]; then
    printf '%s\n' "$RUNNER_MACHINE"
  else
    hostname 2>/dev/null || uname -n
  fi
}

# Pure: the claim commit's message.
# Args: $1 machine, $2 run id, $3 formann sha, $4 heartbeat (UTC ISO-8601).
claim_message() {
  printf 'formann claim\n\nmachine: %s\nrun: %s\nformann: %s\nheartbeat: %s\n' \
    "$1" "$2" "$3" "$4"
}

# Pure: one field of a claim message (empty when absent).
# Args: $1 message, $2 field name (machine | run | formann | heartbeat).
claim_field() {
  printf '%s\n' "$1" | awk -v k="$2: " 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

# Seconds after its last heartbeat at which a claim is stale.
claim_stale_after() {
  printf '%s\n' "${RUNNER_CLAIM_STALE_AFTER:-1800}"
}

# This reader's clock (epoch seconds). Each reader judges staleness by its
# own clock; tests redefine this.
claim_now_epoch() {
  date +%s
}

# Pure: epoch seconds of a UTC ISO-8601 time `YYYY-MM-DDTHH:MM:SSZ`.
# No `date` parsing (GNU and BSD differ): days-from-civil arithmetic.
# Returns 1 (prints nothing) on anything else.
claim_iso_to_epoch() {
  local iso="${1:-}"
  [[ "$iso" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 1
  [ "$m" -le 2 ] && y=$((y - 1))
  local era=$((y / 400))
  local yoe=$((y - era * 400))
  local mp=$(( m > 2 ? m - 3 : m + 9 ))
  local doy=$(( (153 * mp + 2) / 5 + d - 1 ))
  local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  local days=$(( era * 146097 + doe - 719468 ))
  printf '%s\n' $(( days * 86400 + hh * 3600 + mm * 60 + ss ))
}

# Pure: is the feature free, held or stale, given the claim's message as
# read? An empty message (no claim ref) is `free`. A claim whose heartbeat
# is more than stale-after seconds before now is `stale`; at exactly
# stale-after it is still `held`. A claim whose heartbeat can't be read is
# `held`: a claim this runner can't judge is never taken over.
# Args: $1 claim message, $2 now (epoch seconds), $3 stale-after (seconds).
claim_verdict() {
  local message="${1:-}" now="${2:-}" stale_after="${3:-}"
  if [ -z "$(printf '%s' "$message" | tr -d '[:space:]')" ]; then
    echo "free"
    return 0
  fi
  local hb
  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$stale_after" =~ ^[0-9]+$ ]] \
      && hb="$(claim_iso_to_epoch "$(claim_field "$message" heartbeat)")" \
      && [ $(( now - hb )) -gt "$stale_after" ]; then
    echo "stale"
  else
    echo "held"
  fi
}

# Read the Shared remote's claim for a feature. Prints the claim's sha and
# message as `<sha>\n<message>`; prints nothing when there is no claim.
# Returns 1 when the remote can't be read.
claim_read() {
  local feature="$1"
  local remote ref seen ls_out sha
  remote="$(claim_shared_remote)"
  ref="$(claim_ref "$feature")"
  if ! ls_out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" ls-remote "$remote" "$ref" 2>&1)"; then
    printf 'runner: claim: cannot read %s on %s:\n%s\n' "$ref" "$remote" "$ls_out" >&2
    return 1
  fi
  sha="$(printf '%s\n' "$ls_out" | awk -v r="$ref" '$2 == r { print $1; exit }')"
  [ -n "$sha" ] || return 0
  # Fetch the claim commit into a scratch ref, read it, drop the ref: the
  # host keeps no claim refs of its own.
  seen="refs/formann/seen/$feature"
  if ! GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" fetch --quiet --no-write-fetch-head \
      "$remote" "+$ref:$seen" >&2; then
    printf 'runner: claim: cannot fetch %s from %s\n' "$ref" "$remote" >&2
    return 1
  fi
  sha="$(git -C "$HOST_REPO" rev-parse --verify --quiet "$seen^{commit}" || true)"
  if [ -z "$sha" ]; then
    git -C "$HOST_REPO" update-ref -d "$seen" >/dev/null 2>&1 || true
    return 0
  fi
  printf '%s\n' "$sha"
  git -C "$HOST_REPO" log -1 --format=%B "$sha"
  git -C "$HOST_REPO" update-ref -d "$seen" >/dev/null 2>&1 || true
}

# Write a claim commit for this runner, with a fresh heartbeat, into the
# host's object store; print its sha.
claim_commit() {
  local machine tree now
  machine="$(claim_machine)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tree="$(git -C "$HOST_REPO" mktree </dev/null)" || return 1
  claim_message "$machine" "${RUN_TS:-unknown}" "${RUNNER_FORMANN_SHA:-unknown}" "$now" \
    | GIT_AUTHOR_NAME="formann-runner" GIT_AUTHOR_EMAIL="runner@$machine" \
      GIT_COMMITTER_NAME="formann-runner" GIT_COMMITTER_EMAIL="runner@$machine" \
      git -C "$HOST_REPO" commit-tree "$tree"
}

# The machine named in a `claim_read` output (`<sha>\n<message>`).
claim_read_machine() {
  local m
  m="$(claim_field "$(printf '%s\n' "$1" | sed '1d')" machine)"
  printf '%s\n' "${m:-unknown}"
}

# take: lease push expecting the ref absent. Refusal → read the claim: held
# by a live runner → `held-by`; stale → take it over with a lease push on
# the stale claim's sha.
claim_take() {
  local feature="$1"
  local remote ref commit push_out push_rc=0 read_out holder verdict
  remote="$(claim_shared_remote)"
  ref="$(claim_ref "$feature")"
  if ! commit="$(claim_commit)" || [ -z "$commit" ]; then
    echo "runner: claim: could not write the claim commit for $feature" >&2
    return 1
  fi
  push_out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" push --quiet \
      "--force-with-lease=$ref:" "$remote" "$commit:$ref" 2>&1)" || push_rc=$?
  if [ "$push_rc" -eq 0 ]; then
    CLAIM_HELD_FEATURE="$feature"
    CLAIM_HELD_SHA="$commit"
    CLAIM_RESULT="taken"
    return 0
  fi
  # Refused (or failed). Never retried as a plain or forced push: read who
  # holds it instead.
  if ! read_out="$(claim_read "$feature")"; then
    printf 'runner: claim: take of %s on %s failed:\n%s\n' "$ref" "$remote" "$push_out" >&2
    return 1
  fi
  if [ -z "$read_out" ]; then
    # No claim on the remote, yet the push failed: not a lost race (or the
    # holder released in between). Don't drain on a claim we don't hold.
    printf 'runner: claim: take of %s on %s failed and no claim is there:\n%s\n' \
      "$ref" "$remote" "$push_out" >&2
    return 1
  fi
  holder="$(claim_read_machine "$read_out")"
  verdict="$(claim_verdict "$(printf '%s\n' "$read_out" | sed '1d')" \
    "$(claim_now_epoch)" "$(claim_stale_after)")"
  if [ "$verdict" = "stale" ]; then
    claim_takeover "$feature" "$commit" "$(printf '%s\n' "$read_out" | head -n 1)" "$holder"
    return
  fi
  CLAIM_RESULT="held-by $holder"
  return 0
}

# takeover: a lease push on the stale claim's sha. Refusal means the holder
# heart-beat (or someone else took over) meanwhile: re-read and back off as
# `held-by`.
# Args: $1 feature, $2 this runner's claim commit, $3 stale sha, $4 its machine.
claim_takeover() {
  local feature="$1" commit="$2" stale_sha="$3" stale_holder="$4"
  local remote ref push_out push_rc=0 read_out
  remote="$(claim_shared_remote)"
  ref="$(claim_ref "$feature")"
  push_out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" push --quiet \
      "--force-with-lease=$ref:$stale_sha" "$remote" "$commit:$ref" 2>&1)" || push_rc=$?
  if [ "$push_rc" -eq 0 ]; then
    CLAIM_HELD_FEATURE="$feature"
    CLAIM_HELD_SHA="$commit"
    CLAIM_RESULT="taken-over-from $stale_holder"
    return 0
  fi
  if ! read_out="$(claim_read "$feature")"; then
    printf 'runner: claim: takeover of %s on %s failed:\n%s\n' "$ref" "$remote" "$push_out" >&2
    return 1
  fi
  if [ -z "$read_out" ]; then
    printf 'runner: claim: takeover of %s on %s failed and no claim is there:\n%s\n' \
      "$ref" "$remote" "$push_out" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$read_out" | head -n 1)" = "$stale_sha" ]; then
    # The stale claim is still there: the push failed for another reason.
    printf 'runner: claim: takeover of %s on %s failed:\n%s\n' "$ref" "$remote" "$push_out" >&2
    return 1
  fi
  CLAIM_RESULT="held-by $(claim_read_machine "$read_out")"
  return 0
}

# heartbeat: replace this runner's claim commit with one carrying a fresh
# heartbeat, as a lease push on the sha it last wrote. A refused lease whose
# re-read shows the claim moved means the claim was lost: `lost-to
# <machine>`, and this runner holds nothing (it must not release a claim
# that is no longer its own). Anything else — remote unreachable, claim
# still ours — is `error`, and the claim is still held: the next heartbeat
# point tries again.
claim_heartbeat() {
  local feature="$1"
  local remote ref commit push_out push_rc=0 read_out
  remote="$(claim_shared_remote)"
  ref="$(claim_ref "$feature")"
  if [ "$CLAIM_HELD_FEATURE" != "$feature" ] || [ -z "$CLAIM_HELD_SHA" ]; then
    echo "runner: claim: heartbeat of $feature refused — this runner holds no claim on it" >&2
    CLAIM_RESULT="error"
    return 1
  fi
  if ! commit="$(claim_commit)" || [ -z "$commit" ]; then
    echo "runner: claim: could not write the heartbeat commit for $feature" >&2
    CLAIM_RESULT="error"
    return 1
  fi
  push_out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" push --quiet \
      "--force-with-lease=$ref:$CLAIM_HELD_SHA" "$remote" "$commit:$ref" 2>&1)" || push_rc=$?
  if [ "$push_rc" -eq 0 ]; then
    CLAIM_HELD_SHA="$commit"
    CLAIM_RESULT="ok"
    return 0
  fi
  if ! read_out="$(claim_read "$feature")"; then
    printf 'runner: claim: heartbeat of %s on %s failed (remote unreachable); still holding it:\n%s\n' \
      "$ref" "$remote" "$push_out" >&2
    CLAIM_RESULT="error"
    return 1
  fi
  if [ -n "$read_out" ] && [ "$(printf '%s\n' "$read_out" | head -n 1)" = "$CLAIM_HELD_SHA" ]; then
    printf 'runner: claim: heartbeat of %s on %s failed; the claim is still ours:\n%s\n' \
      "$ref" "$remote" "$push_out" >&2
    CLAIM_RESULT="error"
    return 1
  fi
  # The claim moved: taken over, or deleted by hand (`unknown`).
  CLAIM_HELD_FEATURE=""
  CLAIM_HELD_SHA=""
  if [ -n "$read_out" ]; then
    CLAIM_RESULT="lost-to $(claim_read_machine "$read_out")"
  else
    CLAIM_RESULT="lost-to unknown"
  fi
  return 0
}

# release: lease delete on the sha this runner wrote. A refusal means the
# ref moved; it is left alone.
claim_release() {
  local feature="$1"
  local remote ref push_out push_rc=0
  remote="$(claim_shared_remote)"
  ref="$(claim_ref "$feature")"
  if [ "$CLAIM_HELD_FEATURE" != "$feature" ] || [ -z "$CLAIM_HELD_SHA" ]; then
    echo "runner: claim: release of $feature refused — this runner holds no claim on it" >&2
    CLAIM_RESULT="release-refused"
    return 1
  fi
  push_out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" push --quiet \
      "--force-with-lease=$ref:$CLAIM_HELD_SHA" "$remote" ":$ref" 2>&1)" || push_rc=$?
  # Either way this runner no longer holds a claim it may write.
  CLAIM_HELD_FEATURE=""
  CLAIM_HELD_SHA=""
  if [ "$push_rc" -eq 0 ]; then
    CLAIM_RESULT="released"
    return 0
  fi
  printf 'runner: claim: release of %s on %s refused (the claim moved, or the remote is unreachable); left as it is:\n%s\n' \
    "$ref" "$remote" "$push_out" >&2
  CLAIM_RESULT="release-refused"
  return 1
}

# Entry point: claim take|heartbeat|release <feature>.
claim() {
  local verb="${1:-}" feature="${2:-}" rc=0
  CLAIM_RESULT=""
  if [ -z "$feature" ]; then
    echo "usage: claim take|heartbeat|release <feature>" >&2
    return 2
  fi
  case "$verb" in
    take)      claim_take "$feature" || rc=$? ;;
    heartbeat) claim_heartbeat "$feature" || rc=$? ;;
    release)   claim_release "$feature" || rc=$? ;;
    *)
      echo "usage: claim take|heartbeat|release <feature>" >&2
      return 2
      ;;
  esac
  [ -n "$CLAIM_RESULT" ] && printf '%s\n' "$CLAIM_RESULT"
  return "$rc"
}

# Release whatever claim this runner holds, if any. Idempotent: drain end
# and finalize_run (the EXIT trap every interrupt reaches) both call it.
claim_release_held() {
  [ -n "$CLAIM_HELD_FEATURE" ] || return 0
  local feature="$CLAIM_HELD_FEATURE"
  if claim release "$feature" >/dev/null; then
    echo "[$(date +%H:%M:%S)] runner: released the claim on $feature"
  else
    echo "[$(date +%H:%M:%S)] runner: could not release the claim on $feature (see above)"
  fi
  return 0
}
