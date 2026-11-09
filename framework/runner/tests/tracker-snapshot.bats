#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  TRACKER_SNAPSHOT="$HERE/../../bindings/issue-tracker/local-markdown/tracker-snapshot"
  FIXTURES="$HERE/fixtures"
  export TRACKER_ROOT="$FIXTURES"
}

# Compare the script's stdout to the fixture's expected.json after
# canonicalising both via `jq -S`. Diff output appears in the bats
# failure log so a golden mismatch is self-explaining.
assert_snapshot_matches_golden() {
  local feature="$1"
  run "$TRACKER_SNAPSHOT" "$feature"
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/$feature/expected.json")
}

@test "case 1 — eligible with no blockers" {
  assert_snapshot_matches_golden "eligible-no-blockers"
}

@test "case 2 — eligible with all-done blockers" {
  assert_snapshot_matches_golden "eligible-all-done-blockers"
}

@test "case 3 — ineligible due to unmet blockers" {
  assert_snapshot_matches_golden "ineligible-unmet-blockers"
}

@test "case 4 — ineligible HITL (status passes, type fails)" {
  assert_snapshot_matches_golden "ineligible-hitl"
}

@test "case 5 — every non-ready-for-agent status is ineligible" {
  assert_snapshot_matches_golden "non-ready-states"
}

@test "case 6 — malformed frontmatter surfaces parse_error" {
  assert_snapshot_matches_golden "malformed-frontmatter"
}

@test "case 7 — cross-feature blocker forces eligible:false" {
  assert_snapshot_matches_golden "cross-feature-blocker"
}

@test "missing argument exits non-zero with usage" {
  run "$TRACKER_SNAPSHOT"
  assert_failure
  assert_output --partial "usage: tracker-snapshot"
}

# === tracker-snapshot --list ================================================
#
# Additive flag: emits a JSON array of active feature slugs (subdirs of
# tracker_root excluding done/). Today's bare invocation (no --list, no slug)
# keeps exiting 2 with a usage line — the contract grows additively.

@test "--list — emits a JSON array of active slugs" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-list"
  mkdir -p "$tracker_root/alpha" "$tracker_root/beta"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "2" ]
  local slugs
  slugs="$(printf '%s\n' "$output" | jq -r '.[]' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$slugs" = "alpha beta" ]
}

@test "--list — excludes .archived/ directory and its contents" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-archived"
  mkdir -p "$tracker_root/active" "$tracker_root/.archived" "$tracker_root/.archived/some-feature"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "1" ]
  local slug
  slug="$(printf '%s\n' "$output" | jq -r '.[0]')"
  [ "$slug" = "active" ]
}

@test "--list — ordering is deterministic (sorted by name)" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-order"
  mkdir -p "$tracker_root/zebra" "$tracker_root/apple" "$tracker_root/mango"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local first second third
  first="$(printf '%s\n' "$output" | jq -r '.[0]')"
  second="$(printf '%s\n' "$output" | jq -r '.[1]')"
  third="$(printf '%s\n' "$output" | jq -r '.[2]')"
  [ "$first" = "apple" ]
  [ "$second" = "mango" ]
  [ "$third" = "zebra" ]
}

@test "--list — empty tracker root yields empty array" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-empty"
  mkdir -p "$tracker_root"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

