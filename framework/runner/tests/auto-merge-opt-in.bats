#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Auto-merge opt-in (auto-merge-opt-in, #39, ADR-0015) against a bare
# repository standing in for the Shared remote and the github-issues
# binding's comment-on-feature driven through a `gh` shim — and, without a
# Shared remote, the host repo's own refs under the local-markdown binding.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  OPT_IN="$HERE/../auto-merge-opt-in"
  BINDINGS="$HERE/../../bindings/issue-tracker"
  unset RUNNER_SHARED_REMOTE HOST_REPO

  SHARED="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$SHARED"
  HOST="$BATS_TEST_TMPDIR/host"
  git init --quiet --initial-branch=main "$HOST"
  git -C "$HOST" config user.name "Maintainer Name"
  git -C "$HOST" config user.email m@example.com
  git -C "$HOST" commit --allow-empty --quiet -m init
  git -C "$HOST" remote add origin "$SHARED"
  mkdir -p "$HOST/docs/formann"
  ln -s "$BINDINGS/github-issues" "$HOST/docs/formann/issue-tracker"

  # gh shim. `issue list` prints $GH_PARENTS (one number per line); `issue
  # view` prints no comments; `issue comment` appends its issue number and
  # body to $GH_LOG.comments, one record per call.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")  printf '%s' "$GH_PARENTS"; exit 0 ;;
  "issue view")  printf '%s' '{"comments":[]}'; exit 0 ;;
  "issue comment")
    num="$3"; shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '=== #%s\n%s\n' "$num" "$body" >>"$GH_LOG.comments"
    exit 0 ;;
esac
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"
  export PATH="$FAKE_BIN:$PATH"
  export GH_TRACKER_REPO="test-owner/test-repo"
  export GH_LOG="$BATS_TEST_TMPDIR/gh"
  export GH_PARENTS=$'12\n'
}

notes() {
  if [ -f "$GH_LOG.comments" ]; then grep -c '^=== #12$' "$GH_LOG.comments"; else echo 0; fi
}

remote_ref() {
  git -C "$SHARED" rev-parse --verify --quiet "$1" || true
}

opt_in() {
  ( cd "$HOST" && "$OPT_IN" "$@" )
}

@test "grant then read — the ref lands on the Shared remote, read says opted-in, one Note on the parent" {
  run --separate-stderr opt_in grant alpha
  assert_success
  assert_output "granted"
  local sha
  sha="$(remote_ref refs/formann/auto-merge/alpha)"
  [ -n "$sha" ]
  # A parentless commit on the empty tree, recording who and when.
  [ -z "$(git -C "$SHARED" log -1 --format=%P "$sha")" ]
  [ "$(git -C "$SHARED" log -1 --format=%T "$sha")" = "4b825dc642cb6eb9a060e54bf8d69288fbee4904" ]
  local msg
  msg="$(git -C "$SHARED" log -1 --format=%B "$sha")"
  [[ "$msg" == *"feature: alpha"* ]]
  [[ "$msg" == *"granted-by: Maintainer Name"* ]]
  [[ "$msg" =~ granted-at:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]]
  # The host keeps no opt-in ref of its own.
  [ -z "$(git -C "$HOST" for-each-ref refs/formann)" ]

  [ "$(notes)" = "1" ]
  grep -q "^### Note — " "$GH_LOG.comments"
  grep -q "Opted into auto-merge\*\* by Maintainer Name" "$GH_LOG.comments"
  grep -q "auto-merge-opt-in revoke alpha" "$GH_LOG.comments"
  grep -q "not a release" "$GH_LOG.comments"

  run --separate-stderr opt_in read alpha
  assert_success
  assert_output "opted-in"
}

@test "grant twice — the second is a no-op: same ref, no new Note" {
  opt_in grant alpha >/dev/null
  local sha
  sha="$(remote_ref refs/formann/auto-merge/alpha)"
  run --separate-stderr opt_in grant alpha
  assert_success
  assert_output "already-opted-in"
  [ "$(remote_ref refs/formann/auto-merge/alpha)" = "$sha" ]
  [ "$(notes)" = "1" ]
}

@test "revoke then read — the ref is deleted, read says not-opted-in, a second Note on the parent" {
  opt_in grant alpha >/dev/null
  run --separate-stderr opt_in revoke alpha
  assert_success
  assert_output "revoked"
  [ -z "$(remote_ref refs/formann/auto-merge/alpha)" ]
  [ "$(notes)" = "2" ]
  grep -q "Auto-merge opt-in revoked\*\* by Maintainer Name" "$GH_LOG.comments"

  run --separate-stderr opt_in read alpha
  assert_success
  assert_output "not-opted-in"
}

@test "revoke without an opt-in — a no-op, no Note" {
  run --separate-stderr opt_in revoke alpha
  assert_success
  assert_output "not-opted-in"
  [ "$(notes)" = "0" ]
}

@test "read without an opt-in — not-opted-in, exit 0" {
  run --separate-stderr opt_in read alpha
  assert_success
  assert_output "not-opted-in"
}

@test "grant with no open feature parent — exit 1, nothing pushed, nothing posted" {
  export GH_PARENTS=""
  run --separate-stderr opt_in grant alpha
  assert_failure 1
  [[ "$stderr" == *"no open feature parent"* ]]
  [ -z "$(remote_ref refs/formann/auto-merge/alpha)" ]
  [ -z "$(git -C "$SHARED" for-each-ref)" ]
  [ ! -f "$GH_LOG.comments" ]
}

