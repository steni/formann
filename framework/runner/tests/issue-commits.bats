#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# issue-commits <ref> — which commits on HEAD are the issue's. Each test builds
# a consumer checkout whose `.formann` points at this framework and whose
# `docs/formann/issue-tracker` points at a real binding, exactly as the
# installer lays them out, and runs `.formann/runner/issue-commits` from the
# checkout's root.

setup_file() {
  if ! git init --quiet --initial-branch=main "$BATS_FILE_TMPDIR/probe" 2>/dev/null; then
    echo "issue-commits.bats needs git 2.28 or newer (git init --initial-branch); found: $(git --version)" >&2
    return 1
  fi
}

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  unset RUNNER_DEFAULT_BRANCH GH_TRACKER_REPO GH_REPO

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FRAMEWORK="$(cd "$HERE/../.." && pwd)"
  BINDINGS="$FRAMEWORK/bindings/issue-tracker"
  GH_FIXTURES="$BINDINGS/github-issues/tests/fixtures"

  # gh shim for the github-issues binding: serves the fixture response, or
  # fails every call when GH_SHIM_FAIL=1.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "${GH_SHIM_FAIL:-0}" = "1" ]; then
  echo "gh: API rate limit exceeded" >&2
  exit 1
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  printf '%s\n' "$*" >>"$GH_SHIM_LOG"
  cat "$FIXTURE_RESPONSES_DIR/graphql-response.json"
  exit 0
fi
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"
  export PATH="$FAKE_BIN:$PATH"
  export GH_SHIM_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$GH_SHIM_LOG"

  REPO="$BATS_TEST_TMPDIR/consumer"
}

# Commit with a fixed identity. Args: $1 = repo, $2 = message.
commit() {
  git -C "$1" -c user.email=t@t -c user.name=t commit --allow-empty --quiet -m "$2"
}

# Lay out the framework and binding views a consumer checkout carries.
# Args: $1 = checkout, $2 = binding (local-markdown | github-issues).
link_views() {
  ln -s "$FRAMEWORK" "$1/.formann"
  mkdir -p "$1/docs/formann"
  ln -s "$BINDINGS/$2" "$1/docs/formann/issue-tracker"
}

# A consumer repo on `main` with two commits, the binding views in place, and
# HEAD on a new branch named $2 cut from main.
# Args: $1 = binding, $2 = feature branch.
make_consumer() {
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=main
  printf '/.formann\n/docs/formann\n' >"$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  commit "$REPO" "main: first"
  commit "$REPO" "main: second mentions feat/01 and #7"
  link_views "$REPO" "$1"
  git -C "$REPO" checkout --quiet -b "$2"
}

# A local-markdown issue file. Args: $1 = feature, $2 = NN.
md_issue() {
  mkdir -p "$REPO/.features/$1/issues"
  cat >"$REPO/.features/$1/issues/$2-thing.md" <<'EOF'
---
status: in-review
category: enhancement
type: AFK
---

# Thing

## Blocked by

None — can start immediately.
EOF
}

# Full sha of the commit whose subject is $1 on HEAD.
sha_of() {
  git -C "$REPO" log --format='%H %s' | awk -v s="$1" 'substr($0, 42) == s { print $1; exit }'
}

run_helper() {
  cd "$REPO"
  run .formann/runner/issue-commits "$@"
}

# === usage ===================================================================

@test "issue-commits — no ref is a usage error (exit 2)" {
  make_consumer local-markdown feat
  run_helper
  assert_failure 2
  assert_output --partial "usage: issue-commits <ref>"
}

@test "issue-commits — more than one argument is a usage error (exit 2)" {
  make_consumer local-markdown feat
  run_helper feat/01 feat/02
  assert_failure 2
}

# === local-markdown refs (<feature>/NN) ======================================

@test "issue-commits — local-markdown: trailer-stamped commits, oldest first, without other issues' or main's" {
  make_consumer local-markdown feat
  md_issue feat 01
  md_issue feat 02
  commit "$REPO" $'one\n\nFormann-Issue: feat/01'
  commit "$REPO" $'other issue\n\nFormann-Issue: feat/02'
  commit "$REPO" $'two\n\nFormann-Issue: feat/01'
  commit "$REPO" "unrelated, no ref"

  run_helper feat/01
  assert_success
  assert_output "$(sha_of one)
$(sha_of two)"
}

@test "issue-commits — local-markdown: commits that only mention the ref, in either form the binding allows" {
  make_consumer local-markdown feat
  md_issue feat 01
  md_issue feat 02
  commit "$REPO" "work toward feat/01"
  commit "$REPO" "shorthand (#01) on the feature branch"
  commit "$REPO" "feat/010 is another issue"
  commit "$REPO" "work toward feat/02"

  run_helper feat/01
  assert_success
  assert_output "$(sha_of "work toward feat/01")
$(sha_of "shorthand (#01) on the feature branch")"
}

@test "issue-commits — a Formann-Issue trailer decides on its own: another issue's commit that mentions the ref is left out" {
  make_consumer local-markdown feat
  md_issue feat 01
  md_issue feat 02
  commit "$REPO" $'follow-up to feat/01\n\nFormann-Issue: feat/02'

  run_helper feat/01
  assert_success
  assert_output ""
}

