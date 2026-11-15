#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Nothing a Dispatch writes under the runner-checkout's `.git/` runs on the
# host (#35). The checkout is mounted read-write into the sandbox, and the
# host side of the runner runs git in that same tree; git obeys the
# repository config and hooks it finds there. These tests plant what a
# dispatch could write — a `core.fsmonitor` command, hooks, a filter driver
# bound to a tracked file through `.gitattributes`, a repository nested in
# the checkout with a filter in its own config, a `.git/commondir`
# redirect — each of which writes a marker file when it runs, then drive the
# host side of a dispatch cycle and assert no marker exists.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  unset RUNNER_DEFAULT_BRANCH RUNNER_SHARED_REMOTE
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER_DIR="$(cd "$HERE/.." && pwd)"
  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_DIR/run-the-queue.sh"
  RUNNER_DISABLE_LIVENESS=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  MARKERS="$BATS_TEST_TMPDIR/markers"
  EVIL="$BATS_TEST_TMPDIR/evil"
  mkdir -p "$MARKERS" "$EVIL"
}

# A host repo with a feature branch `f`, and its runner-checkout made the way
# pre-flight makes it, synced to `f`.
setup_cycle_fixture() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  git init --quiet --initial-branch=main "$HOST_REPO"
  printf '/.runner-state/\n' >"$HOST_REPO/.gitignore"
  echo one >"$HOST_REPO/notes.txt"
  git -C "$HOST_REPO" add -A
  git -C "$HOST_REPO" commit --quiet -m init
  git -C "$HOST_REPO" branch f
  HOST_RUNNER_STATE="$HOST_REPO/.runner-state"
  HOST_CHECKOUT="$HOST_RUNNER_STATE/checkout"
  ensure_runner_checkout_exists
  ensure_runner_checkout_on_branch f >/dev/null 2>&1
  git -C "$HOST_REPO" remote add runner "$HOST_CHECKOUT"

  # Binding scripts that, like local-markdown's, run git in the checkout
  # they are handed.
  mkdir -p "$HOST_REPO/docs/formann/issue-tracker"
  cat >"$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot" <<'SH'
#!/usr/bin/env bash
git -C "$SNAPSHOT_CHECKOUT_DIR" status --porcelain >/dev/null
git -C "$SNAPSHOT_CHECKOUT_DIR" log -1 --format=%H >/dev/null
printf '{"feature":"%s","issues":[]}\n' "$1"
SH
  cat >"$HOST_REPO/docs/formann/issue-tracker/blocked-passes" <<'SH'
#!/usr/bin/env bash
git -C "$SNAPSHOT_CHECKOUT_DIR" status --porcelain >/dev/null
echo 0
SH
  chmod +x "$HOST_REPO/docs/formann/issue-tracker/"*
}

# What a dispatch can leave in the checkout. The dispatch's own commit
# binds `*.dat` to filter `x` through a tracked `.gitattributes`; then the
# config and hooks are planted, each command writing a marker named after
# itself. Writes the files directly, as a dispatch without the read-only
# mounts could.
plant_dispatch() {
  DISPATCH_BASE="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  printf '*.dat filter=x\n' >"$HOST_CHECKOUT/.gitattributes"
  echo data >"$HOST_CHECKOUT/a.dat"
  plant_nested_repos
  git -C "$HOST_CHECKOUT" add -A 2>/dev/null
  git -C "$HOST_CHECKOUT" commit --quiet -m "feat: the dispatch's work"
  sleep 1
  touch "$HOST_CHECKOUT/sub/f.dat" "$HOST_CHECKOUT/mod/f.dat"

  local name
  for name in fsmonitor smudge clean; do
    printf '#!/bin/sh\ntouch "%s/%s"\n%s\n' "$MARKERS" "$name" \
      "$( [ "$name" = fsmonitor ] && echo 'exit 1' || echo 'cat' )" >"$EVIL/$name"
    chmod +x "$EVIL/$name"
  done
  git config --file "$HOST_CHECKOUT/.git/config" core.fsmonitor "$EVIL/fsmonitor"
  git config --file "$HOST_CHECKOUT/.git/config" filter.x.smudge "$EVIL/smudge"
  git config --file "$HOST_CHECKOUT/.git/config" filter.x.clean "$EVIL/clean"
  git config --file "$HOST_CHECKOUT/.git/config" remote.origin.url "$EVIL/elsewhere.git"
  for name in post-checkout pre-push pre-commit post-commit post-merge \
      reference-transaction post-rewrite pre-auto-gc; do
    printf '#!/bin/sh\ntouch "%s/hook-%s"\n' "$MARKERS" "$name" >"$HOST_CHECKOUT/.git/hooks/$name"
    chmod +x "$HOST_CHECKOUT/.git/hooks/$name"
  done
  # A stray untracked file, so the next sync's scrub and clean run.
  echo stray >"$HOST_CHECKOUT/stray.txt"
}

