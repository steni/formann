#!/usr/bin/env bats

# sandbox-token-check: refuses a sandbox token that can publish (#36).
# The token comes from the real sandbox-env, fed by a `security` shim; `gh`
# is a shim that answers `gh api --include rate_limit` with a header block.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  CHECK="$HERE/../sandbox-token-check"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$GH_CALLS"
  export GH_CALLS

  # security shim: returns $FAKE_TOKEN for find-generic-password -w.
  cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "find-generic-password" ]]; then
  [[ -n "${FAKE_TOKEN_MISSING:-}" ]] && exit 44
  for arg in "$@"; do
    [[ "$arg" == "-w" ]] && { printf '%s\n' "$FAKE_TOKEN"; exit 0; }
  done
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/security"

  cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-C" ]]; then shift 2; fi
if [[ "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then echo "/fake/repo"; exit 0; fi
if [[ "$1" == "remote" && "$2" == "get-url" && "$3" == "origin" ]]; then
  echo "https://github.com/owner/repo.git"; exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/git"

  # gh shim. Logs argv and whether GH_TOKEN carried the token from the store.
  #   FAKE_GH_STATUS — HTTP status line code (default 200)
  #   FAKE_GH_SCOPES — X-OAuth-Scopes value; unset → header absent
  #   FAKE_GH_NETFAIL — non-empty: no response at all, exit 1
  cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "argv: $*" >>"$GH_CALLS"
[[ "${GH_TOKEN:-}" == "$FAKE_TOKEN" ]] && echo "env GH_TOKEN: the stored token" >>"$GH_CALLS"
if [[ -n "${FAKE_GH_NETFAIL:-}" ]]; then
  echo "error connecting to api.github.com" >&2; exit 1
fi
status="${FAKE_GH_STATUS:-200}"
printf 'HTTP/2.0 %s X\r\n' "$status"
printf 'Access-Control-Expose-Headers: ETag, X-OAuth-Scopes, X-Accepted-OAuth-Scopes\r\n'
if [[ -n "${FAKE_GH_SCOPES+x}" ]]; then
  printf 'X-Oauth-Scopes: %s\r\n' "$FAKE_GH_SCOPES"
fi
printf '\r\n{"resources":{}}'
[[ "$status" == 2* ]] || exit 1
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"

  export PATH="$FAKE_BIN:$PATH"
  export OSTYPE="darwin21"
  unset FAKE_GH_SCOPES FAKE_GH_STATUS FAKE_GH_NETFAIL FAKE_TOKEN_MISSING
  export FAKE_TOKEN="ghp_SECRETclassic0123456789"
}

@test "classic ghp_ token with repo scope — refused (exit 1), message names the fine-grained token" {
  export FAKE_GH_SCOPES="read:org, repo, workflow"
  run "$CHECK"
  [ "$status" -eq 1 ]
  assert_output --partial "refused"
  assert_output --partial "'repo'"
  assert_output --partial "Fine-grained tokens"
  assert_output --partial "Issues: Read and write"
  assert_output --partial "Contents: Read-only"
  assert_output --partial "RUNNER_SANDBOX_TOKEN_MAY_PUBLISH=1"
  refute_output --partial "$FAKE_TOKEN"
  # The token reached gh through the environment, never argv.
  grep -qx "argv: api --include rate_limit" "$GH_CALLS"
  grep -qx "env GH_TOKEN: the stored token" "$GH_CALLS"
  ! grep -qF "$FAKE_TOKEN" "$GH_CALLS"
}

@test "classic ghp_ token with public_repo scope — refused" {
  export FAKE_GH_SCOPES="public_repo"
  run "$CHECK"
  [ "$status" -eq 1 ]
  assert_output --partial "'public_repo'"
  refute_output --partial "$FAKE_TOKEN"
}

@test "classic ghp_ token with only read:org — passes" {
  export FAKE_GH_SCOPES="read:org"
  run "$CHECK"
  assert_success
  assert_output --partial "classic token without repo/public_repo scope"
  refute_output --partial "$FAKE_TOKEN"
}

@test "classic token: repo:status / repo_deployment do not count as repo" {
  export FAKE_GH_SCOPES="repo:status, repo_deployment, read:org"
  run "$CHECK"
  assert_success
}

@test "classic token: X-OAuth-Scopes only in Access-Control-Expose-Headers — no scopes, passes" {
  # The expose-headers line names X-OAuth-Scopes too; only the header itself counts.
  run "$CHECK"
  assert_success
  assert_output --partial "scopes: none"
}

@test "gho_ token with repo scope — refused" {
  export FAKE_TOKEN="gho_SECREToauth0123456789" FAKE_GH_SCOPES="repo"
  run "$CHECK"
  [ "$status" -eq 1 ]
  refute_output --partial "$FAKE_TOKEN"
}

@test "github_pat_ fine-grained token — passes without an API call deciding it" {
  export FAKE_TOKEN="github_pat_SECRETfine0123456789"
  # Were gh asked, it would answer `repo` and the check would refuse.
  export FAKE_GH_SCOPES="repo"
  run "$CHECK"
  assert_success
  assert_output --partial "fine-grained"
  refute_output --partial "$FAKE_TOKEN"
  [ ! -s "$GH_CALLS" ]
}

@test "ghs_ App installation token — passes without an API call" {
  export FAKE_TOKEN="ghs_SECRETapp0123456789" FAKE_GH_SCOPES="repo"
  run "$CHECK"
  assert_success
  [ ! -s "$GH_CALLS" ]
}

@test "transient: network failure — exit 3, not a refusal" {
  export FAKE_GH_NETFAIL=1
  run "$CHECK"
  [ "$status" -eq 3 ]
  assert_output --partial "transient"
  refute_output --partial "refused"
  refute_output --partial "$FAKE_TOKEN"
}

@test "transient: HTTP 502 — exit 3" {
  export FAKE_GH_STATUS=502 FAKE_GH_SCOPES="repo"
  run "$CHECK"
  [ "$status" -eq 3 ]
}

@test "transient: HTTP 403 rate limit — exit 3" {
  export FAKE_GH_STATUS=403
  run "$CHECK"
  [ "$status" -eq 3 ]
}

@test "GitHub rejects the token (401) — exit 2, no token to check" {
  export FAKE_GH_STATUS=401
  run "$CHECK"
  [ "$status" -eq 2 ]
  assert_output --partial "rejected"
  refute_output --partial "$FAKE_TOKEN"
}

@test "secret-store entry missing — exit 2" {
  export FAKE_TOKEN_MISSING=1
  run "$CHECK"
  [ "$status" -eq 2 ]
  assert_output --partial "sandbox-env failed"
  [ ! -s "$GH_CALLS" ]
}
