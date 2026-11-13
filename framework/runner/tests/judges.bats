#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# The Judges checkout (judges.sh, #27): the runner's own checkout of the
# consumer's default branch, detached at the Shared remote's tip and refreshed
# before every pass, so the reviewers (`.claude/{skills,agents,rules}`), the
# gates' step prompts and the manifests come from the default branch, never
# from wherever the host repo happens to be. The host repo is where people
# work: it is never touched. A bare repository stands in for the Shared
# remote.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  TESTS="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SRC_RUNNER="$(cd "$TESTS/.." && pwd)"
  # shellcheck source=../lib.sh
  source "$SRC_RUNNER/lib.sh"
  # shellcheck source=../judges.sh
  source "$SRC_RUNNER/judges.sh"

  unset RUNNER_SHARED_REMOTE RUNNER_DEFAULT_BRANCH RUNNER_FORMANN_DIR \
        RUNNER_FORMANN_REF RUNNER_FORMANN_REEXEC
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  SHARED="$BATS_TEST_TMPDIR/shared.git"
  git init --quiet --bare --initial-branch=main "$SHARED"
  # Another machine: where merges to the default branch come from.
  OTHER="$BATS_TEST_TMPDIR/other"
  git init --quiet --initial-branch=main "$OTHER"
  git -C "$OTHER" remote add origin "$SHARED"
  mkdir -p "$OTHER/.claude/agents" "$OTHER/runner"
  echo v1 >"$OTHER/.claude/agents/review.md"
  printf 'review-and-gate.md\n' >"$OTHER/runner/manifest.md"
  echo "gate v1" >"$OTHER/runner/review-and-gate.md"
  printf '/.runner-state/\n/.formann\n' >"$OTHER/.gitignore"
  git -C "$OTHER" add -A
  git -C "$OTHER" commit --quiet -m v1
  git -C "$OTHER" push --quiet origin main

  HOST_REPO="$BATS_TEST_TMPDIR/host"
  git clone --quiet "$SHARED" "$HOST_REPO"
  HOST_JUDGES="$HOST_REPO/$RUNNER_JUDGES_PATH"
  V1="$(git -C "$HOST_REPO" rev-parse HEAD)"
}

# Merge a new reviewer version on the Shared remote's default branch. Prints
# its sha.
push_reviewer() {
  echo "$1" >"$OTHER/.claude/agents/review.md"
  git -C "$OTHER" commit --quiet -am "$1"
  git -C "$OTHER" push --quiet origin "${2:-main}"
  git -C "$OTHER" rev-parse HEAD
}

judges_head() { git -C "$HOST_JUDGES" rev-parse HEAD; }

# Everything a person working in the host repo could notice: HEAD, the
# branch, every path's state, the stash, the worktree list, the local
# branches.
host_state() {
  git -C "$HOST_REPO" rev-parse HEAD
  git -C "$HOST_REPO" symbolic-ref --quiet --short HEAD || echo detached
  git -C "$HOST_REPO" status --porcelain --untracked-files=all
  git -C "$HOST_REPO" diff
  git -C "$HOST_REPO" stash list
  git -C "$HOST_REPO" worktree list --porcelain
  git -C "$HOST_REPO" for-each-ref refs/heads
}

# --- judges_refresh -------------------------------------------------------------

@test "judges_refresh — creates the judges checkout detached at the Shared remote's default branch; the host repo is untouched" {
  local before
  before="$(host_state)"
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_JUDGES" origin/main)"
  [ -z "$stderr" ] || fail "stderr: $stderr"
  [ "$(judges_head)" = "$V1" ]
  ! git -C "$HOST_JUDGES" symbolic-ref --quiet HEAD
  [ "$(cat "$HOST_JUDGES/.claude/agents/review.md")" = "v1" ]
  [ "$(host_state)" = "$before" ]
}

@test "judges_refresh — a commit merged on the Shared remote is what the next pass judges with; the host repo stays where it was" {
  judges_refresh >/dev/null 2>&1
  local v2 before
  v2="$(push_reviewer v2)"
  before="$(host_state)"
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_JUDGES" origin/main)"
  [ "$(judges_head)" = "$v2" ]
  [ "$(cat "$HOST_JUDGES/.claude/agents/review.md")" = "v2" ]
  [ "$(git -C "$HOST_REPO" rev-parse HEAD)" = "$V1" ]
  [ "$(cat "$HOST_REPO/.claude/agents/review.md")" = "v1" ]
  [ "$(host_state)" = "$before" ]
}

