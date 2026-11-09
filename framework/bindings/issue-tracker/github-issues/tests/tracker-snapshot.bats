#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  TRACKER_SNAPSHOT="$HERE/../tracker-snapshot"
  FIXTURES="$HERE/fixtures"

  # Scratch dir for gh shim + call log
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # Create the gh shim.
  # Handles: gh api graphql → records call, optionally fails (FAIL_FIRST_N),
  # then serves ${FIXTURE_RESPONSES_DIR}/graphql-response.json.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  # Count calls (this call not yet recorded)
  # Count logged calls, not log lines: a query spans several lines.
  prior_count=$(grep -c '^graphql call' "${CALL_LOG}" 2>/dev/null)
  call_num=$((prior_count + 1))
  echo "graphql call $call_num: $*" >>"${CALL_LOG}"

  # Optionally fail the first N calls to simulate transient errors
  fail_n="${FAIL_FIRST_N:-0}"
  if [ "$call_num" -le "$fail_n" ]; then
    echo "gh: API rate limit exceeded" >&2
    exit 1
  fi

  # Serve the fixture response
  if [ -f "${FIXTURE_RESPONSES_DIR}/graphql-response-${call_num}.json" ]; then
    cat "${FIXTURE_RESPONSES_DIR}/graphql-response-${call_num}.json"
    exit 0
  elif [ -f "${FIXTURE_RESPONSES_DIR}/graphql-response.json" ]; then
    cat "${FIXTURE_RESPONSES_DIR}/graphql-response.json"
    exit 0
  fi

  echo "shim: no fixture response for call $call_num in ${FIXTURE_RESPONSES_DIR}" >&2
  exit 1
fi
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"

  # Prepend fake bin so our shim wins PATH lookup.
  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"

  # Suppress git-remote detection — all tests use the env var override.
  export GH_TRACKER_REPO="test-owner/test-repo"

  # Ensure jq is available (installed to ~/bin in this environment).
  export PATH="$HOME/bin:$PATH"
}

# ── Helper: compare snapshot output to an expected.json (jq-normalised) ───────
assert_snapshot_matches_golden() {
  local scenario="$1" slug="$2"
  export FIXTURE_RESPONSES_DIR="$FIXTURES/$scenario/recorded-responses"
  run "$TRACKER_SNAPSHOT" "$slug"
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/$scenario/expected.json")
}

# ── Helper: graphql call count ────────────────────────────────────────────────
graphql_call_count() {
  grep -c "^graphql call" "$CALL_LOG" 2>/dev/null || echo 0
}

# ════════════════════════════════════════════════════════════════════════════════
# Slug-mode fixtures
# ════════════════════════════════════════════════════════════════════════════════

@test "empty feature — 0 sub-issues yields empty issues array" {
  assert_snapshot_matches_golden "empty-feature" "empty-feature"
}

@test "single-issue feature — correct ref, status, category, type, eligible" {
  assert_snapshot_matches_golden "single-issue-feature" "single-issue-feature"
}

@test "multi-issue priority ordering — subIssues API order preserved unchanged" {
  assert_snapshot_matches_golden "multi-issue-priority-api-order" "multi-issue"
}

@test "unresolved #N blocker — conservative-false eligibility" {
  assert_snapshot_matches_golden "unresolved-blocker-conservative-false" "unresolved-blocker"
}

# ── Slug mode: 0-match case ───────────────────────────────────────────────────
@test "slug mode: 0 parent matches — emits empty snapshot and exits 0" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/zero-match"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[]}}}}
JSON
  run "$TRACKER_SNAPSHOT" "no-such-feature"
  assert_success
  feature="$(printf '%s\n' "$output" | jq -r '.feature')"
  count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$feature" = "no-such-feature" ]
  [ "$count" = "0" ]
}

# ── Slug mode: slug collision (≥2 matches) ────────────────────────────────────
@test "slug-collision — exits non-zero (code 4) and names both parents on stderr" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/slug-collision/recorded-responses"
  run "$TRACKER_SNAPSHOT" "my-feature"
  [ "$status" -eq 4 ]
  assert_output --partial "#8"
  assert_output --partial "#11"
}

# ════════════════════════════════════════════════════════════════════════════════
# Work-item parent (formann:feature + formann:status:*)
# ════════════════════════════════════════════════════════════════════════════════

@test "work-item parent with zero sub-issues — parent is the single issues[] entry" {
  assert_snapshot_matches_golden "work-item-parent-zero-sub-issues" "standalone-feature"
}

