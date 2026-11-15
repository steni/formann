#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Post-drain mark store (post-drain-marks.sh, #38) against a bare repository
# standing in for the Shared remote, and — without a Shared remote — the host
# repo's own refs.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  # shellcheck source=../claim.sh
  source "$HERE/../claim.sh"
  # shellcheck source=../post-drain-marks.sh
  source "$HERE/../post-drain-marks.sh"
  unset RUNNER_SHARED_REMOTE

  SHARED="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$SHARED"
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  git init --quiet --initial-branch=main "$HOST_REPO"
  git -C "$HOST_REPO" remote add origin "$SHARED"
  TIP1="$(commit_on alpha one)"
  git -C "$HOST_REPO" push --quiet origin alpha
}

# Commit on branch $1 of the host repo; print the new sha.
commit_on() {
  git -C "$HOST_REPO" checkout --quiet -B "$1" 2>/dev/null
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m "$2"
  git -C "$HOST_REPO" rev-parse HEAD
}

remote_ref() {
  git -C "$SHARED" rev-parse --verify --quiet "$1" || true
}

@test "mark refs — ok is refs/formann/post-drained/<feature>, failed refs/formann/post-drain-failed/<feature>" {
  [ "$(post_drain_mark_ref ok alpha)" = "refs/formann/post-drained/alpha" ]
  [ "$(post_drain_mark_ref failed alpha)" = "refs/formann/post-drain-failed/alpha" ]
  run post_drain_mark_ref waiting alpha
  assert_failure
}

@test "read — no marks: both fields empty" {
  run post_drain_marks read alpha
  assert_success
  assert_output "$(printf '\t')"
}

@test "set then read — each mark lands on the Shared remote at the tip, and reads back" {
  run post_drain_marks set ok alpha "$TIP1"
  assert_success
  assert_output "set"
  [ "$(remote_ref refs/formann/post-drained/alpha)" = "$TIP1" ]

  local tip2
  tip2="$(commit_on alpha two)"
  git -C "$HOST_REPO" push --quiet origin alpha
  run post_drain_marks set failed alpha "$tip2"
  assert_output "set"
  [ "$(remote_ref refs/formann/post-drain-failed/alpha)" = "$tip2" ]

  run post_drain_marks read alpha
  assert_success
  assert_output "$TIP1	$tip2"
  # The host keeps no mark refs of its own.
  [ -z "$(git -C "$HOST_REPO" for-each-ref refs/formann)" ]
}

@test "set — moves a mark it read to a new tip" {
  post_drain_marks set ok alpha "$TIP1" >/dev/null
  local tip2
  tip2="$(commit_on alpha two)"
  git -C "$HOST_REPO" push --quiet origin alpha
  post_drain_marks_read alpha >/dev/null
  post_drain_marks set ok alpha "$tip2" >/dev/null
  [ "$POST_DRAIN_MARKS_RESULT" = "set" ]
  [ "$(remote_ref refs/formann/post-drained/alpha)" = "$tip2" ]
}

@test "set — a refused lease (another writer moved the ref since the read) is reported, and the other writer's value stands" {
  post_drain_marks_read alpha >/dev/null
  # Another machine sets the ok mark meanwhile.
  local other="$BATS_TEST_TMPDIR/other" tip2
  git clone --quiet --branch alpha "$SHARED" "$other"
  git -C "$other" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m other
  tip2="$(git -C "$other" rev-parse HEAD)"
  git -C "$other" push --quiet origin "HEAD:refs/heads/alpha" "HEAD:refs/formann/post-drained/alpha"

  run --separate-stderr post_drain_marks set ok alpha "$TIP1"
  assert_success
  assert_output "lease-refused"
  [[ "$stderr" == *"refused"* ]]
  [ "$(remote_ref refs/formann/post-drained/alpha)" = "$tip2" ]
}

@test "set — a tip the host does not have is fetched from the feature branch first" {
  local other="$BATS_TEST_TMPDIR/other" tip2
  git clone --quiet "$SHARED" "$other"
  git -C "$other" checkout --quiet alpha
  git -C "$other" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m elsewhere
  tip2="$(git -C "$other" rev-parse HEAD)"
  git -C "$other" push --quiet origin alpha
  ! git -C "$HOST_REPO" cat-file -e "$tip2^{commit}" 2>/dev/null

  run post_drain_marks set ok alpha "$tip2"
  assert_output "set"
  [ "$(remote_ref refs/formann/post-drained/alpha)" = "$tip2" ]
  [ -z "$(git -C "$HOST_REPO" for-each-ref refs/formann)" ]
}