@test "judges_refresh — a dirty, off-branch, diverged host repo doesn't matter: the judges are the remote's tip, the host repo is untouched" {
  local v2
  v2="$(push_reviewer v2)"
  git -C "$HOST_REPO" checkout --quiet -b feature-x
  echo local >"$HOST_REPO/local.md"
  git -C "$HOST_REPO" add local.md
  git -C "$HOST_REPO" commit --quiet -m local
  echo mine >"$HOST_REPO/.claude/agents/review.md"
  echo staged >"$HOST_REPO/staged.md"
  git -C "$HOST_REPO" add staged.md
  echo stray >"$HOST_REPO/stray.md"
  local before
  before="$(host_state)"
  run --separate-stderr judges_refresh
  assert_success
  [ -z "$stderr" ] || fail "stderr: $stderr"
  [ "$(judges_head)" = "$v2" ]
  [ "$(cat "$HOST_JUDGES/.claude/agents/review.md")" = "v2" ]
  [ ! -e "$HOST_JUDGES/local.md" ]
  [ "$(host_state)" = "$before" ]
  [ "$(cat "$HOST_REPO/.claude/agents/review.md")" = "mine" ]
}

@test "judges_refresh — the judges checkout is set exactly: an edit or a stray file in it is gone after the next refresh" {
  judges_refresh >/dev/null 2>&1
  echo hacked >"$HOST_JUDGES/.claude/agents/review.md"
  echo stray >"$HOST_JUDGES/stray.md"
  run --separate-stderr judges_refresh
  assert_success
  [ "$(cat "$HOST_JUDGES/.claude/agents/review.md")" = "v1" ]
  [ ! -e "$HOST_JUDGES/stray.md" ]
  [ -z "$(git -C "$HOST_JUDGES" status --porcelain --untracked-files=all)" ]
}

@test "judges_refresh — something that isn't a git checkout at the judges path is replaced" {
  mkdir -p "$HOST_JUDGES"
  echo junk >"$HOST_JUDGES/junk"
  run --separate-stderr judges_refresh
  assert_success
  [ "$(judges_head)" = "$V1" ]
  [ ! -e "$HOST_JUDGES/junk" ]
}

@test "judges_refresh — follows RUNNER_SHARED_REMOTE and RUNNER_DEFAULT_BRANCH" {
  git -C "$OTHER" checkout --quiet -b trunk
  local v2
  v2="$(push_reviewer v2 trunk)"
  git -C "$HOST_REPO" remote rename origin shared
  export RUNNER_SHARED_REMOTE=shared RUNNER_DEFAULT_BRANCH=trunk
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_JUDGES" shared/trunk)"
  [ "$(judges_head)" = "$v2" ]
}

@test "judges_refresh — the Shared remote can't be reached: a warning, the judges kept at their last commit, exit 0" {
  judges_refresh >/dev/null 2>&1
  push_reviewer v2 >/dev/null
  mv "$SHARED" "$SHARED.gone"
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_JUDGES" "origin/main, not refreshed")"
  [[ "$stderr" == "judges: not refreshed: fetch of origin/main failed: "*"; keeping them at $V1" ]] || fail "stderr: $stderr"
  [ "$(judges_head)" = "$V1" ]
}

@test "judges_refresh — the Shared remote can't be reached and there is no judges checkout yet: the judges come from the host repo, with a warning" {
  mv "$SHARED" "$SHARED.gone"
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_REPO" "host repo")"
  [[ "$stderr" == "judges: not refreshed: fetch of origin/main failed: "*"; they come from the host repo until the judges checkout exists" ]] || fail "stderr: $stderr"
}

@test "judges_refresh — no default branch resolves: a warning naming RUNNER_DEFAULT_BRANCH; the host repo as the fallback" {
  git -C "$HOST_REPO" remote set-head origin --delete
  git -C "$HOST_REPO" branch --quiet -m main stem
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_REPO" "host repo")"
  [[ "$stderr" == *"not refreshed: cannot determine the default branch"*"RUNNER_DEFAULT_BRANCH"* ]] || fail "stderr: $stderr"
}

@test "judges_refresh — no Shared remote (one machine): the host repo, as before, silently; no judges checkout is made" {
  git -C "$HOST_REPO" remote remove origin
  run --separate-stderr judges_refresh
  assert_success
  assert_output "$(printf '%s\t%s' "$HOST_REPO" "host repo, no Shared remote 'origin'")"
  [ -z "$stderr" ] || fail "stderr: $stderr"
  [ ! -e "$HOST_JUDGES" ]
}

# --- in the runner --------------------------------------------------------------

