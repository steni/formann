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

  unset RUNNER_SHARED_REMOTE RUNNER_FORMANN_SHA RUNNER_CLAIM_STALE_AFTER
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
  run claim steal alpha
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

# === Heartbeat, staleness and takeover (#8) ================================

HB="2026-11-08T12:00:00Z"
HB_EPOCH=1794139200   # $HB in epoch seconds

# Push a claim for machine $2 on feature $1 with heartbeat $3, from that
# machine's own host repo. Prints the claim's sha.
plant_claim() {
  local feature="$1" machine="$2" hb="$3" dir tree sha
  dir="$BATS_TEST_TMPDIR/planted-$machine"
  [ -d "$dir" ] || new_host "planted-$machine" >/dev/null
  tree="$(git -C "$dir" mktree </dev/null)"
  sha="$(claim_message "$machine" r0 unknown "$hb" \
    | git -C "$dir" -c user.email=t@t -c user.name=t commit-tree "$tree")"
  git -C "$dir" push --quiet --force origin "$sha:refs/formann/claims/$feature"
  printf '%s\n' "$sha"
}

remote_claim_field() {
  claim_field "$(git -C "$SHARED" log -1 --format=%B "refs/formann/claims/$1")" "$2"
}

@test "claim_iso_to_epoch — matches the epoch of known UTC times; rejects anything else" {
  [ "$(claim_iso_to_epoch 1970-01-01T00:00:00Z)" = "0" ]
  [ "$(claim_iso_to_epoch 2000-03-01T00:00:00Z)" = "951868800" ]
  [ "$(claim_iso_to_epoch 2024-02-29T23:59:59Z)" = "1709251199" ]
  [ "$(claim_iso_to_epoch "$HB")" = "$HB_EPOCH" ]
  # The runner's own heartbeat format round-trips against this clock.
  local now iso
  now="$(date +%s)"
  iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ $(( $(claim_iso_to_epoch "$iso") - now )) -ge 0 ]
  [ $(( $(claim_iso_to_epoch "$iso") - now )) -le 2 ]
  run claim_iso_to_epoch "2026-11-08 12:00:00"
  assert_failure
  run claim_iso_to_epoch ""
  assert_failure
}

@test "claim_verdict — held up to thirty minutes after the heartbeat, stale after; nobody writes stale" {
  local msg
  msg="$(claim_message m2 r1 unknown "$HB")"
  run claim_verdict "$msg" $(( HB_EPOCH + 29 * 60 )) 1800
  assert_output "held"
  run claim_verdict "$msg" $(( HB_EPOCH + 1800 )) 1800
  assert_output "held"
  run claim_verdict "$msg" $(( HB_EPOCH + 1801 )) 1800
  assert_output "stale"
  run claim_verdict "$msg" $(( HB_EPOCH + 31 * 60 )) 1800
  assert_output "stale"
  # A heartbeat in the reader's future (clock skew) is held.
  run claim_verdict "$msg" $(( HB_EPOCH - 600 )) 1800
  assert_output "held"
  # A heartbeat that can't be read is never judged stale.
  run claim_verdict "$(claim_message m2 r1 unknown garbage)" $(( HB_EPOCH + 99999 )) 1800
  assert_output "held"
}

@test "claim take — a 29-minute-old heartbeat is held: held-by, the claim untouched" {
  local planted
  planted="$(plant_claim alpha m2 "$HB")"
  claim_now_epoch() { echo $(( HB_EPOCH + 29 * 60 )); }

  claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "held-by m2" ]
  [ -z "$CLAIM_HELD_FEATURE" ]
  [ "$(remote_claim_sha alpha)" = "$planted" ]
}

@test "claim take — a 31-minute-old heartbeat is stale: taken-over-from <machine>, the claim is now this runner's" {
  local planted
  planted="$(plant_claim alpha m2 "$HB")"
  claim_now_epoch() { echo $(( HB_EPOCH + 31 * 60 )); }

  claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "taken-over-from m2" ]
  [ "$CLAIM_HELD_FEATURE" = "alpha" ]
  [ "$CLAIM_HELD_SHA" = "$(remote_claim_sha alpha)" ]
  [ "$(remote_claim_sha alpha)" != "$planted" ]
  [ "$(remote_claim_field alpha machine)" = "m1" ]
}

@test "claim take — RUNNER_CLAIM_STALE_AFTER sets the threshold" {
  plant_claim alpha m2 "$HB" >/dev/null
  claim_now_epoch() { echo $(( HB_EPOCH + 120 )); }
  RUNNER_CLAIM_STALE_AFTER=60 claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "taken-over-from m2" ]
}