# A git repository nested in the checkout, committed as a gitlink, whose own
# config — outside the read-only mounts — defines a filter bound to a file in
# it. `sub` keeps its config in `sub/.git/config`; `mod` keeps it in
# `.git/modules/mod/config` behind a gitfile, as `git submodule` lays it out.
# plant_dispatch commits them with its work and then touches each file, so
# `git status` recursing into an inner repository would run its `clean` to
# compare contents.
plant_nested_repos() {
  local name inner gitdir
  for name in sub mod; do
    inner="$HOST_CHECKOUT/$name"
    git init --quiet --initial-branch=main "$inner"
    printf '*.dat filter=x\n' >"$inner/.gitattributes"
    echo inner >"$inner/f.dat"
    git -C "$inner" add -A
    git -C "$inner" commit --quiet -m inner
    printf '#!/bin/sh\ntouch "%s/nested-%s-clean"\ncat\n' "$MARKERS" "$name" >"$EVIL/nested-$name-clean"
    chmod +x "$EVIL/nested-$name-clean"
    git -C "$inner" config filter.x.clean "$EVIL/nested-$name-clean"
  done
  mkdir -p "$HOST_CHECKOUT/.git/modules"
  mv "$HOST_CHECKOUT/mod/.git" "$HOST_CHECKOUT/.git/modules/mod"
  printf 'gitdir: ../.git/modules/mod\n' >"$HOST_CHECKOUT/mod/.git"
  git config --file "$HOST_CHECKOUT/.git/modules/mod/config" core.worktree ../../../mod
}

# The host side of a dispatch cycle after the container exits: the
# implement-stage dirty check, the post-dispatch snapshot and blocked-pass
# read, stamping and propagation, then — after the host moves `f` on with a
# change to the filtered file — the next dispatch's checkout sync and reset.
drive_host_cycle() {
  checkout_git status --porcelain --untracked-files=all >/dev/null
  take_snapshot f >/dev/null
  read_blocked_passes f/01 >/dev/null
  propagate_feature f f/01 "$DISPATCH_BASE"
  [ "$(git -C "$HOST_REPO" rev-parse f)" = "$(git -C "$HOST_CHECKOUT" rev-parse HEAD)" ]

  git -C "$HOST_REPO" checkout --quiet f
  printf '*.dat filter=x\n' >"$HOST_REPO/.gitattributes"
  echo "host change" >"$HOST_REPO/a.dat"
  git -C "$HOST_REPO" -c core.hooksPath=/dev/null add -A
  git -C "$HOST_REPO" -c core.hooksPath=/dev/null commit --quiet -m "host moves f on"
  git -C "$HOST_REPO" checkout --quiet main

  ensure_runner_checkout_on_branch f
  [ "$(git -C "$HOST_CHECKOUT" rev-parse HEAD)" = "$(git -C "$HOST_REPO" rev-parse f)" ]
}