load_runner() {
  # shellcheck source=../run-the-queue.sh
  source "$SRC_RUNNER/run-the-queue.sh"
}

@test "refresh_judges — logs the judges' commit and where it comes from; the runner reads the judges from there" {
  load_runner
  local v2
  v2="$(push_reviewer v2)"
  run refresh_judges
  assert_success
  assert_equal "${#lines[@]}" 1
  assert_line --index 0 --regexp "^\[[0-9:]+\] runner: judges $v2 \(origin/main\)$"
  refresh_judges >/dev/null
  [ "$JUDGES_DIR" = "$HOST_JUDGES" ]
  [ "$(judges_dir)" = "$HOST_JUDGES" ]
  [ "$RUNNER_JUDGES_SHA" = "$v2" ]
}

@test "refresh_judges — a failed fetch: a warning, then the commit kept" {
  load_runner
  refresh_judges >/dev/null
  mv "$SHARED" "$SHARED.gone"
  run refresh_judges
  assert_success
  assert_line --index 0 --regexp "^\[[0-9:]+\] runner: warning: judges not refreshed: fetch of origin/main failed: .*; keeping them at $V1$"
  assert_line --index 1 --regexp "^\[[0-9:]+\] runner: judges $V1 \(origin/main, not refreshed\)$"
}

@test "refresh_judges — no Shared remote: the host repo's commit, read from the host repo" {
  load_runner
  git -C "$HOST_REPO" remote remove origin
  run refresh_judges
  assert_success
  assert_line --index 0 --regexp "runner: judges $V1 \(host repo, no Shared remote 'origin'\)$"
  refresh_judges >/dev/null
  [ "$(judges_dir)" = "$HOST_REPO" ]
}

@test "prepare_idle_pass — every later pass refreshes the judges before it drains" {
  load_runner
  refresh_judges >/dev/null
  RUNNER_FORMANN_MANAGED=0
  RUN_MODE=drain
  refresh_discovery() { echo "discovered with judges at $(git -C "$(judges_dir)" rev-parse HEAD)" >>"$BATS_TEST_TMPDIR/discovered"; }
  local v2
  v2="$(push_reviewer v2)"
  run prepare_idle_pass
  assert_success
  assert_output --partial "runner: judges $v2 (origin/main)"
  [ "$(cat "$BATS_TEST_TMPDIR/discovered")" = "discovered with judges at $v2" ]
}

@test "prepare_idle_pass — judges that can't be refreshed don't skip the pass" {
  load_runner
  refresh_judges >/dev/null
  RUNNER_FORMANN_MANAGED=0
  RUN_MODE=drain
  refresh_discovery() { echo refreshed >>"$BATS_TEST_TMPDIR/discovered"; }
  mv "$SHARED" "$SHARED.gone"
  run prepare_idle_pass
  assert_success
  assert_output --partial "warning: judges not refreshed"
  [ "$(cat "$BATS_TEST_TMPDIR/discovered")" = "refreshed" ]
}

@test "check_manifest and check_post_drain_manifest — the consumer's manifests and step prompts are read from the judges checkout" {
  load_runner
  printf 'review-and-gate.md\nextra-review.md\n' >"$OTHER/runner/manifest.md"
  echo "extra" >"$OTHER/runner/extra-review.md"
  printf 'wrap-up.md\n' >"$OTHER/runner/post-drain.md"
  echo "wrap up" >"$OTHER/runner/wrap-up.md"
  git -C "$OTHER" add -A
  git -C "$OTHER" commit --quiet -m "a new reviewer step"
  git -C "$OTHER" push --quiet origin main
  refresh_judges >/dev/null
  HERE="$SRC_RUNNER"
  check_manifest
  [ "$RESOLVED_MANIFEST" = "$(printf 'review-and-gate\t%s\nextra-review\t%s' \
      "$HOST_JUDGES/runner/review-and-gate.md" "$HOST_JUDGES/runner/extra-review.md")" ] \
    || fail "RESOLVED_MANIFEST: $RESOLVED_MANIFEST"
  check_post_drain_manifest
  [ "$RESOLVED_POST_DRAIN" = "$(printf 'wrap-up\t%s' "$HOST_JUDGES/runner/wrap-up.md")" ] \
    || fail "RESOLVED_POST_DRAIN: $RESOLVED_POST_DRAIN"
}