@test "claim heartbeat — replaces the holder's claim with a fresh heartbeat, a lease on its last sha" {
  claim_now_epoch() { date +%s; }
  local before_sha
  plant_claim alpha m1 2000-01-01T00:00:00Z >/dev/null
  # This runner holds that (old) claim.
  CLAIM_HELD_FEATURE="alpha"
  CLAIM_HELD_SHA="$(remote_claim_sha alpha)"
  before_sha="$CLAIM_HELD_SHA"

  run claim heartbeat alpha
  assert_success
  assert_output "ok"
  claim heartbeat alpha >/dev/null
  [ "$CLAIM_RESULT" = "ok" ]
  [ "$CLAIM_HELD_SHA" = "$(remote_claim_sha alpha)" ]
  [ "$CLAIM_HELD_SHA" != "$before_sha" ]
  [ "$(remote_claim_field alpha machine)" = "m1" ]
  [ "$(claim_verdict "$(git -C "$SHARED" log -1 --format=%B "$CLAIM_HELD_SHA")" "$(date +%s)" 1800)" = "held" ]
  local age
  age=$(( $(date +%s) - $(claim_iso_to_epoch "$(remote_claim_field alpha heartbeat)") ))
  [ "$age" -le 5 ]
}

@test "claim heartbeat — after a takeover: lost-to <machine>, the new holder's claim untouched, nothing left to release" {
  claim take alpha >/dev/null
  [ "$CLAIM_RESULT" = "taken" ]
  # Another runner takes over (it judged the claim stale by its clock).
  local other other_sha
  other="$(new_host other)"
  other_sha="$(
    HOST_REPO="$other"; RUNNER_MACHINE="m2"
    claim_now_epoch() { echo $(( $(date +%s) + 3600 )); }
    claim take alpha >/dev/null
    [ "$CLAIM_RESULT" = "taken-over-from m1" ] || exit 1
    echo "$CLAIM_HELD_SHA"
  )"
  [ "$(remote_claim_sha alpha)" = "$other_sha" ]

  claim heartbeat alpha >/dev/null
  [ "$CLAIM_RESULT" = "lost-to m2" ]
  [ -z "$CLAIM_HELD_FEATURE" ]
  [ -z "$CLAIM_HELD_SHA" ]
  [ "$(remote_claim_sha alpha)" = "$other_sha" ]
  # Release is now a no-op; m2's claim stays.
  claim_release_held >/dev/null
  [ "$(remote_claim_sha alpha)" = "$other_sha" ]
}

@test "claim heartbeat — unreachable Shared remote: error, the claim still held for the next try" {
  claim take alpha >/dev/null
  local held="$CLAIM_HELD_SHA"
  git -C "$HOST_REPO" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"

  run --separate-stderr claim heartbeat alpha
  assert_failure 1
  assert_output "error"
  claim heartbeat alpha >/dev/null 2>&1 || true
  [ "$CLAIM_RESULT" = "error" ]
  [ "$CLAIM_HELD_FEATURE" = "alpha" ]
  [ "$CLAIM_HELD_SHA" = "$held" ]

  # Back online: the next heartbeat succeeds on the same lease.
  git -C "$HOST_REPO" remote set-url origin "$SHARED"
  claim heartbeat alpha >/dev/null
  [ "$CLAIM_RESULT" = "ok" ]
}

@test "claim heartbeat — a feature this runner doesn't hold: error, nothing written" {
  run --separate-stderr claim heartbeat alpha
  assert_failure 1
  assert_output "error"
  [ -z "$(remote_claim_sha alpha)" ]
}

@test "claim take — a takeover racing a late heartbeat: exactly one wins" {
  local round holder taker out_h out_t planted wins
  for round in 1 2 3 4 5 6 7 8; do
    planted="$(plant_claim "f$round" mh 2000-01-01T00:00:00Z)"
    holder="$(new_host "hold-$round")"
    taker="$(new_host "take-$round")"
    out_h="$BATS_TEST_TMPDIR/out-h-$round"
    out_t="$BATS_TEST_TMPDIR/out-t-$round"
    # The holder comes back to life and heart-beats on its stale claim while
    # the taker, judging it stale, takes it over.
    ( HOST_REPO="$holder" RUNNER_MACHINE="mh"; source "$CLAIM_SH"
      CLAIM_HELD_FEATURE="f$round"; CLAIM_HELD_SHA="$planted"
      claim heartbeat "f$round" ) >"$out_h" 2>/dev/null &
    ( HOST_REPO="$taker" RUNNER_MACHINE="mt"; source "$CLAIM_SH"
      claim take "f$round" ) >"$out_t" 2>/dev/null &
    wait
    local results="$(cat "$out_h"),$(cat "$out_t")"
    case "$results" in
      "ok,held-by mh")
        [ "$(remote_claim_field "f$round" machine)" = "mh" ] || fail "round $round: $results but the claim is not mh's" ;;
      "lost-to mt,taken-over-from mh")
        [ "$(remote_claim_field "f$round" machine)" = "mt" ] || fail "round $round: $results but the claim is not mt's" ;;
      *) fail "round $round: expected exactly one winner, got '$results'" ;;
    esac
    [ "$(remote_claim_sha "f$round")" != "$planted" ]
  done
}