@test "post_drain_tip — the feature branch on the Shared remote; nothing for a feature with no branch" {
  [ "$(post_drain_tip alpha)" = "$TIP1" ]
  [ -z "$(post_drain_tip beta)" ]
}

@test "post_drain_refs_listing — one read carries every branch and every mark" {
  post_drain_marks set failed alpha "$TIP1" >/dev/null
  local listing
  listing="$(post_drain_refs_listing)"
  [ "$(post_drain_listing_tip "$listing" alpha)" = "$TIP1" ]
  [ "$(post_drain_listing_sha "$listing" refs/formann/post-drain-failed/alpha)" = "$TIP1" ]
  [ -z "$(post_drain_listing_sha "$listing" refs/formann/post-drained/alpha)" ]
  [ -z "$(post_drain_listing_tip "$listing" beta)" ]
}

@test "no Shared remote — the marks are local refs in the host repo, with the same lease" {
  git -C "$HOST_REPO" remote remove origin
  [ "$(post_drain_tip alpha)" = "$TIP1" ]

  run post_drain_marks set ok alpha "$TIP1"
  assert_output "set"
  [ "$(git -C "$HOST_REPO" rev-parse refs/formann/post-drained/alpha)" = "$TIP1" ]
  run post_drain_marks read alpha
  assert_output "$TIP1	"

  # A lease on a stale read is refused locally too.
  post_drain_marks_read alpha >/dev/null
  local tip2
  tip2="$(commit_on alpha two)"
  git -C "$HOST_REPO" update-ref refs/formann/post-drained/alpha "$tip2"
  run --separate-stderr post_drain_marks set ok alpha "$TIP1"
  assert_output "lease-refused"
  [ "$(git -C "$HOST_REPO" rev-parse refs/formann/post-drained/alpha)" = "$tip2" ]

  local listing
  listing="$(post_drain_refs_listing)"
  [ "$(post_drain_listing_tip "$listing" alpha)" = "$tip2" ]
  [ "$(post_drain_listing_sha "$listing" refs/formann/post-drained/alpha)" = "$tip2" ]
}

@test "no Shared remote — without a host branch, the parking ref is the tip" {
  git -C "$HOST_REPO" remote remove origin
  git -C "$HOST_REPO" checkout --quiet main 2>/dev/null || git -C "$HOST_REPO" checkout --quiet --orphan main
  git -C "$HOST_REPO" update-ref refs/remotes/runner/gamma "$TIP1"
  [ "$(post_drain_tip gamma)" = "$TIP1" ]
  [ "$(post_drain_listing_tip "$(post_drain_refs_listing)" gamma)" = "$TIP1" ]
}

@test "post_drain_mark_delete_recipe — names the push of the deletion, or the local update-ref without a Shared remote" {
  [ "$(post_drain_mark_delete_recipe failed alpha)" = "git -C <host-repo> push origin :refs/formann/post-drain-failed/alpha" ]
  git -C "$HOST_REPO" remote remove origin
  [ "$(post_drain_mark_delete_recipe ok alpha)" = "git -C <host-repo> update-ref -d refs/formann/post-drained/alpha" ]
}

# === Structural claim ========================================================

# The mark store is the only writer of the post-drain refs: no other runner
# script names a mark ref, or writes (push / update-ref) through
# post_drain_mark_ref.
mark_store_writers() {
  local dir="${1:-$HERE/..}"
  grep -RIl --include='*.sh' -e 'refs/formann/post-drain' "$dir" | grep -v '/post-drain-marks\.sh$' || true
  grep -RIn --include='*.sh' -e 'post_drain_mark_ref' "$dir" \
    | grep -v '^[^:]*/post-drain-marks\.sh:' \
    | grep -E 'push|update-ref' || true
}

@test "structural claim — post-drain-marks.sh is the only writer of the post-drain refs" {
  run mark_store_writers
  assert_success
  assert_output ""
}

@test "structural claim — the check catches a second writer" {
  local copy="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$copy"
  cp "$HERE"/../*.sh "$copy/"
  printf '%s\n' 'rogue() { git -C "$HOST_REPO" push origin "$1:$(post_drain_mark_ref ok "$2")"; }' >>"$copy/post-drain.sh"
  run mark_store_writers "$copy"
  assert_output --partial "post-drain.sh"
  cp "$HERE"/../post-drain.sh "$copy/post-drain.sh"
  printf '%s\n' 'rogue() { git -C "$HOST_REPO" update-ref refs/formann/post-drained/x HEAD; }' >>"$copy/run-the-queue.sh"
  run mark_store_writers "$copy"
  assert_output --partial "run-the-queue.sh"
}