@test "work-item parent with sub-issues — parent first, sub-issues follow in API order" {
  assert_snapshot_matches_golden "work-item-parent-with-sub-issues" "standalone-with-subs"
}

@test "archive guard: non-terminal work-item parent with zero sub-issues — present in issues[] with non-terminal status" {
  # Models the scenario where the archive non-terminal guard must refuse:
  # a standalone work-item parent (no sub-issues) whose status is ready-for-agent.
  # Iterating issues[] (not just sub-issues) catches this entry.
  assert_snapshot_matches_golden "archive-guard-non-terminal-work-item-parent" "standalone-nonterminal"
  export FIXTURE_RESPONSES_DIR="$FIXTURES/archive-guard-non-terminal-work-item-parent/recorded-responses"
  run "$TRACKER_SNAPSHOT" "standalone-nonterminal"
  status_val="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$count" = "1" ]
  [ "$status_val" != "done" ]
  [ "$status_val" != "wontfix" ]
}

@test "--list: mixed repo — pure-container and work-item parent both returned" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-both-shapes/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/list-both-shapes/expected.json")
}

@test "slug-collision between two work-item parents — exits code 4, names both on stderr" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/slug-collision-work-item-parents/recorded-responses"
  run "$TRACKER_SNAPSHOT" "shared-slug"
  [ "$status" -eq 4 ]
  assert_output --partial "#8"
  assert_output --partial "#11"
}

# ── One GraphQL query per invocation ─────────────────────────────────────────
@test "one GraphQL query per slug invocation" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/single-issue-feature/recorded-responses"
  run "$TRACKER_SNAPSHOT" "single-issue-feature"
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

@test "one GraphQL query per --list invocation" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

# ════════════════════════════════════════════════════════════════════════════════
# --list mode fixtures
# ════════════════════════════════════════════════════════════════════════════════

@test "--list: archived (closed) parent absent — only open parents returned" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/list-archived-excluded/expected.json")
}

@test "--list: ordered by #N ascending (in-script sort_by(.number))" {
  # Fixture returns issues out of #N order (#7, #5-closed, #3) — verify the
  # in-script sort delivers #N ASC output regardless of API return order.
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  first="$(printf '%s\n' "$output" | jq -r '.[0]')"
  second="$(printf '%s\n' "$output" | jq -r '.[1]')"
  [ "$first" = "alpha-feature" ]
  [ "$second" = "beta-feature" ]
}

@test "--list: issues with no formann:slug:* label are silently skipped" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/no-slug"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {"number": 1, "labels": {"nodes": [{"name": "formann:feature"}]}},
          {"number": 2, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:has-slug"}]}}
        ]
      }
    }
  }
}
JSON
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  count="$(printf '%s\n' "$output" | jq 'length')"
  slug="$(printf '%s\n' "$output" | jq -r '.[0]')"
  [ "$count" = "1" ]
  [ "$slug" = "has-slug" ]
}

@test "--list: duplicate slug warns on stderr, deduplicates in output" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/dupe-slug"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {"number": 5, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:shared"}]}},
          {"number": 9, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:shared"}]}}
        ]
      }
    }
  }
}
JSON
  run --separate-stderr "$TRACKER_SNAPSHOT" --list
  assert_success
  # Slug appears only once in the JSON array (stdout only)
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "1" ]
  # Warning mentions both parent numbers on stderr
  [[ "$stderr" == *"#5"* ]] || { echo "Expected #5 in stderr: $stderr" >&2; return 1; }
  [[ "$stderr" == *"#9"* ]] || { echo "Expected #9 in stderr: $stderr" >&2; return 1; }
  [[ "$stderr" == *"shared"* ]] || { echo "Expected 'shared' in stderr: $stderr" >&2; return 1; }
}

# ════════════════════════════════════════════════════════════════════════════════
# Transient failure / retry
# ════════════════════════════════════════════════════════════════════════════════

@test "transient-error retry success — first call fails, second succeeds, output correct" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/transient-error-retry-success/recorded-responses"
  export FAIL_FIRST_N=1
  run --separate-stderr "$TRACKER_SNAPSHOT" "retry-feature"
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -ge 2 ]
  issue_count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$issue_count" = "1" ]
}

@test "transient-error retry exhaustion — all calls fail, exits with code 3" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/always-fail"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  export FAIL_FIRST_N=99
  run "$TRACKER_SNAPSHOT" "some-feature"
  [ "$status" -eq 3 ]
  assert_output --partial "failed after"
}