@test "--list — nonexistent tracker root yields empty array" {
  TRACKER_ROOT="$BATS_TEST_TMPDIR/no-such-dir" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

# Discovery: when no TRACKER_ROOT is set, the script must find the
# consumer's .features/ by walking $PWD upward for a .formann ancestor — the
# same shape build-image.sh uses to find HOST_REPO. Without this walk, the
# fallback "compute relative to BASH_SOURCE" path breaks when the role-surface
# entry point (docs/formann/issue-tracker/) is itself a directory symlink:
# `..` resolution physically follows the symlink into the framework checkout
# and lands in the wrong namespace.
@test "auto-discovers tracker_root via .formann ancestor when no env override" {
  unset TRACKER_ROOT
  local consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/.features/auto-discovered"
  # The .formann marker is what identifies the consumer root. The walk only
  # cares that the entry exists; pointing it at a real dir keeps `[ -e ]`
  # honest without requiring symlink resolution.
  ln -s "$BATS_TEST_TMPDIR" "$consumer/.formann"
  ( cd "$consumer" && "$TRACKER_SNAPSHOT" --list ) >"$BATS_TEST_TMPDIR/out" 2>&1
  run cat "$BATS_TEST_TMPDIR/out"
  assert_success
  local slugs
  slugs="$(printf '%s\n' "$output" | jq -r '.[]' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  [ "$slugs" = "auto-discovered" ]
}

# === SNAPSHOT_CHECKOUT_DIR — read from a git repo's committed HEAD ===========
#
# When SNAPSHOT_CHECKOUT_DIR is set, tracker-snapshot archives .features/ from
# that repo's committed HEAD rather than reading from TRACKER_ROOT or PWD.
# This is how the runner's take_snapshot wrapper avoids working-tree noise.

@test "SNAPSHOT_CHECKOUT_DIR — snapshots committed .features/ from a git repo" {
  local repo="$BATS_TEST_TMPDIR/snap-checkout-repo"
  local feature_dir="$repo/.features/snap-feature/issues"
  mkdir -p "$feature_dir"
  printf -- '---\nstatus: ready-for-agent\ncategory: enhancement\ntype: AFK\n---\n\n# Snap test\n\n## Blocked by\n\nNone.\n' \
    >"$feature_dir/01-snap.md"
  git -C "$repo" init --quiet
  git -C "$repo" -c user.email=t@t -c user.name=t add .features
  git -C "$repo" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  # Unset TRACKER_ROOT so the env-var fallback cannot interfere.
  unset TRACKER_ROOT
  SNAPSHOT_CHECKOUT_DIR="$repo" run "$TRACKER_SNAPSHOT" "snap-feature"
  assert_success

  local status_out nn_out eligible_out
  status_out="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  nn_out="$(printf '%s\n' "$output" | jq -r '.issues[0].nn')"
  eligible_out="$(printf '%s\n' "$output" | jq -r '.issues[0].eligible')"
  [ "$status_out" = "ready-for-agent" ]
  [ "$nn_out" = "01" ]
  [ "$eligible_out" = "true" ]
}

@test "SNAPSHOT_CHECKOUT_DIR — ignores working-tree changes not yet committed" {
  local repo="$BATS_TEST_TMPDIR/snap-wt-repo"
  local feature_dir="$repo/.features/snap-wt/issues"
  mkdir -p "$feature_dir"
  printf -- '---\nstatus: ready-for-agent\ncategory: enhancement\ntype: AFK\n---\n\n# Committed\n' \
    >"$feature_dir/01-committed.md"
  git -C "$repo" init --quiet
  git -C "$repo" -c user.email=t@t -c user.name=t add .features
  git -C "$repo" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  # Add a second issue file to the working tree but do NOT commit it.
  printf -- '---\nstatus: ready-for-agent\ncategory: enhancement\ntype: AFK\n---\n\n# Uncommitted\n' \
    >"$feature_dir/02-uncommitted.md"

  unset TRACKER_ROOT
  SNAPSHOT_CHECKOUT_DIR="$repo" run "$TRACKER_SNAPSHOT" "snap-wt"
  assert_success

  # Only the committed issue (01) should appear; the uncommitted (02) must not.
  local issue_count
  issue_count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$issue_count" = "1" ]
  local ref_out
  ref_out="$(printf '%s\n' "$output" | jq -r '.issues[0].ref')"
  [ "$ref_out" = "snap-wt/01" ]
}

@test "CRLF-encoded issue files are parsed, not silently dropped" {
  # Regression: parse_frontmatter compared each line to the bare string
  # `---`, but `read -r` does not strip a trailing `\r`. A CRLF-saved
  # issue file's `---\r` opener never matched, the parser fell through
  # to "no frontmatter" mode, and the issue surfaced with empty
  # status/type, eligible:false, and *no* parse_error — invisible to
  # the runner and the maintainer alike. The fix strips `\r` from each
  # line before comparison so the parser handles CRLF transparently.
  local feature_dir="$BATS_TEST_TMPDIR/tracker/crlf-feature/issues"
  mkdir -p "$feature_dir"
  # Write the issue with CRLF line endings throughout.
  printf -- '---\r\nstatus: ready-for-agent\r\ncategory: enhancement\r\ntype: AFK\r\n---\r\n\r\n# CRLF\r\n\r\n## Blocked by\r\n\r\nNone.\r\n' \
    >"$feature_dir/01-crlf.md"

  TRACKER_ROOT="$BATS_TEST_TMPDIR/tracker" \
    run "$TRACKER_SNAPSHOT" "crlf-feature"
  assert_success

  # Issue parsed: status/type populated, eligible:true, no parse_error.
  local status_field type_field eligible_field has_parse_error
  status_field="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  type_field="$(printf '%s\n' "$output" | jq -r '.issues[0].type')"
  eligible_field="$(printf '%s\n' "$output" | jq -r '.issues[0].eligible')"
  has_parse_error="$(printf '%s\n' "$output" | jq 'has("issues") and (.issues[0] | has("parse_error"))')"
  [ "$status_field" = "ready-for-agent" ]
  [ "$type_field" = "AFK" ]
  [ "$eligible_field" = "true" ]
  [ "$has_parse_error" = "false" ]
}

# === tracker-snapshot --any-eligible ==========================================
#
# `yes` when some active feature's snapshot holds an eligible issue, `no`
# otherwise — the cheap check the runner makes before a drain pass.

# Write an issue file. Args: $1=tracker root  $2=feature  $3=NN  $4=status
# $5=type  $6=blocked-by line (default "None.")
_lm_issue() {
  local root="$1" feature="$2" nn="$3" status="$4" type="$5" blocked="${6:-None.}"
  mkdir -p "$root/$feature/issues"
  printf -- '---\nstatus: %s\ncategory: enhancement\ntype: %s\n---\n\n# Issue %s\n\n## Blocked by\n\n%s\n' \
    "$status" "$type" "$nn" "$blocked" >"$root/$feature/issues/$nn-issue.md"
}

@test "--any-eligible — no when every ready AFK issue has an unfinished blocker in its feature" {
  local root="$BATS_TEST_TMPDIR/any-unfinished"
  _lm_issue "$root" alpha 01 in-review AFK
  _lm_issue "$root" alpha 02 ready-for-agent AFK "- alpha/01"
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible — no when the only blocker is done but in another feature" {
  local root="$BATS_TEST_TMPDIR/any-external"
  _lm_issue "$root" alpha 01 ready-for-agent AFK "- beta/01"
  _lm_issue "$root" beta 01 done AFK
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible — no when the only ready issues are HITL" {
  local root="$BATS_TEST_TMPDIR/any-hitl"
  _lm_issue "$root" alpha 01 ready-for-agent HITL
  _lm_issue "$root" beta 01 ready-for-agent HITL
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible — no for an empty or missing tracker root, and archived features don't count" {
  local root="$BATS_TEST_TMPDIR/any-empty"
  mkdir -p "$root"
  _lm_issue "$root/.archived" old 01 ready-for-agent AFK
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
  TRACKER_ROOT="$BATS_TEST_TMPDIR/no-such-root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible — yes when one ready AFK issue (in a later feature) is unblocked" {
  local root="$BATS_TEST_TMPDIR/any-unblocked"
  _lm_issue "$root" alpha 01 ready-for-agent HITL
  _lm_issue "$root" beta 01 ready-for-agent AFK
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible — yes when all its blockers in the same feature are done" {
  local root="$BATS_TEST_TMPDIR/any-all-done"
  _lm_issue "$root" alpha 01 done AFK
  _lm_issue "$root" alpha 02 done AFK
  _lm_issue "$root" alpha 03 ready-for-agent AFK "- alpha/01
- alpha/02"
  TRACKER_ROOT="$root" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible agrees with 'some issue is eligible' on every snapshot fixture" {
  local checked=0 dir name want got root
  for dir in "$FIXTURES"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    [ -f "$dir/expected.json" ] && [ -d "$dir/issues" ] || continue
    want="$(jq -r 'if any(.issues[]; .eligible == true) then "yes" else "no" end' "$dir/expected.json")"
    # A tracker root holding this one feature only.
    root="$BATS_TEST_TMPDIR/agree/$name"
    mkdir -p "$root"
    cp -R "$dir" "$root/$name"
    got="$(TRACKER_ROOT="$root" "$TRACKER_SNAPSHOT" --any-eligible)"
    if [ "$got" != "$want" ]; then
      echo "$name: --any-eligible said $got, the snapshot says $want" >&2
      return 1
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -ge 7 ]
  # And all of them together: some fixture is eligible.
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible — reads the feature's committed branch when it is ahead of the working tree" {
  # The runner snapshots a feature on its own branch. An issue made ready
  # there (and not on the branch checked out in the working tree) is work.
  local repo="$BATS_TEST_TMPDIR/any-branch-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=main
  _lm_issue "$repo/.features" alpha 01 needs-triage AFK
  git -C "$repo" add .features
  git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m init
  TRACKER_ROOT="$repo/.features" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_output "no"

  git -C "$repo" checkout --quiet -b alpha
  _lm_issue "$repo/.features" alpha 01 ready-for-agent AFK
  git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -am "tracker: ready"
  git -C "$repo" checkout --quiet main

  TRACKER_ROOT="$repo/.features" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"

  # A remote-tracking branch of that name counts the same way.
  local other="$BATS_TEST_TMPDIR/any-branch-other"
  git clone --quiet "$repo" "$other"
  git -C "$repo" branch --quiet -D alpha
  TRACKER_ROOT="$repo/.features" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_output "no"
  [ -d "$other/.features/alpha" ]
  TRACKER_ROOT="$other/.features" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible — with SNAPSHOT_CHECKOUT_DIR reads that repo's HEAD (not the working tree)" {
  local repo="$BATS_TEST_TMPDIR/any-checkout"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=main
  _lm_issue "$repo/.features" alpha 01 ready-for-agent AFK
  git -C "$repo" add .features
  git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m init
  # Uncommitted: the issue is no longer ready in the working tree.
  _lm_issue "$repo/.features" alpha 01 in-review AFK
  unset TRACKER_ROOT
  SNAPSHOT_CHECKOUT_DIR="$repo" run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}
