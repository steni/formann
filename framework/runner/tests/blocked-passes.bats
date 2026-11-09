#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Both bindings' `blocked-passes` count Blocked comments the same way: the
# shared fixture (fixtures/blocked-passes/) carries each timeline as a
# local-markdown issue file and as a github-issues `gh issue view --json
# comments` response, and expected.tsv holds the one count both must print.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BINDINGS="$HERE/../../bindings/issue-tracker"
  LM_BLOCKED_PASSES="$BINDINGS/local-markdown/blocked-passes"
  GH_BLOCKED_PASSES="$BINDINGS/github-issues/blocked-passes"
  FIXTURE="$HERE/fixtures/blocked-passes"

  # gh shim: serves github/<N>.json for `gh issue view <N> … --json comments`.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  f="$GH_FIXTURE_DIR/$(printf '%02d' "$3").json"
  [ -f "$f" ] && { cat "$f"; exit 0; }
  echo "shim: no fixture for issue $3" >&2; exit 1
fi
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"
  export PATH="$FAKE_BIN:$PATH"
  export GH_FIXTURE_DIR="$FIXTURE/github"
  export GH_TRACKER_REPO="test-owner/test-repo"
}

@test "blocked-passes — both bindings print the fixture's expected count for every timeline" {
  local nn expected n=0
  while IFS=$'\t' read -r nn expected; do
    n=$((n + 1))
    TRACKER_ROOT="$HERE/fixtures" run --separate-stderr "$LM_BLOCKED_PASSES" "blocked-passes/$nn"
    assert_success
    [ "$output" = "$expected" ] || fail "local-markdown blocked-passes/$nn: expected $expected, got '$output'"
    run --separate-stderr "$GH_BLOCKED_PASSES" "#$((10#$nn))"
    assert_success
    [ "$output" = "$expected" ] || fail "github-issues #$nn: expected $expected, got '$output'"
  done <"$FIXTURE/expected.tsv"
  [ "$n" -eq 6 ]
}

@test "blocked-passes (local-markdown) — two prior Blocked plus the third pass counts 3" {
  TRACKER_ROOT="$HERE/fixtures" run "$LM_BLOCKED_PASSES" "blocked-passes/03"
  assert_success
  assert_output "3"
}

@test "blocked-passes (local-markdown) — a new Implementation comment resets the count" {
  TRACKER_ROOT="$HERE/fixtures" run "$LM_BLOCKED_PASSES" "blocked-passes/04"
  assert_success
  assert_output "1"
}

@test "blocked-passes (local-markdown) — SNAPSHOT_CHECKOUT_DIR reads the committed file at HEAD, not the working tree" {
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo/.features/f/issues"
  git init --quiet "$repo"
  cp "$FIXTURE/issues/02-two-blocked-since-implementation.md" "$repo/.features/f/issues/02-x.md"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m init
  # Uncommitted extra Blocked comment: invisible to the runner's view.
  printf '\n### Blocked — 2026-11-09\n\nuncommitted\n' >>"$repo/.features/f/issues/02-x.md"

  SNAPSHOT_CHECKOUT_DIR="$repo" run "$LM_BLOCKED_PASSES" "f/02"
  assert_success
  assert_output "2"

  TRACKER_ROOT="$repo/.features" run "$LM_BLOCKED_PASSES" "f/02"
  assert_success
  assert_output "3"
}

@test "blocked-passes (local-markdown) — missing issue file exits 1" {
  TRACKER_ROOT="$HERE/fixtures" run "$LM_BLOCKED_PASSES" "blocked-passes/99"
  assert_failure 1
}

@test "blocked-passes (local-markdown) — a ref without <feature>/<NN> shape is a usage error" {
  TRACKER_ROOT="$HERE/fixtures" run "$LM_BLOCKED_PASSES" "#3"
  assert_failure 2
  TRACKER_ROOT="$HERE/fixtures" run "$LM_BLOCKED_PASSES"
  assert_failure 2
}