# ════════════════════════════════════════════════════════════════════════════════
# Usage and pre-condition errors
# ════════════════════════════════════════════════════════════════════════════════

@test "missing argument exits non-zero with usage message" {
  run "$TRACKER_SNAPSHOT"
  assert_failure
  assert_output --partial "usage: tracker-snapshot"
}

@test "done sub-issue is not eligible even with correct status label absent" {
  # done is derived from state=CLOSED+stateReason=COMPLETED, not from a label.
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/done-closed"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {
            "number": 1,
            "subIssues": {
              "nodes": [
                {
                  "number": 2,
                  "state": "CLOSED",
                  "stateReason": "COMPLETED",
                  "labels": {"nodes": [{"name": "formann:category:enhancement"}, {"name": "formann:type:afk"}]},
                  "blockedBy": {"nodes": []}
                }
              ]
            }
          }
        ]
      }
    }
  }
}
JSON
  run "$TRACKER_SNAPSHOT" "done-feature"
  assert_success
  status_val="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  eligible_val="$(printf '%s\n' "$output" | jq -r '.issues[0].eligible')"
  [ "$status_val" = "done" ]
  [ "$eligible_val" = "false" ]
}

# ════════════════════════════════════════════════════════════════════════════════
# Origin-URL parsing (the GH_TRACKER_REPO fallback path)
#
# These tests exercise the code path that runs when GH_TRACKER_REPO is unset.
# The script reads `git remote get-url origin` and parses owner/repo out of it.
# Coverage spans both URL shapes (https://, git@:) and both sed dialects (GNU
# on Linux, BSD on macOS) — the parse uses ERE so `https?` is portable.
# ════════════════════════════════════════════════════════════════════════════════

# Helper: spin up a scratch git repo with a known origin URL, then run
# tracker-snapshot from inside it with the GH_TRACKER_REPO override unset.
# Returns: leaves $CALL_LOG populated; caller asserts on grep'd flags.
_parse_origin_and_call() {
  local origin_url="$1" slug="$2"
  local scratch="$BATS_TEST_TMPDIR/scratch-$BATS_TEST_NUMBER"
  mkdir -p "$scratch"
  ( cd "$scratch" && git init -q && git remote add origin "$origin_url" )

  unset GH_TRACKER_REPO
  export FIXTURE_RESPONSES_DIR="$FIXTURES/empty-feature/recorded-responses"

  cd "$scratch"
  run "$TRACKER_SNAPSHOT" "$slug"
}

@test "parses https://github.com/<owner>/<repo>.git origin URL" {
  _parse_origin_and_call "https://github.com/some-owner/some-repo.git" "some-slug"
  assert_success
  # The gh shim records every call with its full arg list; assert the
  # owner/name flags carry the *parsed* values, not the raw URL fragment.
  run cat "$CALL_LOG"
  assert_output --partial "owner=some-owner"
  assert_output --partial "name=some-repo"
  refute_output --partial "owner=https:"
  refute_output --partial "name=some-repo.git"
}

@test "parses https://github.com/<owner>/<repo> origin URL (no .git suffix)" {
  _parse_origin_and_call "https://github.com/some-owner/some-repo" "some-slug"
  assert_success
  run cat "$CALL_LOG"
  assert_output --partial "owner=some-owner"
  assert_output --partial "name=some-repo"
}

@test "parses http://github.com/<owner>/<repo>.git origin URL" {
  _parse_origin_and_call "http://github.com/some-owner/some-repo.git" "some-slug"
  assert_success
  run cat "$CALL_LOG"
  assert_output --partial "owner=some-owner"
  assert_output --partial "name=some-repo"
}

@test "parses git@github.com:<owner>/<repo>.git origin URL (SSH form)" {
  _parse_origin_and_call "git@github.com:some-owner/some-repo.git" "some-slug"
  assert_success
  run cat "$CALL_LOG"
  assert_output --partial "owner=some-owner"
  assert_output --partial "name=some-repo"
}

# ════════════════════════════════════════════════════════════════════════════════
# --any-eligible
#
# One question for the whole tracker: is any issue in any active feature
# eligible?  Answered by one GraphQL query over the open ready-for-agent issues
# (plus pages), never by a snapshot per feature.
# ════════════════════════════════════════════════════════════════════════════════

