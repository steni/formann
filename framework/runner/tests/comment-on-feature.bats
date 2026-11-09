#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Both bindings' `comment-on-feature <feature> <Kind>` realize "Comment with
# `<kind>`" on the feature's parent — the runner posts its claim Note through
# it. Same heading convention, same same-day suffix rule.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BINDINGS="$HERE/../../bindings/issue-tracker"
  LM="$BINDINGS/local-markdown/comment-on-feature"
  GH="$BINDINGS/github-issues/comment-on-feature"
  TODAY="$(date -u +%Y-%m-%d)"

  # gh shim. `issue list` prints $GH_PARENTS (the --jq projection: one
  # number per line); `issue view` prints $GH_COMMENTS_JSON; `issue comment`
  # records its issue number and body.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    printf '%s\n' "$*" >"$GH_LOG.list-args"
    printf '%s' "$GH_PARENTS"; exit 0 ;;
  "issue view")
    # A plain-variable default: bash 3.2 keeps the backslash in an escaped
    # `\}` inside ${…:-…}, which would hand jq `{"comments":[]\}`.
    no_comments='{"comments":[]}'
    printf '%s' "${GH_COMMENTS_JSON:-$no_comments}"; exit 0 ;;
  "issue comment")
    num="$3"; shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in --body) body="$2"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$num" >"$GH_LOG.num"
    printf '%s' "$body" >"$GH_LOG.body"
    exit 0 ;;
esac
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"
  export PATH="$FAKE_BIN:$PATH"
  export GH_TRACKER_REPO="test-owner/test-repo"
  export GH_LOG="$BATS_TEST_TMPDIR/gh"
}

lm_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.features/alpha"
  git init --quiet --initial-branch=alpha "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  printf '# Alpha\n\n## Gist\n\nA feature.\n' >"$REPO/.features/alpha/PRD.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit --quiet -m init
}

@test "comment-on-feature (github-issues) — posts a Note on the feature's parent issue, located by its labels" {
  export GH_PARENTS=$'12\n'
  run --separate-stderr bash -c 'printf "the body\n" | "$0" alpha Note' "$GH"
  assert_success
  assert_output "#12"
  [ "$(cat "$GH_LOG.num")" = "12" ]
  [ "$(cat "$GH_LOG.body")" = "$(printf '### Note — %s\n\nthe body' "$TODAY")" ]
  grep -q -- '--label formann:feature --label formann:slug:alpha' "$GH_LOG.list-args"
}

@test "comment-on-feature (github-issues) — a same-day Note already there: suffixed (2)" {
  export GH_PARENTS=$'12\n'
  export GH_COMMENTS_JSON="{\"comments\":[{\"body\":\"### Note — $TODAY\\n\\nearlier\"},{\"body\":\"### Implementation — $TODAY\\n\\nx\"}]}"
  run --separate-stderr bash -c 'printf "b\n" | "$0" alpha Note' "$GH"
  assert_success
  [ "$(head -n 1 "$GH_LOG.body")" = "### Note (2) — $TODAY" ]
}

@test "comment-on-feature (github-issues) — no parent, or a slug collision: exit 1, nothing posted" {
  export GH_PARENTS=""
  run --separate-stderr bash -c 'printf "b\n" | "$0" alpha Note' "$GH"
  assert_failure 1
  [ ! -f "$GH_LOG.body" ]
  export GH_PARENTS=$'3\n9\n'
  run --separate-stderr bash -c 'printf "b\n" | "$0" alpha Note' "$GH"
  assert_failure 1
  [[ "$stderr" == *"#3"*"#9"* ]]
  [ ! -f "$GH_LOG.body" ]
}

@test "comment-on-feature (local-markdown) — appends a Note under ## Comments of the PRD and commits it as tracker:" {
  lm_repo
  run --separate-stderr bash -c 'printf "the body\n" | TRACKER_CHECKOUT_DIR="$1" "$0" alpha Note' "$LM" "$REPO"
  assert_success
  assert_output ".features/alpha/PRD.md"
  # Committed, working tree clean.
  [ -z "$(git -C "$REPO" status --porcelain)" ]
  [ "$(git -C "$REPO" log -1 --format=%s)" = "tracker: alpha — Note on the feature" ]
  local committed
  committed="$(git -C "$REPO" show HEAD:.features/alpha/PRD.md)"
  [ "$committed" = "$(printf '# Alpha\n\n## Gist\n\nA feature.\n\n## Comments\n\n### Note — %s\n\nthe body' "$TODAY")" ]
}

@test "comment-on-feature (local-markdown) — a second same-day Note is suffixed (2), one ## Comments section" {
  lm_repo
  printf 'one\n' | TRACKER_CHECKOUT_DIR="$REPO" "$LM" alpha Note >/dev/null
  printf 'two\n' | TRACKER_CHECKOUT_DIR="$REPO" "$LM" alpha Note >/dev/null
  [ "$(grep -c '^## Comments$' "$REPO/.features/alpha/PRD.md")" = "1" ]
  grep -qx "### Note — $TODAY" "$REPO/.features/alpha/PRD.md"
  grep -qx "### Note (2) — $TODAY" "$REPO/.features/alpha/PRD.md"
}

@test "comment-on-feature (local-markdown) — a feature without PRD.md has no parent: exit 1, nothing committed" {
  lm_repo
  local before
  before="$(git -C "$REPO" rev-parse HEAD)"
  run --separate-stderr bash -c 'printf "b\n" | TRACKER_CHECKOUT_DIR="$1" "$0" beta Note' "$LM" "$REPO"
  assert_failure 1
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$before" ]
}

@test "comment-on-feature — both bindings: usage errors exit 2" {
  run "$LM" alpha
  assert_failure 2
  run "$GH" alpha
  assert_failure 2
}
