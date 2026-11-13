#!/usr/bin/env bash
# Judges checkout — the runner's own checkout of the consumer's default
# branch, which everything that judges a dispatch is read from (GLOSSARY:
# Judges checkout).
#
# The sandbox mounts the consumer's `.claude/skills`, `.claude/agents` and
# `.claude/rules` read-only, and the runner reads the consumer's post-implement
# and post-drain manifests and step prompts (`runner/`), from a checkout the
# slug branch can't change, so a branch never changes the reviewers that judge
# it. The host repo is where people and their sessions work, so the runner
# never updates it; it keeps a clone of its own at $HOST_JUDGES
# (`.runner-state/judges`), detached at `<shared-remote>/<default-branch>` and
# set exactly to it before every pass. Nobody edits it, so there is nothing to
# skip: local edits and stray files in it are discarded.
#
# Interface:
#   judges_refresh → `<dir><TAB><source>` on stdout, always exit 0; at most
#                    one `judges: <message>` line on stderr
#     <dir>    where the judges are read from: $HOST_JUDGES, or $HOST_REPO
#     <source> `<remote>/<branch>`; `<remote>/<branch>, not refreshed`
#              (kept at its last commit); `host repo` (fallback);
#              `host repo, no Shared remote '<remote>'`
#
# The remote is $RUNNER_SHARED_REMOTE (default `origin`); the default branch
# resolves as runner_default_branch (lib.sh) does in the host repo. The host
# repo's only change is the fetch into refs/remotes/<remote>/<branch>, as the
# runner's other Shared-remote reads do; its HEAD, branches and working tree
# are never touched.
#
# When the judges can't be refreshed (the fetch fails, the default branch
# doesn't resolve, the clone or checkout fails) the pass goes on, with a
# `not refreshed: <reason>` message: with the judges checkout at its last
# commit when there is one, else from the host repo. A host repo with no
# Shared remote (one machine) reads the judges from the host repo, silently,
# as it always has.

judges_say() {
  echo "judges: $*" >&2
}

# True when $HOST_JUDGES is a git checkout of its own, with a commit.
judges_checkout_present() {
  local top
  top="$(git -C "$HOST_JUDGES" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(cd "$top" && pwd -P)" = "$(cd "$HOST_JUDGES" && pwd -P)" ] || return 1
  git -C "$HOST_JUDGES" rev-parse --verify --quiet HEAD >/dev/null
}

# Not refreshed: keep the judges checkout at its last commit, or fall back to
# the host repo. Args: $1 the reason, $2 the `<remote>/<branch>` it follows.
judges_keep() {
  local reason="$1" follows="$2"
  if judges_checkout_present; then
    judges_say "not refreshed: $reason; keeping them at $(git -C "$HOST_JUDGES" rev-parse HEAD)"
    printf '%s\t%s\n' "$HOST_JUDGES" "${follows:+$follows, }not refreshed"
  else
    judges_say "not refreshed: $reason; they come from the host repo until the judges checkout exists"
    printf '%s\t%s\n' "$HOST_REPO" "host repo"
  fi
}

judges_refresh() {
  local remote="${RUNNER_SHARED_REMOTE:-origin}"
  if ! git -C "$HOST_REPO" remote get-url "$remote" >/dev/null 2>&1; then
    printf '%s\t%s\n' "$HOST_REPO" "host repo, no Shared remote '$remote'"
    return 0
  fi

  local branch
  if ! branch="$(runner_default_branch "$HOST_REPO")"; then
    judges_keep "cannot determine the default branch (set RUNNER_DEFAULT_BRANCH to its name)" ""
    return 0
  fi
  local follows="$remote/$branch" err

  if ! err="$(GIT_TERMINAL_PROMPT=0 git -C "$HOST_REPO" fetch --quiet --no-tags "$remote" \
      "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>&1)"; then
    judges_keep "fetch of $follows failed: $(printf '%s\n' "$err" | tail -n 1)" "$follows"
    return 0
  fi

  if ! judges_checkout_present; then
    rm -rf "$HOST_JUDGES"
    if ! err="$(git clone --quiet --no-checkout "$HOST_REPO" "$HOST_JUDGES" 2>&1)"; then
      rm -rf "$HOST_JUDGES"
      judges_keep "git clone into $HOST_JUDGES failed: $(printf '%s\n' "$err" | tail -n 1)" "$follows"
      return 0
    fi
  fi

  if ! err="$(git -C "$HOST_JUDGES" fetch --quiet --no-tags "$HOST_REPO" \
        "+refs/remotes/$remote/$branch:refs/remotes/judged/$branch" 2>&1 \
      && git -C "$HOST_JUDGES" checkout --quiet --detach --force "refs/remotes/judged/$branch" 2>&1 \
      && git -C "$HOST_JUDGES" clean -ffdxq 2>&1)"; then
    judges_keep "checkout of $follows in $HOST_JUDGES failed: $(printf '%s\n' "$err" | tail -n 1)" "$follows"
    return 0
  fi
  printf '%s\t%s\n' "$HOST_JUDGES" "$follows"
}