# Write an --any-eligible response page holding the given issue nodes (a JSON
# array) to $FIXTURE_RESPONSES_DIR/graphql-response[-N].json.
# Args: $1 = nodes JSON array  $2 = page file suffix ("" or "-N")
#       $3 = hasNextPage (default false)  $4 = endCursor (default null)
_any_page() {
  local nodes="$1" suffix="${2:-}" next="${3:-false}" cursor="${4:-null}"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  jq -n --argjson nodes "$nodes" --argjson next "$next" --argjson cursor "$cursor" \
    '{data:{repository:{issues:{pageInfo:{hasNextPage:$next,endCursor:$cursor},nodes:$nodes}}}}' \
    >"$FIXTURE_RESPONSES_DIR/graphql-response${suffix}.json"
}

# One ready-for-agent node.  Args: $1 = number  $2 = type label (afk|hitl)
# $3 = parent JSON (null for a standalone)  $4 = blockedBy nodes JSON array
# $5 = extra labels JSON array (default [])
_ready_node() {
  jq -n --argjson n "$1" --arg t "$2" --argjson p "$3" --argjson b "$4" \
    --argjson extra "${5:-[]}" \
    '{number:$n, state:"OPEN",
      labels:{nodes:([{name:"formann:status:ready-for-agent"},{name:"formann:category:enhancement"},{name:("formann:type:" + $t)}] + $extra)},
      parent:$p, blockedBy:{nodes:$b}}'
}

_feature_parent='{"number":10,"state":"OPEN","labels":{"nodes":[{"name":"formann:feature"},{"name":"formann:slug:alpha"}]}}'

@test "--any-eligible: no when every ready AFK issue is blocked by an unfinished blocker in its feature" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-unfinished"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":12,"state":"OPEN","stateReason":null,"parent":{"number":10}}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when the only blocker is done but external (another feature's sub-issue)" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-external"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":40,"state":"CLOSED","stateReason":"COMPLETED","parent":{"number":39}}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when the only blocker is done but has no parent (a standalone outside the feature)" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-orphan-blocker"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":40,"state":"CLOSED","stateReason":"COMPLETED","parent":null}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when a blocker in the feature was closed as not planned" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-wontfix"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":12,"state":"CLOSED","stateReason":"NOT_PLANNED","parent":{"number":10}}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when the only ready issues are HITL" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-hitl"
  _any_page "[$(_ready_node 11 hitl "$_feature_parent" '[]'),$(_ready_node 13 hitl null '[]' '[{"name":"formann:feature"},{"name":"formann:slug:solo"}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when no issue is ready at all" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-none"
  _any_page '[]'
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: no when the ready issue is in no feature (parent closed, or no slug anywhere)" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-no-feature"
  _any_page "[$(_ready_node 11 afk '{"number":10,"state":"CLOSED","labels":{"nodes":[{"name":"formann:slug:alpha"}]}}' '[]'),$(_ready_node 13 afk '{"number":20,"state":"OPEN","labels":{"nodes":[]}}' '[]'),$(_ready_node 15 afk null '[]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
}

@test "--any-eligible: yes when one ready AFK issue is unblocked" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-unblocked"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":12,"state":"OPEN","stateReason":null,"parent":{"number":10}}]'),$(_ready_node 14 afk "$_feature_parent" '[]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible: yes when all its blockers in the same feature are done" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-all-done"
  _any_page "[$(_ready_node 11 afk "$_feature_parent" '[{"number":12,"state":"CLOSED","stateReason":"COMPLETED","parent":{"number":10}},{"number":13,"state":"CLOSED","stateReason":"COMPLETED","parent":{"number":10}}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible: yes for a standalone work item whose blocker is its own done sub-issue" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-standalone"
  _any_page "[$(_ready_node 27 afk null '[{"number":30,"state":"CLOSED","stateReason":"COMPLETED","parent":{"number":27}}]' '[{"name":"formann:feature"},{"name":"formann:slug:solo"}]')]"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
}

@test "--any-eligible: one GraphQL query for a single page, filtered on the ready-for-agent label" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-one-call"
  _any_page '[]'
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  [ "$(graphql_call_count)" -eq 1 ]
  grep -q 'formann:status:ready-for-agent' "$CALL_LOG"
}