@test "drain_one_feature's claim Note names the judges' commit beside Formann's" {
  load_runner
  RUNNER_FORMANN_SHA=f0f0f0 RUNNER_JUDGES_SHA=c1c1c1
  mkdir -p "$HOST_REPO/docs/formann/issue-tracker"
  printf '#!/usr/bin/env bash\ncat >"%s"\n' "$BATS_TEST_TMPDIR/note" >"$HOST_REPO/docs/formann/issue-tracker/comment-on-feature"
  chmod +x "$HOST_REPO/docs/formann/issue-tracker/comment-on-feature"
  HOST_CHECKOUT="$HOST_REPO"
  RUNNER_MACHINE=m1 RUN_TS=20261113-120000
  post_claim_note alpha >/dev/null
  grep -q 'Formann `f0f0f0`, judges `c1c1c1`' "$BATS_TEST_TMPDIR/note" || fail "$(cat "$BATS_TEST_TMPDIR/note")"
}

# --- the sandbox's mounts -----------------------------------------------------------

# Run run_sandbox_container with docker stubbed; the docker args land in
# $args_file, one per line. The runner is already loaded.
capture_mounts() {
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/runner-state"
  MVN_VOLUME=test-mvn NET_NAME=test-net IMAGE_NAME=test-image TOKEN=test-token
  RUNNER_INTERRUPTED=0 IN_FLIGHT_CID_FILE="" RUNNER_DISABLE_LIVENESS=1
  mkdir -p "$HOST_CHECKOUT" "$HOST_RUNNER_STATE"
  args_file="$BATS_TEST_TMPDIR/docker-args"
  docker() { printf '%s\n' "$@" >"$args_file"; }
  run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p "/implement f/01"
}

@test "run_sandbox_container — .claude/{skills,agents,rules} are mounted from the judges checkout, not the host repo" {
  mkdir -p "$OTHER/.claude/skills/s" "$OTHER/.claude/rules"
  echo s >"$OTHER/.claude/skills/s/SKILL.md"
  echo r >"$OTHER/.claude/rules/r.md"
  git -C "$OTHER" add -A
  git -C "$OTHER" commit --quiet -m "skills and rules"
  git -C "$OTHER" push --quiet origin main
  load_runner
  refresh_judges >/dev/null
  capture_mounts
  local sub
  for sub in skills agents rules; do
    grep -qFx -- "$HOST_JUDGES/.claude/$sub:/repo/.claude/$sub:ro" "$args_file" \
      || fail "no judges mount for $sub: $(cat "$args_file")"
    ! grep -qFx -- "$HOST_REPO/.claude/$sub:/repo/.claude/$sub:ro" "$args_file"
  done
}

@test "run_sandbox_container — a .claude/<sub> the judges checkout lacks (untracked, as in Formann's self-install) is mounted from the host repo" {
  load_runner
  refresh_judges >/dev/null
  mkdir -p "$HOST_REPO/.claude/skills"
  capture_mounts
  grep -qFx -- "$HOST_JUDGES/.claude/agents:/repo/.claude/agents:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  ! grep -qF -- "/.claude/rules:" "$args_file"
}

# --- a whole run ------------------------------------------------------------------
#
# A consumer with no tracker: past the lock and the judges, pre-flight stops
# at `discovery`, before anything needs Docker.

start_runner() {
  ln -s "$(cd "$SRC_RUNNER/.." && pwd)" "$HOST_REPO/.formann"
  run --separate-stderr bash -c 'cd "$1" && exec bash .formann/runner/run-the-queue.sh --no-caffeinate' _ "$HOST_REPO"
}

latest_runner_log() {
  cat "$(ls -1d "$HOST_REPO/.runner-state/runs/"*/ | tail -n 1)/runner.log"
}

@test "run — at startup the judges checkout is brought to the remote's tip and runner.log names its commit after Formann's; the dirty host repo is untouched" {
  local v2
  v2="$(push_reviewer v2)"
  echo mine >"$HOST_REPO/.claude/agents/review.md"
  git -C "$HOST_REPO" checkout --quiet -b feature-x
  start_runner
  [ "$status" -eq 2 ] || fail "status $status; stderr: $stderr; stdout: $output"
  [ "$(judges_head)" = "$v2" ]
  [ "$(git -C "$HOST_REPO" rev-parse HEAD)" = "$V1" ]
  [ "$(git -C "$HOST_REPO" symbolic-ref --short HEAD)" = "feature-x" ]
  [ "$(cat "$HOST_REPO/.claude/agents/review.md")" = "mine" ]
  local log
  log="$(latest_runner_log)"
  [[ "$log" == *"runner: Formann "*"runner: judges $v2 (origin/main)"*"discovery"* ]] || fail "$log"
}