@test "grant on a slug collision — exit 1, nothing pushed" {
  export GH_PARENTS=$'3\n9\n'
  run --separate-stderr opt_in grant alpha
  assert_failure 1
  [ -z "$(remote_ref refs/formann/auto-merge/alpha)" ]
}

@test "an unreachable Shared remote — read and grant exit 3" {
  git -C "$HOST" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run --separate-stderr opt_in read alpha
  assert_failure 3
  run --separate-stderr opt_in grant alpha
  assert_failure 3
  [ ! -f "$GH_LOG.comments" ]
}

@test "a tracker that can't be reached — grant exits 3 and pushes nothing" {
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"
  # comment-on-feature retries with backoff; keep the test fast.
  sleep() { :; }; export -f sleep
  run --separate-stderr opt_in grant alpha
  assert_failure 3
  [ -z "$(remote_ref refs/formann/auto-merge/alpha)" ]
}

@test "usage errors — exit 2" {
  run --separate-stderr opt_in
  assert_failure 2
  run --separate-stderr opt_in allow alpha
  assert_failure 2
  run --separate-stderr opt_in grant ""
  assert_failure 2
  run --separate-stderr opt_in grant "a/b"
  assert_failure 2
  run --separate-stderr opt_in grant "bad..slug"
  assert_failure 2
}

@test "RUNNER_SHARED_REMOTE names the Shared remote" {
  git -C "$HOST" remote rename origin shared
  export RUNNER_SHARED_REMOTE=shared
  export GH_TRACKER_REPO="test-owner/test-repo"
  run --separate-stderr opt_in grant alpha
  assert_success
  [ -n "$(remote_ref refs/formann/auto-merge/alpha)" ]
}

@test "no Shared remote, local-markdown — a local ref in the host repo, and the Notes land in the PRD" {
  git -C "$HOST" remote remove origin
  rm "$HOST/docs/formann/issue-tracker"
  ln -s "$BINDINGS/local-markdown" "$HOST/docs/formann/issue-tracker"
  mkdir -p "$HOST/.formann" "$HOST/.features/alpha"
  printf '# Alpha\n\n## Gist\n\nA feature.\n' >"$HOST/.features/alpha/PRD.md"
  git -C "$HOST" add .features
  git -C "$HOST" commit --quiet -m prd

  run --separate-stderr opt_in grant beta
  assert_failure 1
  [ -z "$(git -C "$HOST" for-each-ref refs/formann)" ]

  run --separate-stderr opt_in grant alpha
  assert_success
  assert_output "granted"
  git -C "$HOST" rev-parse --verify --quiet refs/formann/auto-merge/alpha >/dev/null
  grep -q "Opted into auto-merge" "$HOST/.features/alpha/PRD.md"
  grep -q "in the host repo (no Shared remote)" "$HOST/.features/alpha/PRD.md"
  [ "$(git -C "$HOST" log -1 --format=%s)" = "tracker: alpha — Note on the feature" ]
  run opt_in read alpha
  assert_output "opted-in"

  run opt_in grant alpha
  assert_output "already-opted-in"

  run --separate-stderr opt_in revoke alpha
  assert_success
  assert_output "revoked"
  ! git -C "$HOST" rev-parse --verify --quiet refs/formann/auto-merge/alpha
  grep -q "Auto-merge opt-in revoked" "$HOST/.features/alpha/PRD.md"
  run opt_in read alpha
  assert_output "not-opted-in"
}

# === Structural claim ========================================================

# No runner code path grants or revokes an opt-in: run-the-queue.sh and the
# scripts it sources (every *.sh beside it) never invoke `auto-merge-opt-in
# grant|revoke`, and never write (push / update-ref) an auto-merge ref.
opt_in_writers() {
  local dir="${1:-$HERE/..}"
  grep -RIn --include='*.sh' -E 'auto-merge-opt-in["'"'"']?[[:space:]]+(grant|revoke)' "$dir" || true
  grep -RIn --include='*.sh' -e 'refs/formann/auto-merge' "$dir" | grep -E 'push|update-ref' || true
}

@test "structural claim — no runner code path calls grant or revoke" {
  # The sourced set is what this check scans: every source line of
  # run-the-queue.sh names a *.sh beside it.
  run bash -c "grep -E '^[[:space:]]*(source|\\.)[[:space:]]' '$HERE/../run-the-queue.sh' | grep -v '\\.sh\"\$'"
  assert_output ""
  run opt_in_writers
  assert_success
  assert_output ""
}

@test "structural claim — the check catches a runner path that grants or writes the ref" {
  local copy="$BATS_TEST_TMPDIR/runner"
  mkdir -p "$copy"
  cp "$HERE"/../*.sh "$copy/"
  printf '%s\n' 'rogue() { "$HERE/auto-merge-opt-in" grant "$1"; }' >>"$copy/post-drain.sh"
  run opt_in_writers "$copy"
  assert_output --partial "post-drain.sh"
  cp "$HERE"/../post-drain.sh "$copy/post-drain.sh"
  printf '%s\n' 'rogue() { git -C "$HOST_REPO" push origin "HEAD:refs/formann/auto-merge/$1"; }' >>"$copy/run-the-queue.sh"
  run opt_in_writers "$copy"
  assert_output --partial "run-the-queue.sh"
}
