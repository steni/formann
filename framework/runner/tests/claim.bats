#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Claim (claim.sh) against a bare repository standing in for the Shared
# remote. Tests check what a caller can see: which refs exist on the bare
# repo, what `claim` and `claim_verdict` return.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  CLAIM_SH="$HERE/../claim.sh"
  # shellcheck source=../claim.sh
  source "$CLAIM_SH"

  unset RUNNER_SHARED_REMOTE RUNNER_FORMANN_SHA
  SHARED="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$SHARED"
  HOST_REPO="$(new_host host)"
  RUNNER_MACHINE="m1"
  RUN_TS="20261108-120000"
}

# A host repo whose `origin` is the Shared remote. Prints its path.
new_host() {
  local dir="$BATS_TEST_TMPDIR/$1"
  git init --quiet --initial-branch=main "$dir"
  git -C "$dir" remote add origin "$SHARED"
  printf '%s\n' "$dir"
}

remote_claim_sha() {
  git -C "$SHARED" rev-parse --verify --quiet "refs/formann/claims/$1" || true
}

@test "claim take — absent claim: taken, the ref exists on the Shared remote with machine, run, formann and heartbeat" {
  run claim take alpha
  assert_success
  assert_output "taken"

  local sha msg
  sha="$(remote_claim_sha alpha)"
  [ -n "$sha" ]
  # Parentless, empty tree.
  [ -z "$(git -C "$SHARED" rev-list --parents -n 1 "$sha" | cut -s -d' ' -f2)" ]
  [ "$(git -C "$SHARED" rev-parse "$sha^{tree}")" = "$(git -C "$SHARED" mktree </dev/null)" ]
  msg="$(git -C "$SHARED" log -1 --format=%B "$sha")"
  [ "$(claim_field "$msg" machine)" = "m1" ]
  [ "$(claim_field "$msg" run)" = "20261108-120000" ]
  [ "$(claim_field "$msg" formann)" = "unknown" ]
  [[ "$(claim_field "$msg" heartbeat)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "claim take — in the runner's shell: holds the claim it wrote (CLAIM_RESULT, CLAIM_HELD_*)" {
  claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "taken" ]
  [ "$CLAIM_HELD_FEATURE" = "alpha" ]
  [ "$CLAIM_HELD_SHA" = "$(remote_claim_sha alpha)" ]
}

@test "claim take — a feature another machine holds: held-by <machine>, the claim untouched, the host keeps no claim refs" {
  local other
  other="$(new_host other)"
  ( HOST_REPO="$other" RUNNER_MACHINE="m2"; claim take alpha >/dev/null )
  local before
  before="$(remote_claim_sha alpha)"

  run claim take alpha
  assert_success
  assert_output "held-by m2"
  [ "$(remote_claim_sha alpha)" = "$before" ]
  [ -z "$(git -C "$HOST_REPO" for-each-ref refs/formann/)" ]
}

@test "claim take — two runners racing for one free feature: exactly one taken, the other held-by the winner" {
  local round a b out_a out_b
  for round in 1 2 3 4 5 6; do
    a="$(new_host "race-a-$round")"
    b="$(new_host "race-b-$round")"
    out_a="$BATS_TEST_TMPDIR/out-a-$round"
    out_b="$BATS_TEST_TMPDIR/out-b-$round"
    ( HOST_REPO="$a" RUNNER_MACHINE="ma"; source "$CLAIM_SH"; claim take "f$round" ) >"$out_a" 2>/dev/null &
    ( HOST_REPO="$b" RUNNER_MACHINE="mb"; source "$CLAIM_SH"; claim take "f$round" ) >"$out_b" 2>/dev/null &
    wait
    local results
    results="$(cat "$out_a" "$out_b" | sort | paste -sd ',' -)"
    case "$results" in
      "held-by mb,taken")
        [ "$(cat "$out_a")" = "held-by mb" ] || fail "round $round: a lost to itself: $results" ;;
      "held-by ma,taken")
        [ "$(cat "$out_b")" = "held-by ma" ] || fail "round $round: b lost to itself: $results" ;;
      *) fail "round $round: expected one taken and one held-by, got '$results'" ;;
    esac
    # The winner's claim is the one on the remote.
    local winner
    if [ "$(cat "$out_a")" = "taken" ]; then winner=ma; else winner=mb; fi
    [ "$(claim_field "$(git -C "$SHARED" log -1 --format=%B "refs/formann/claims/f$round")" machine)" = "$winner" ]
  done
}

