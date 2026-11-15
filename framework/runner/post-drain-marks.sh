#!/usr/bin/env bash
# Post-drain mark store — how a feature's Post-drain phase last ended, kept
# as refs on the Shared remote (ADR-0013).
#
# Two marks per feature, each a ref pointing at the feature-branch commit
# (the tip) it records:
#
#     refs/formann/post-drained/<feature>       ok     — the phase ended ok
#                                                        at this tip
#     refs/formann/post-drain-failed/<feature>  failed — a step failed (or
#                                                        ended Blocked a third
#                                                        time) at this tip
#
# A feature with either mark at its tip is not due (post_drain_due in
# post-drain.sh); a new commit on the feature moves the tip off both, and
# deleting the failed mark retries a failure without one:
#
#     git -C <host-repo> push <shared-remote> :refs/formann/post-drain-failed/<feature>
#
# Interface:
#   post_drain_marks read <feature>
#       → `<ok-sha>\t<failed-sha>` (either field empty when that mark is
#         absent). Remembers what it read for the next `set`.
#   post_drain_marks set ok|failed <feature> <tip>
#       → `set` | `lease-refused`
#   post_drain_tip <feature>     → the feature branch's tip sha, or nothing
#   post_drain_refs_listing      → `<sha>\t<ref>` lines: every branch and
#                                  every mark, in ONE read (a drain pass's
#                                  candidate filter)
#
# The rule (the Claim's, claim.sh): this file is the only code that writes
# the mark refs, and every write is a lease on the value the writer last
# read. A refused lease is reported and never retried as a plain or forced
# push: another writer moved the ref, and its value stands.
#
# With no Shared remote (claim_shared_remote_present false) the marks are
# local refs of the same names in the host repo, written with `git
# update-ref <ref> <new> <old>` (the same lease, locally), and the tip is the
# host's own `refs/heads/<feature>` — or, when the host has no such branch,
# the parking ref `refs/remotes/runner/<feature>`: one machine's behaviour.
#
# Every git call runs in $HOST_REPO, with the host's credentials.

# What the last `read` saw, per feature: the lease a later `set` pushes on.
# One feature at a time (the runner ends one feature before the next).
POST_DRAIN_MARKS_SEEN_FEATURE=""
POST_DRAIN_MARK_OK_SEEN=""
POST_DRAIN_MARK_FAILED_SEEN=""
POST_DRAIN_MARKS_RESULT=""

# The ref of a mark. Args: $1 = ok | failed, $2 = feature.
post_drain_mark_ref() {
  case "$1" in
    ok)     printf 'refs/formann/post-drained/%s\n' "$2" ;;
    failed) printf 'refs/formann/post-drain-failed/%s\n' "$2" ;;
    *)      return 2 ;;
  esac
}

# Every branch and every mark as `<sha>\t<ref>` lines, in one read: one
# `git ls-remote` of the Shared remote, or one `git for-each-ref` of the
# host repo without one. Returns 1 (diagnostic on stderr) when the remote
# can't be read.
post_drain_refs_listing() {
  if claim_shared_remote_present; then
    local remote out
    remote="$(claim_shared_remote)"
    if ! out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" ls-remote "$remote" \
        'refs/heads/*' 'refs/formann/post-drained/*' 'refs/formann/post-drain-failed/*' 2>&1)"; then
      printf 'runner: post-drain marks: cannot list %s:\n%s\n' "$remote" "$out" >&2
      return 1
    fi
    printf '%s\n' "$out" | awk -F'\t' 'NF == 2 && $1 ~ /^[0-9a-f]+$/'
  else
    git -C "$HOST_REPO" for-each-ref --format='%(objectname)	%(refname)' \
      refs/heads refs/remotes/runner refs/formann/post-drained refs/formann/post-drain-failed
  fi
}

# Pure: the sha a listing (post_drain_refs_listing) gives a ref, or nothing.
# Args: $1 = listing, $2 = ref.
post_drain_listing_sha() {
  printf '%s\n' "$1" | awk -F'\t' -v r="$2" '$2 == r { print $1; exit }'
}

# Pure: a feature's tip in a listing — its branch, or (no Shared remote, no
# host branch) its parking ref. Args: $1 = listing, $2 = feature.
post_drain_listing_tip() {
  local tip
  tip="$(post_drain_listing_sha "$1" "refs/heads/$2")"
  [ -n "$tip" ] || tip="$(post_drain_listing_sha "$1" "refs/remotes/runner/$2")"
  printf '%s' "$tip"
}

# A feature's tip as it stands now. Prints nothing when the feature has no
# branch; returns 1 when the remote can't be read.
post_drain_tip() {
  local feature="$1" out
  if claim_shared_remote_present; then
    local remote
    remote="$(claim_shared_remote)"
    if ! out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" ls-remote "$remote" \
        "refs/heads/$feature" 2>&1)"; then
      printf 'runner: post-drain marks: cannot read the tip of %s on %s:\n%s\n' "$feature" "$remote" "$out" >&2
      return 1
    fi
    post_drain_listing_sha "$out" "refs/heads/$feature"
  else
    git -C "$HOST_REPO" rev-parse --verify --quiet "refs/heads/$feature^{commit}" 2>/dev/null \
      || git -C "$HOST_REPO" rev-parse --verify --quiet "refs/remotes/runner/$feature^{commit}" 2>/dev/null \
      || true
  fi
}