@test "host-git-escape — nothing planted in the checkout's .git runs during the host side of a dispatch cycle" {
  setup_cycle_fixture
  plant_dispatch

  drive_host_cycle >"$BATS_TEST_TMPDIR/out" 2>&1 || { cat "$BATS_TEST_TMPDIR/out"; return 1; }

  run ls -A "$MARKERS"
  assert_output ""
  # The planted config is gone: the checkout carries the host-owned copy.
  cmp -s "$HOST_RUNNER_STATE/checkout-git/config" "$HOST_CHECKOUT/.git/config"
  [ "$(git -C "$HOST_CHECKOUT" config --get remote.origin.url)" = "$HOST_REPO" ]
  run git -C "$HOST_CHECKOUT" config --get core.fsmonitor
  assert_failure
  grep -q "runner-checkout .git/config differed from the host-owned copy; restored" "$BATS_TEST_TMPDIR/out"
}

# Control: the same cycle with the protection taken out fires the planted
# commands, so the test above is not passing because the plants are inert.
@test "host-git-escape — control: without the guard and the overrides the same cycle runs the planted commands" {
  setup_cycle_fixture
  plant_dispatch
  guard_runner_checkout_git() { :; }
  RUNNER_CHECKOUT_GIT_OVERRIDES=(core.quotePath=true)

  # Undo the origin rewrite by hand, so the unprotected cycle gets as far.
  git config --file "$HOST_CHECKOUT/.git/config" remote.origin.url "$HOST_REPO"

  drive_host_cycle >"$BATS_TEST_TMPDIR/out" 2>&1 || true

  [ -f "$MARKERS/fsmonitor" ]
  [ -f "$MARKERS/hook-post-checkout" ]
  [ -f "$MARKERS/smudge" ]
  [ -f "$MARKERS/nested-sub-clean" ]
  [ -f "$MARKERS/nested-mod-clean" ]
}

@test "host-git-escape — a planted pre-push hook does not run when the host pushes from the checkout" {
  setup_cycle_fixture
  plant_dispatch
  local bare="$BATS_TEST_TMPDIR/pushed.git"
  git init --quiet --bare "$bare"

  checkout_git push --quiet "$bare" HEAD:refs/heads/f 2>/dev/null

  [ ! -e "$MARKERS/hook-pre-push" ]
  [ ! -e "$MARKERS/fsmonitor" ]
}

@test "host-git-escape — a .git/commondir redirect is removed before host git runs" {
  setup_cycle_fixture
  # A redirect to a common dir whose config runs a command on `git status`.
  local other="$BATS_TEST_TMPDIR/other"
  cp -R "$HOST_CHECKOUT/.git" "$other"
  printf '#!/bin/sh\ntouch "%s/fsmonitor"\nexit 1\n' "$MARKERS" >"$EVIL/fsmonitor"
  chmod +x "$EVIL/fsmonitor"
  git config --file "$other/config" core.fsmonitor "$EVIL/fsmonitor"
  printf '%s\n' "$other" >"$HOST_CHECKOUT/.git/commondir"

  run checkout_git status --porcelain

  assert_success
  assert_output --partial "removed $HOST_CHECKOUT/.git/commondir"
  [ ! -e "$HOST_CHECKOUT/.git/commondir" ]
  [ ! -e "$MARKERS/fsmonitor" ]
}

@test "host-git-escape — a .git/config symlink is replaced, never written through" {
  setup_cycle_fixture
  local target="$BATS_TEST_TMPDIR/precious"
  echo precious >"$target"
  rm "$HOST_CHECKOUT/.git/config"
  ln -s "$target" "$HOST_CHECKOUT/.git/config"

  checkout_git rev-parse HEAD >/dev/null 2>&1

  [ "$(cat "$target")" = "precious" ]
  [ ! -L "$HOST_CHECKOUT/.git/config" ]
  cmp -s "$HOST_RUNNER_STATE/checkout-git/config" "$HOST_CHECKOUT/.git/config"
}

@test "host-git-escape — a .git that is not a directory is refused, and git does not run" {
  setup_cycle_fixture
  mv "$HOST_CHECKOUT/.git" "$BATS_TEST_TMPDIR/real-git"
  printf 'gitdir: %s\n' "$BATS_TEST_TMPDIR/real-git" >"$HOST_CHECKOUT/.git"

  run checkout_git rev-parse HEAD

  assert_failure
  assert_output --partial "is not a directory"
}