@test "claim release — the holder's release deletes the ref" {
  claim take alpha >/dev/null
  [ -n "$(remote_claim_sha alpha)" ]

  claim release alpha >/dev/null
  [ "$CLAIM_RESULT" = "released" ]
  [ -z "$(remote_claim_sha alpha)" ]
  [ -z "$CLAIM_HELD_FEATURE" ]
}

@test "claim release — after the ref moved: refused, the other writer's claim left as it is" {
  claim take alpha >/dev/null
  # Another runner's claim replaces ours (as a takeover would).
  local other other_sha
  other="$(new_host other)"
  other_sha="$(cd "$other" && HOST_REPO="$other" RUNNER_MACHINE="m2" claim_commit)"
  git -C "$other" push --quiet --force origin "$other_sha:refs/formann/claims/alpha"

  run --separate-stderr claim release alpha
  assert_failure 1
  assert_output "release-refused"
  [ "$(remote_claim_sha alpha)" = "$other_sha" ]
}

@test "claim release — a feature this runner doesn't hold: refused, nothing deleted" {
  local other
  other="$(new_host other)"
  ( HOST_REPO="$other" RUNNER_MACHINE="m2"; claim take alpha >/dev/null )
  local before
  before="$(remote_claim_sha alpha)"

  run --separate-stderr claim release alpha
  assert_failure 1
  assert_output "release-refused"
  [ "$(remote_claim_sha alpha)" = "$before" ]
}

@test "claim_release_held — releases the held claim and is a no-op once released" {
  claim take alpha >/dev/null
  claim_release_held >/dev/null
  [ -z "$(remote_claim_sha alpha)" ]
  run claim_release_held
  assert_success
  assert_output ""
}

@test "claim take — unreachable Shared remote: fails, holds nothing" {
  git -C "$HOST_REPO" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run claim take alpha
  assert_failure 1
  claim take alpha >/dev/null 2>&1 || true
  [ -z "$CLAIM_HELD_FEATURE" ]
}

@test "claim_shared_remote_present — follows RUNNER_SHARED_REMOTE; no such remote means no claims" {
  claim_shared_remote_present
  RUNNER_SHARED_REMOTE="shared" run claim_shared_remote_present
  assert_failure
  git -C "$HOST_REPO" remote add shared "$SHARED"
  RUNNER_SHARED_REMOTE="shared" claim_shared_remote_present
}

@test "claim — usage errors exit 2" {
  run claim take
  assert_failure 2
  run claim heartbeat alpha
  assert_failure 2
}

@test "claim_verdict — empty message is free; a claim message is held" {
  run claim_verdict "" 1000 1800
  assert_output "free"
  run claim_verdict $'\n  \n' 1000 1800
  assert_output "free"
  run claim_verdict "$(claim_message m1 r1 unknown 2026-11-08T12:00:00Z)" 1000 1800
  assert_output "held"
}

@test "claim_field — reads each field of claim_message" {
  local msg
  msg="$(claim_message box-1 20261108-1 abc123 2026-11-08T12:00:00Z)"
  [ "$(claim_field "$msg" machine)" = "box-1" ]
  [ "$(claim_field "$msg" run)" = "20261108-1" ]
  [ "$(claim_field "$msg" formann)" = "abc123" ]
  [ "$(claim_field "$msg" heartbeat)" = "2026-11-08T12:00:00Z" ]
  [ -z "$(claim_field "$msg" nope)" ]
}