# read: both marks of a feature. Remembers them as the lease for `set`.
post_drain_marks_read() {
  local feature="$1" ok_ref failed_ref ok="" failed=""
  ok_ref="$(post_drain_mark_ref ok "$feature")"
  failed_ref="$(post_drain_mark_ref failed "$feature")"
  if claim_shared_remote_present; then
    local remote out
    remote="$(claim_shared_remote)"
    if ! out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" ls-remote "$remote" \
        "$ok_ref" "$failed_ref" 2>&1)"; then
      printf 'runner: post-drain marks: cannot read the marks of %s on %s:\n%s\n' "$feature" "$remote" "$out" >&2
      return 1
    fi
    ok="$(post_drain_listing_sha "$out" "$ok_ref")"
    failed="$(post_drain_listing_sha "$out" "$failed_ref")"
  else
    ok="$(git -C "$HOST_REPO" rev-parse --verify --quiet "$ok_ref" 2>/dev/null || true)"
    failed="$(git -C "$HOST_REPO" rev-parse --verify --quiet "$failed_ref" 2>/dev/null || true)"
  fi
  POST_DRAIN_MARKS_SEEN_FEATURE="$feature"
  POST_DRAIN_MARK_OK_SEEN="$ok"
  POST_DRAIN_MARK_FAILED_SEEN="$failed"
  printf '%s\t%s\n' "$ok" "$failed"
}

# Make sure the host repo has the tip's commit, so it can be pushed as a
# mark: fetch the feature branch into a scratch ref when it doesn't (the
# host keeps no ref of its own for it).
_post_drain_have_tip() {
  local feature="$1" tip="$2" remote="$3" scratch
  git -C "$HOST_REPO" cat-file -e "$tip^{commit}" 2>/dev/null && return 0
  scratch="refs/formann/seen/post-drain/$feature"
  GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" fetch --quiet --no-write-fetch-head \
    "$remote" "+refs/heads/$feature:$scratch" >&2 || true
  git -C "$HOST_REPO" update-ref -d "$scratch" >/dev/null 2>&1 || true
  git -C "$HOST_REPO" cat-file -e "$tip^{commit}" 2>/dev/null
}

# set: point a mark at a tip, leasing on the value the last `read` of this
# feature saw (reading first when there was none).
post_drain_marks_set() {
  local kind="$1" feature="$2" tip="$3"
  local ref expect
  if ! ref="$(post_drain_mark_ref "$kind" "$feature")" || [ -z "$tip" ]; then
    echo "usage: post_drain_marks set ok|failed <feature> <tip>" >&2
    return 2
  fi
  if [ "$POST_DRAIN_MARKS_SEEN_FEATURE" != "$feature" ]; then
    post_drain_marks_read "$feature" >/dev/null || return 1
  fi
  if [ "$kind" = "ok" ]; then expect="$POST_DRAIN_MARK_OK_SEEN"; else expect="$POST_DRAIN_MARK_FAILED_SEEN"; fi

  if claim_shared_remote_present; then
    local remote out rc=0
    remote="$(claim_shared_remote)"
    if ! _post_drain_have_tip "$feature" "$tip" "$remote"; then
      printf 'runner: post-drain marks: tip %s of %s is not in the host repo and could not be fetched\n' "$tip" "$feature" >&2
      return 1
    fi
    out="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" push --quiet \
        "--force-with-lease=$ref:$expect" "$remote" "$tip:$ref" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'runner: post-drain marks: set %s of %s on %s refused (another writer moved %s, or the remote is unreachable); left as it is:\n%s\n' \
        "$kind" "$feature" "$remote" "$ref" "$out" >&2
      POST_DRAIN_MARKS_SEEN_FEATURE=""
      POST_DRAIN_MARKS_RESULT="lease-refused"
      return 0
    fi
  else
    if ! git -C "$HOST_REPO" update-ref "$ref" "$tip" "$expect" 2>/dev/null; then
      printf 'runner: post-drain marks: set %s of %s refused (%s moved since it was read); left as it is\n' \
        "$kind" "$feature" "$ref" >&2
      POST_DRAIN_MARKS_SEEN_FEATURE=""
      POST_DRAIN_MARKS_RESULT="lease-refused"
      return 0
    fi
  fi
  if [ "$kind" = "ok" ]; then POST_DRAIN_MARK_OK_SEEN="$tip"; else POST_DRAIN_MARK_FAILED_SEEN="$tip"; fi
  POST_DRAIN_MARKS_RESULT="set"
  return 0
}

# Pure: the command a maintainer runs to delete a mark (the Note on a failed
# phase quotes it). Args: $1 = ok | failed, $2 = feature.
post_drain_mark_delete_recipe() {
  local ref
  ref="$(post_drain_mark_ref "$1" "$2")" || return 2
  if claim_shared_remote_present; then
    printf 'git -C <host-repo> push %s :%s\n' "$(claim_shared_remote)" "$ref"
  else
    printf 'git -C <host-repo> update-ref -d %s\n' "$ref"
  fi
}

# Entry point: post_drain_marks read <feature> | set ok|failed <feature> <tip>.
# `set` prints its result and leaves it in POST_DRAIN_MARKS_RESULT; it
# returns non-zero only on a usage error or an unreadable remote.
post_drain_marks() {
  local verb="${1:-}"
  POST_DRAIN_MARKS_RESULT=""
  case "$verb" in
    read)
      [ -n "${2:-}" ] || { echo "usage: post_drain_marks read <feature>" >&2; return 2; }
      post_drain_marks_read "$2"
      ;;
    set)
      local rc=0
      post_drain_marks_set "${2:-}" "${3:-}" "${4:-}" || rc=$?
      [ -n "$POST_DRAIN_MARKS_RESULT" ] && printf '%s\n' "$POST_DRAIN_MARKS_RESULT"
      return "$rc"
      ;;
    *)
      echo "usage: post_drain_marks read <feature> | set ok|failed <feature> <tip>" >&2
      return 2
      ;;
  esac
}