@test "host-git-escape — the host-owned config keeps only format keys and the runner's origin, whatever the checkout held" {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  git init --quiet --initial-branch=main "$HOST_REPO"
  git -C "$HOST_REPO" commit --quiet --allow-empty -m init
  HOST_RUNNER_STATE="$HOST_REPO/.runner-state"
  HOST_CHECKOUT="$HOST_RUNNER_STATE/checkout"
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT"
  # A checkout found already tampered with, before the runner first saw it.
  git -C "$HOST_CHECKOUT" config core.fsmonitor "$EVIL/fsmonitor"
  git -C "$HOST_CHECKOUT" config core.sshCommand "$EVIL/ssh"
  git -C "$HOST_CHECKOUT" config include.path "$EVIL/included"
  git -C "$HOST_CHECKOUT" config remote.origin.url "$EVIL/elsewhere.git"

  ensure_runner_checkout_exists 2>/dev/null

  local cfg="$HOST_RUNNER_STATE/checkout-git/config"
  run git config --file "$cfg" --list --name-only
  assert_success
  refute_output --partial fsmonitor
  refute_output --partial sshcommand
  refute_output --partial include
  [ "$(git config --file "$cfg" --get remote.origin.url)" = "$HOST_REPO" ]
  [ "$(git config --file "$cfg" --get core.bare)" = "false" ]
  [ -d "$HOST_RUNNER_STATE/checkout-git/hooks" ]
  [ -z "$(ls -A "$HOST_RUNNER_STATE/checkout-git/hooks")" ]
  cmp -s "$cfg" "$HOST_CHECKOUT/.git/config"
}

@test "host-git-escape — the runner's own origin repair lands in the host-owned copy" {
  setup_cycle_fixture
  git config --file "$HOST_RUNNER_STATE/checkout-git/config" remote.origin.url "$EVIL/edited.git"

  run reset_runner_checkout_origin

  assert_success
  assert_output --partial "origin was '$EVIL/edited.git'; reset to $HOST_REPO"
  [ "$(git config --file "$HOST_RUNNER_STATE/checkout-git/config" --get remote.origin.url)" = "$HOST_REPO" ]
  [ "$(git -C "$HOST_CHECKOUT" config --get remote.origin.url)" = "$HOST_REPO" ]
}

# === The container mounts ===================================================

setup_mount_capture() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/host/.runner-state/checkout"
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/host/.runner-state"
  MVN_VOLUME=vol NET_NAME=net IMAGE_NAME=img TOKEN=tok
  RUNNER_INTERRUPTED=0 IN_FLIGHT_CID_FILE=""
  mkdir -p "$HOST_REPO" "$HOST_RUNNER_STATE"
  git init --quiet --initial-branch=main "$HOST_CHECKOUT"
  args_file="$BATS_TEST_TMPDIR/docker-args"
  docker() { printf '%s\n' "$@" >"$args_file"; }
}

@test "host-git-escape — every container mounts .git/config and .git/hooks read-only from .runner-state, not from the checkout" {
  local wrapper
  for wrapper in sandbox dispatch item; do
    setup_mount_capture
    rm -f "$args_file"
    case "$wrapper" in
      sandbox)  run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p x ;;
      dispatch) run_dispatch_container f/01 "$BATS_TEST_TMPDIR/log" ;;
      item)     echo prompt >"$BATS_TEST_TMPDIR/p"; run_item_container f/01 "$BATS_TEST_TMPDIR/log" "$BATS_TEST_TMPDIR/p" ;;
    esac
    grep -qFx -- "$HOST_RUNNER_STATE/checkout-git/config:/repo/.git/config:ro" "$args_file" \
      || fail "$wrapper: no read-only .git/config mount: $(cat "$args_file")"
    grep -qFx -- "$HOST_RUNNER_STATE/checkout-git/hooks:/repo/.git/hooks:ro" "$args_file" \
      || fail "$wrapper: no read-only .git/hooks mount"
    # Each mount follows a `-v`, and no other mount targets the checkout's .git.
    [ "$(grep -c ':/repo/\.git' "$args_file")" -eq 2 ]
    [ "$(grep -B1 -Fx -- "$HOST_RUNNER_STATE/checkout-git/config:/repo/.git/config:ro" "$args_file" | head -1)" = "-v" ]
    [ -f "$HOST_RUNNER_STATE/checkout-git/config" ]
  done
}

