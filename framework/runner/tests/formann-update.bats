#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Runner's Formann updater (formann-update.sh) against a bare repository
# standing in for the Formann remote. Tests check what a caller can see: the
# sha printed, the refusal and its reason, and the checkout's state after.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  # shellcheck source=../formann-update.sh
  source "$HERE/../formann-update.sh"

  unset RUNNER_FORMANN_DIR RUNNER_FORMANN_REF
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  UPSTREAM="$BATS_TEST_TMPDIR/formann.git"
  git init --quiet --bare --initial-branch=main "$UPSTREAM"
  # The maintainer's working copy: where new Formann commits come from.
  DEV="$BATS_TEST_TMPDIR/dev"
  git clone --quiet "$UPSTREAM" "$DEV" 2>/dev/null
  git -C "$DEV" checkout --quiet -b main
  mkdir -p "$DEV/framework/runner"
  echo v1 >"$DEV/framework/runner/VERSION"
  git -C "$DEV" add -A
  git -C "$DEV" commit --quiet -m v1
  git -C "$DEV" push --quiet origin main

  RUNNER_FORMANN_DIR="$BATS_TEST_TMPDIR/runner-formann"
  git clone --quiet "$UPSTREAM" "$RUNNER_FORMANN_DIR"
}

# Commit a new version on the Formann remote. Prints its sha.
push_version() {
  echo "$1" >"$DEV/framework/runner/VERSION"
  git -C "$DEV" commit --quiet -am "$1"
  git -C "$DEV" push --quiet origin main
  git -C "$DEV" rev-parse HEAD
}

@test "formann_self_update — up to date: prints the checkout's sha, nothing changes" {
  local head
  head="$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)"
  run --separate-stderr formann_self_update origin/main
  assert_success
  assert_output "$head"
}

@test "formann_self_update — fast-forward: a commit pushed to the ref is checked out without anyone pulling; prints its sha" {
  local v2
  v2="$(push_version v2)"
  run --separate-stderr formann_self_update origin/main
  assert_success
  assert_output "$v2"
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" = "$v2" ]
  [ "$(cat "$RUNNER_FORMANN_DIR/framework/runner/VERSION")" = "v2" ]
  [ -z "$(git -C "$RUNNER_FORMANN_DIR" status --porcelain)" ]
}

@test "formann_self_update — the ref defaults to RUNNER_FORMANN_REF, then origin/main" {
  local v2 v3
  v2="$(push_version v2)"
  run --separate-stderr formann_self_update
  assert_success
  assert_output "$v2"

  git -C "$DEV" checkout --quiet -b integration
  v3="$(push_version v3)"
  git -C "$DEV" push --quiet origin integration
  RUNNER_FORMANN_REF=origin/integration
  run --separate-stderr formann_self_update
  assert_success
  assert_output "$v3"
}

@test "formann_self_update — a maintainer's integration branch: follows <remote>/<branch> on any remote name" {
  git -C "$RUNNER_FORMANN_DIR" remote rename origin fork
  git -C "$DEV" checkout --quiet -b integration
  local v2
  v2="$(push_version v2)"
  git -C "$DEV" push --quiet origin integration
  run --separate-stderr formann_self_update fork/integration
  assert_success
  assert_output "$v2"
}

@test "formann_self_update — refuses on a local change (modified file), naming it; the checkout is untouched" {
  push_version v2 >/dev/null
  local head
  head="$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)"
  echo hack >"$RUNNER_FORMANN_DIR/framework/runner/VERSION"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  assert_output ""
  [[ "$stderr" == *"local changes"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"framework/runner/VERSION"* ]] || fail "stderr: $stderr"
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" = "$head" ]
  [ "$(cat "$RUNNER_FORMANN_DIR/framework/runner/VERSION")" = "hack" ]
}

@test "formann_self_update — refuses on a local change (untracked file)" {
  echo x >"$RUNNER_FORMANN_DIR/stray"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"local changes"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"stray"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses on divergence (a local commit not on the ref), naming it; HEAD unchanged" {
  push_version v2 >/dev/null
  echo local >"$RUNNER_FORMANN_DIR/framework/runner/VERSION"
  git -C "$RUNNER_FORMANN_DIR" commit --quiet -am local
  local head
  head="$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  assert_output ""
  [[ "$stderr" == *"diverged from origin/main"* ]] || fail "stderr: $stderr"
  [[ "$stderr" == *"1 local commit"* ]] || fail "stderr: $stderr"
  [ "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)" = "$head" ]
}

@test "formann_self_update — refuses when only ahead of the ref (a local commit, nothing new upstream)" {
  echo local >"$RUNNER_FORMANN_DIR/framework/runner/VERSION"
  git -C "$RUNNER_FORMANN_DIR" commit --quiet -am local
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"diverged from origin/main"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses on an rsync copy (not a git repository)" {
  local copy="$BATS_TEST_TMPDIR/copy"
  mkdir -p "$copy"
  cp -R "$RUNNER_FORMANN_DIR/framework" "$copy/"
  RUNNER_FORMANN_DIR="$copy"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"not a git clone"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses a directory inside some other git repository" {
  RUNNER_FORMANN_DIR="$RUNNER_FORMANN_DIR/framework"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"not a git clone"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses when RUNNER_FORMANN_DIR is unset or missing" {
  unset RUNNER_FORMANN_DIR
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"RUNNER_FORMANN_DIR"* ]] || fail "stderr: $stderr"

  RUNNER_FORMANN_DIR="$BATS_TEST_TMPDIR/nowhere"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"does not exist"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses a malformed ref, an unknown remote, and a branch the remote lacks" {
  run --separate-stderr formann_self_update main
  assert_failure
  [[ "$stderr" == *"<remote>/<branch>"* ]] || fail "stderr: $stderr"

  run --separate-stderr formann_self_update upstream/main
  assert_failure
  [[ "$stderr" == *"no remote 'upstream'"* ]] || fail "stderr: $stderr"

  run --separate-stderr formann_self_update origin/nope
  assert_failure
  [[ "$stderr" == *"fetch"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — refuses when the Formann remote is unreachable" {
  mv "$UPSTREAM" "$UPSTREAM.gone"
  run --separate-stderr formann_self_update origin/main
  assert_failure
  [[ "$stderr" == *"fetch"* ]] || fail "stderr: $stderr"
}

@test "formann_self_update — never touches another checkout of the same Formann (the sessions' .formann)" {
  local sessions="$BATS_TEST_TMPDIR/sessions"
  git clone --quiet "$UPSTREAM" "$sessions"
  local before after
  before="$(cd "$sessions" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum)"
  push_version v2 >/dev/null
  run --separate-stderr formann_self_update origin/main
  assert_success
  after="$(cd "$sessions" && find . -type f -print0 | sort -z | xargs -0 shasum | shasum)"
  [ "$before" = "$after" ]
}

@test "formann_checkout_sha — the checkout's HEAD, or unknown" {
  run formann_checkout_sha "$RUNNER_FORMANN_DIR"
  assert_success
  assert_output "$(git -C "$RUNNER_FORMANN_DIR" rev-parse HEAD)"
  run formann_checkout_sha "$BATS_TEST_TMPDIR/nowhere"
  assert_output "unknown"
}