@test "--any-eligible: follows pages until it finds an eligible issue" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-pages"
  _any_page "[$(_ready_node 11 hitl "$_feature_parent" '[]')]" "-1" true '"CURSOR1"'
  _any_page "[$(_ready_node 14 afk "$_feature_parent" '[]')]" "-2" true '"CURSOR2"'
  _any_page '[]' "-3"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "yes"
  # Page 2 answered it; page 3 is never asked for.
  [ "$(graphql_call_count)" -eq 2 ]
  # The second call (and only it) carries page 1's cursor.
  grep '^graphql call 2:' "$CALL_LOG" | grep -q 'cursor=CURSOR1'
  [ -z "$(grep '^graphql call 1:' "$CALL_LOG" | grep 'cursor=' || true)" ]
}

@test "--any-eligible: no after the last page when no page has an eligible issue" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-pages-no"
  _any_page "[$(_ready_node 11 hitl "$_feature_parent" '[]')]" "-1" true '"CURSOR1"'
  _any_page "[$(_ready_node 14 hitl "$_feature_parent" '[]')]" "-2"
  run "$TRACKER_SNAPSHOT" --any-eligible
  assert_success
  assert_output "no"
  [ "$(graphql_call_count)" -eq 2 ]
}

@test "--any-eligible: a persistent API failure exits 3" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/any-fail"
  _any_page '[]'
  export FAIL_FIRST_N=99
  run --separate-stderr "$TRACKER_SNAPSHOT" --any-eligible
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# Rewrite a recorded <slug>-mode response as the --any-eligible query would
# see the same tracker: the parent (labelled with the slug, as the slug query
# implies) and its sub-issues, keeping the open ready-for-agent ones, each with
# its parent and its blockers' state, close reason and parent.  A blocker
# outside the recorded set is an open issue outside the feature.
_as_any_eligible_response() {
  local slug="$1" in="$2"
  jq --arg slug "$slug" '
    (.data.repository.issues.nodes[0]) as $p
    | ($p.labels.nodes // []) as $pl
    | ($pl + (if any($pl[]; .name == ("formann:slug:" + $slug)) then []
              else [{name: ("formann:slug:" + $slug)}] end)) as $plabels
    | {number: $p.number, state: ($p.state // "OPEN"), labels: {nodes: $plabels}} as $pnode
    | ([{number: $p.number, state: ($p.state // "OPEN"), stateReason: $p.stateReason,
         labels: {nodes: $plabels}, blockedBy: ($p.blockedBy // {nodes: []}), parent: null}]
       + [($p.subIssues.nodes // [])[] | . + {parent: $pnode}]) as $all
    | {data: {repository: {issues: {pageInfo: {hasNextPage: false, endCursor: null},
        nodes: [ $all[]
          | select((.state // "OPEN") == "OPEN")
          | select(any(.labels.nodes[]?; .name == "formann:status:ready-for-agent"))
          | . as $i
          | .blockedBy.nodes = [ ($i.blockedBy.nodes // [])[] | .number as $n
              | (first($all[] | select(.number == $n)) // null) as $b
              | if $b then {number: $n, state: ($b.state // "OPEN"), stateReason: $b.stateReason,
                            parent: (if $b.parent then {number: $b.parent.number} else null end)}
                else {number: $n, state: "OPEN", stateReason: null, parent: null} end ] ]}}}}' "$in"
}

@test "--any-eligible agrees with 'some issue is eligible' on every recorded snapshot fixture" {
  local checked=0 dir slug want got
  for dir in "$FIXTURES"/*/; do
    dir="${dir%/}"
    [ -f "$dir/expected.json" ] || continue
    # Slug-mode goldens only (the --list goldens are arrays).
    jq -e 'type == "object" and has("issues")' "$dir/expected.json" >/dev/null || continue
    slug="$(jq -r '.feature' "$dir/expected.json")"
    want="$(jq -r 'if any(.issues[]; .eligible == true) then "yes" else "no" end' "$dir/expected.json")"
    export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/agree-$(basename "$dir")"
    mkdir -p "$FIXTURE_RESPONSES_DIR"
    _as_any_eligible_response "$slug" "$dir/recorded-responses/graphql-response.json" \
      >"$FIXTURE_RESPONSES_DIR/graphql-response.json"
    got="$("$TRACKER_SNAPSHOT" --any-eligible)"
    if [ "$got" != "$want" ]; then
      echo "$(basename "$dir"): --any-eligible said $got, the snapshot says $want" >&2
      return 1
    fi
    checked=$((checked + 1))
  done
  # The fixture set has both answers; make sure the loop really ran over them.
  [ "$checked" -ge 7 ]
}