@test "host-git-escape — no container starts without host-owned git state to mount" {
  setup_mount_capture
  HOST_RUNNER_STATE=""

  run run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p x

  assert_failure
  assert_output --partial "no host-owned git config to mount"
  [ ! -f "$args_file" ]
}

# === One way in =============================================================
#
# Host code runs git on the runner-checkout only through checkout_git /
# checkout_git_run. bypasses_of_checkout_git prints every line of the given
# files that runs git there some other way; the one call inside checkout_git
# itself carries the `checkout-git-wrapper` marker.
bypasses_of_checkout_git() {
  local f
  for f in "$@"; do
    awk -v file="$f" '
      /checkout-git-wrapper/ { next }
      {
        line = $0
        sub(/^[ \t]*#.*/, "", line)                       # comment lines
        if (line == "") next
        hc = "\"?\\$\\{?HOST_CHECKOUT"
        bad = 0
        if (line ~ ("git[^|;&]*-C[ \t]+" hc)) bad = 1           # git -C "$HOST_CHECKOUT"
        if (line ~ ("cd[ \t]+" hc)) bad = 1                     # cd "$HOST_CHECKOUT"
        if (line ~ ("(GIT_DIR|GIT_WORK_TREE)=" hc)) bad = 1
        if (line ~ ("--(git-dir|work-tree)[ =]" hc)) bad = 1
        if (line ~ /_CHECKOUT_DIR="\$\{?HOST_CHECKOUT/ && line !~ /checkout_git_run/) bad = 1
        if (line ~ /git[^|;&]*(fetch|pull|push|ls-remote|archive)[^|;&]*"\$\{?HOST_CHECKOUT/ \
            && line !~ /checkout_git_run/) bad = 1
        if (bad) printf "%s:%d: %s\n", file, NR, $0
      }' "$f"
  done
}

@test "host-git-escape — no host code runs git in the runner-checkout except through checkout_git / checkout_git_run" {
  local files=("$RUNNER_DIR"/*.sh "$RUNNER_DIR/issue-commits")

  run bypasses_of_checkout_git "${files[@]}"

  assert_success
  assert_output ""
  # The scan sees the real call sites (not a pattern that matches nothing).
  [ "$(grep -c 'checkout_git ' "$RUNNER_DIR/run-the-queue.sh")" -gt 40 ]
  [ "$(grep -c 'checkout_git_run ' "$RUNNER_DIR/run-the-queue.sh")" -ge 5 ]
}

@test "host-git-escape — the bypass scan catches each way around the wrapper" {
  local bad="$BATS_TEST_TMPDIR/bad.sh"
  cat >"$bad" <<'SH'
  git -C "$HOST_CHECKOUT" status
  head="$(git -C "${HOST_CHECKOUT:-}" rev-parse HEAD)"
  ( cd "$HOST_CHECKOUT" && git log )
  GIT_DIR="$HOST_CHECKOUT/.git" git log
  git --git-dir="$HOST_CHECKOUT/.git" log
  out="$(SNAPSHOT_CHECKOUT_DIR="$HOST_CHECKOUT" "$script")"
  git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" f:f
SH
  local good="$BATS_TEST_TMPDIR/good.sh"
  cat >"$good" <<'SH'
  # git -C "$HOST_CHECKOUT" status   (a comment)
  checkout_git status
  out="$(SNAPSHOT_CHECKOUT_DIR="$HOST_CHECKOUT" checkout_git_run "$script")"
  checkout_git_run git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" f:f
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT"
  git -C "$HOST_REPO" remote add runner "$HOST_CHECKOUT"
SH

  run bypasses_of_checkout_git "$bad"
  [ "$(printf '%s\n' "$output" | grep -c "^$bad:")" -eq 7 ]

  run bypasses_of_checkout_git "$good"
  assert_output ""
}