@test "issue-commits — local-markdown standalone: every commit since main, no trailer or ref needed" {
  make_consumer local-markdown solo
  md_issue solo 01
  commit "$REPO" "first change"
  commit "$REPO" "second change"

  run_helper solo/01
  assert_success
  assert_output "$(sha_of "first change")
$(sha_of "second change")"
}

@test "issue-commits — merge commits are never listed, whatever they carry (as git log --no-merges)" {
  make_consumer local-markdown solo
  md_issue solo 01
  commit "$REPO" "before the side branch"
  git -C "$REPO" checkout --quiet -b side
  commit "$REPO" $'on the side\n\nFormann-Issue: solo/01'
  git -C "$REPO" checkout --quiet solo
  commit "$REPO" "alongside"
  git -C "$REPO" -c user.email=t@t -c user.name=t merge --quiet --no-ff side \
    -m $'Merge side for solo/01\n\nFormann-Issue: solo/01'
  [ "$(git -C "$REPO" rev-list --count --merges HEAD)" = "1" ]

  run_helper solo/01
  assert_success
  # Two commits of the same second on parallel lines have no single oldest;
  # what matters is which commits are listed.
  [ "$(printf '%s\n' "$output" | sort)" = "$(printf '%s\n' \
    "$(sha_of "before the side branch")" "$(sha_of "on the side")" "$(sha_of alongside)" | sort)" ]
}

# === github-issues refs (#N) =================================================

@test "issue-commits — github-issues: stamped and mentioning commits of #7, not #15's or #70's" {
  export GH_TRACKER_REPO=test-owner/test-repo
  export FIXTURE_RESPONSES_DIR="$GH_FIXTURES/multi-issue-priority-api-order/recorded-responses"
  make_consumer github-issues multi-issue
  commit "$REPO" $'stamped\n\nFormann-Issue: #7'
  commit "$REPO" $'other\n\nFormann-Issue: #15'
  commit "$REPO" "Fix the thing (#7)"
  commit "$REPO" "Fix the other thing (#70)"

  run_helper "#7"
  assert_success
  assert_output "$(sha_of stamped)
$(sha_of "Fix the thing (#7)")"
}

@test "issue-commits — github-issues standalone (the parent is the work item): every commit since main" {
  export GH_TRACKER_REPO=test-owner/test-repo
  export FIXTURE_RESPONSES_DIR="$GH_FIXTURES/work-item-parent-zero-sub-issues/recorded-responses"
  make_consumer github-issues standalone-feature
  commit "$REPO" "a change with no ref"
  commit "$REPO" "another"

  run_helper "#27"
  assert_success
  assert_output "$(sha_of "a change with no ref")
$(sha_of another)"
}

# === cannot tell (exit 3) ====================================================

@test "issue-commits — exit 3 when the default branch can't be read" {
  mkdir -p "$REPO"
  git -C "$REPO" init --quiet --initial-branch=trunk
  commit "$REPO" "only commit, feat/01"
  link_views "$REPO" local-markdown
  md_issue trunk 01

  run_helper trunk/01
  assert_failure 3
  assert_output --partial "default branch"
}

@test "issue-commits — exit 3 when the tracker can't be read" {
  export GH_TRACKER_REPO=test-owner/test-repo
  export FIXTURE_RESPONSES_DIR="$GH_FIXTURES/multi-issue-priority-api-order/recorded-responses"
  make_consumer github-issues multi-issue
  commit "$REPO" $'stamped\n\nFormann-Issue: #7'
  export GH_SHIM_FAIL=1

  run_helper "#7"
  assert_failure 3
  assert_output --partial "tracker"
}

# === inside the sandbox ======================================================

# The sandbox's checkout is the runner-checkout: a clone whose `origin` is a
# host path the container cannot reach, which may have no local default
# branch, and whose `.formann` and `docs/formann` are mounts. The runner hands
# it RUNNER_DEFAULT_BRANCH and, under github-issues, GH_REPO (no
# GH_TRACKER_REPO).
@test "issue-commits — inside the sandbox: RUNNER_DEFAULT_BRANCH, origin/<default>, GH_REPO" {
  export FIXTURE_RESPONSES_DIR="$GH_FIXTURES/multi-issue-priority-api-order/recorded-responses"
  make_consumer github-issues multi-issue
  commit "$REPO" $'stamped\n\nFormann-Issue: #7'
  commit "$REPO" "Fix the thing (#7)"
  local stamped fixed
  stamped="$(sha_of stamped)"
  fixed="$(sha_of "Fix the thing (#7)")"

  local sandbox="$BATS_TEST_TMPDIR/sandbox-checkout"
  git clone --quiet "$REPO" "$sandbox"
  git -C "$sandbox" checkout --quiet -B multi-issue origin/multi-issue
  # The clone took the host's checked-out branch, so it has no local main.
  run ! git -C "$sandbox" show-ref --verify --quiet refs/heads/main
  git -C "$sandbox" remote set-url origin /host/path/the/container/cannot/see
  git -C "$sandbox" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/multi-issue
  link_views "$sandbox" github-issues
  export RUNNER_DEFAULT_BRANCH=main
  export GH_REPO=test-owner/test-repo

  cd "$sandbox"
  run .formann/runner/issue-commits "#7"
  assert_success
  assert_output "$stamped
$fixed"
  grep -q 'owner=test-owner' "$GH_SHIM_LOG"
}
