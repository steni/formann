#!/usr/bin/env bash
# Runner's Formann updater — brings the runner's own Formann checkout to the
# configured ref before a drain (GLOSSARY: Runner's Formann).
#
# The runner keeps a Formann checkout of its own at $RUNNER_FORMANN_DIR, a git
# clone, separate from the checkout the consumer's interactive sessions read
# through `.formann`. At the start of every drain it is fast-forwarded to
# $RUNNER_FORMANN_REF (`<remote>/<branch>`, default `origin/main`), so every
# machine runs the same version without anyone pulling on each one.
#
# Interface:
#   formann_self_update [<ref>]  → the checkout's sha on stdout, exit 0
#                                | refusal: `formann-update: <reason>` on
#                                  stderr, exit 1, the checkout untouched
#   formann_checkout_sha <dir>   → <dir>'s HEAD sha, or `unknown`
#
# It only ever fast-forwards. It refuses, naming the cause, when the checkout
# is missing, is not a git clone (an rsync copy), has local changes (modified,
# staged or untracked files), has commits the ref lacks (diverged or ahead),
# or the ref cannot be fetched. A refusal stops the drain before any claim is
# taken; the maintainer reconciles the checkout by hand.
#
# Every git call runs in $RUNNER_FORMANN_DIR. Nothing here reads or writes
# the sessions' `.formann` checkout.

# The configured ref ($RUNNER_FORMANN_REF, default `origin/main`).
formann_update_ref() {
  printf '%s\n' "${RUNNER_FORMANN_REF:-origin/main}"
}

formann_update_refuse() {
  echo "formann-update: $*" >&2
  return 1
}

# The HEAD sha of the checkout at $1, or `unknown`.
formann_checkout_sha() {
  git -C "$1" rev-parse --verify --quiet HEAD 2>/dev/null || echo unknown
}

formann_self_update() {
  local ref="${1:-$(formann_update_ref)}"
  local dir="${RUNNER_FORMANN_DIR:-}"

  if [ -z "$dir" ]; then
    formann_update_refuse "RUNNER_FORMANN_DIR is not set"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    formann_update_refuse "the runner's Formann checkout $dir does not exist (clone the Formann remote there)"
    return 1
  fi

  # A clone, at its top level. An rsync copy of a checkout has no `.git`; one
  # copied inside some other repository would resolve to that repository.
  local top want
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  want="$(cd "$dir" && pwd -P)"
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$want" ]; then
    formann_update_refuse "$dir is not a git clone (an rsync copy? replace it with a clone of the Formann remote)"
    return 1
  fi

  if [[ ! "$ref" =~ ^([^/]+)/(.+)$ ]]; then
    formann_update_refuse "ref '$ref' is not of the form <remote>/<branch>"
    return 1
  fi
  local remote="${BASH_REMATCH[1]}" branch="${BASH_REMATCH[2]}"
  if ! git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
    formann_update_refuse "$dir has no remote '$remote' (ref $ref)"
    return 1
  fi

  local changes
  changes="$(git -C "$dir" status --porcelain --untracked-files=normal 2>/dev/null)"
  if [ -n "$changes" ]; then
    formann_update_refuse "$dir has local changes: $(printf '%s\n' "$changes" | head -n 5 | sed 's/^...//' | paste -sd ',' - | sed 's/,/, /g')"
    return 1
  fi

  local err
  if ! err="$(git -C "$dir" fetch --quiet --no-tags "$remote" \
      "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>&1)"; then
    formann_update_refuse "fetch of $ref failed: $(printf '%s\n' "$err" | tail -n 1)"
    return 1
  fi

  local target head
  target="$(git -C "$dir" rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}")" || {
    formann_update_refuse "fetch of $ref brought no commit"
    return 1
  }
  head="$(git -C "$dir" rev-parse --verify --quiet HEAD || true)"

  if [ "$head" != "$target" ]; then
    if [ -n "$head" ] && ! git -C "$dir" merge-base --is-ancestor "$head" "$target"; then
      local ahead behind
      ahead="$(git -C "$dir" rev-list --count "$target..$head")"
      behind="$(git -C "$dir" rev-list --count "$head..$target")"
      formann_update_refuse "$dir has diverged from $ref: $ahead local commit(s) not on $ref, $behind on $ref not checked out"
      return 1
    fi
    if ! err="$(git -C "$dir" merge --ff-only --quiet "$target" 2>&1)"; then
      formann_update_refuse "fast-forward of $dir to $ref failed: $(printf '%s\n' "$err" | tail -n 1)"
      return 1
    fi
  fi

  git -C "$dir" rev-parse HEAD
}
