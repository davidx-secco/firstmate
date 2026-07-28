#!/usr/bin/env bash
# fm-gh-shim: installed by bin/fm-install-gh-shim.sh
#
# A gh that acts as the account the repository belongs to.
#
# It exists for the one place a per-lane credential cannot reach: no-mistakes
# runs its own forge steps from a shared daemon whose environment is fixed when
# it starts, so those calls used whichever account was globally active and failed
# on repositories that account could not see. Installed as a "gh" earlier on PATH
# than the real one, this program is entered by those calls at exec time, needing
# no daemon restart and mutating no gh state.
#
# It is deliberately almost always a pass-through. It hands work to
# bin/fm-gh-account.sh only for a command that acts on a repository it can
# identify, and that helper still refuses rather than guessing when the account
# for that repository cannot be determined.
#
# Passed through to the real gh completely untouched:
#   - any call that already carries GH_TOKEN or GITHUB_TOKEN, so an explicit
#     credential always wins and fm-gh-account's own probes cannot re-enter here
#   - auth, config, alias, completion, extension, version, help, status,
#     codespace, gist, ssh-key, and gpg-key, whose subject is the account or the
#     local install rather than a repository - manual "gh auth" work in
#     particular must keep behaving exactly as it always did
#   - any invocation asking for help or a version, and a bare "gh"
#   - a host other than github.com, from --hostname or GH_HOST
#   - a --repo naming a bare repository name, which only gh's own active account
#     can expand
#   - anything at all when no account selection applies: not a github.com
#     checkout, one account logged in, nobody logged in (fm-gh-account.sh's
#     "nothing to select" exit)
#
# Refused loudly, never run as an unintended account:
#   - a repository whose account cannot be determined
#   - an unreachable bin/fm-gh-account.sh while more than one account is logged
#     in, which is the only case where passing through could silently pick the
#     wrong identity; with one account or none there is nothing to get wrong, so
#     the call passes through
#
# Environment: FM_GH_REAL pins the real gh, FM_GH_ACCOUNT_BIN pins the helper.
# Both exist for tests and for recovery after a move.
# Remove the installed copy, or run bin/fm-install-gh-shim.sh --uninstall, to
# restore plain gh everywhere.
set -u

# The installer replaces this one placeholder with an absolute path. It must stay
# the only occurrence in this file: a second one would be rewritten too, and a
# pattern that matches its own substituted value would defeat the check below.
INSTALLED_HELPER='__FM_GH_ACCOUNT_BIN__'
FM_GH_ACCOUNT_BIN=${FM_GH_ACCOUNT_BIN:-}
if [ -z "$FM_GH_ACCOUNT_BIN" ]; then
  case "$INSTALLED_HELPER" in
    /*/fm-gh-account.sh) FM_GH_ACCOUNT_BIN=$INSTALLED_HELPER ;;
    # Unsubstituted: this is the tracked copy running from bin/ directly.
    *) FM_GH_ACCOUNT_BIN="$(cd "$(dirname "$0")" && pwd)/fm-gh-account.sh" ;;
  esac
fi

self_path() {
  local dir base
  dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || return 1
  base=$(basename "$0")
  printf '%s/%s\n' "$dir" "$base"
}

# The first gh on PATH that is not this program. Resolved physically so a
# symlinked or relatively-invoked copy still recognizes itself.
find_real_gh() {
  local self dir candidate resolved
  self=$(self_path || true)
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    candidate="$dir/gh"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    resolved=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/gh || continue
    [ "$resolved" = "$self" ] && continue
    printf '%s\n' "$resolved"
    return 0
  done
  return 1
}

REAL=${FM_GH_REAL:-}
if [ -z "$REAL" ]; then
  REAL=$(find_real_gh) || {
    printf 'fm-gh-shim: no gh found on PATH besides this wrapper (%s); remove it to restore plain gh\n' \
      "$(self_path || printf '%s' "$0")" >&2
    exit 127
  }
fi

# An explicit credential in the environment always wins.
if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
  exec "$REAL" "$@"
fi

case "${1:-}" in
  ''|auth|config|alias|completion|extension|version|help|status|codespace|cs|gist|ssh-key|gpg-key)
    exec "$REAL" "$@"
    ;;
esac

# Help and version output must be byte-identical to gh's own.
for arg in "$@"; do
  case "$arg" in
    -h|--help|-v|-V|--version) exec "$REAL" "$@" ;;
  esac
done

REPO_ARG=
HOST_ARG=${GH_HOST:-github.com}
PREV=
for arg in "$@"; do
  case "$PREV" in
    -R|--repo) REPO_ARG=$arg ;;
    --hostname) HOST_ARG=$arg ;;
  esac
  case "$arg" in
    --repo=*) REPO_ARG=${arg#--repo=} ;;
    -R=*) REPO_ARG=${arg#-R=} ;;
    --hostname=*) HOST_ARG=${arg#--hostname=} ;;
  esac
  PREV=$arg
done

# A host other than github.com is outside this selection entirely.
case "$HOST_ARG" in
  github.com) ;;
  *) exec "$REAL" "$@" ;;
esac

# An explicit repository wins over the working directory, because a command that
# names one is not asking about wherever it happens to run.
SELECTOR=(--dir .)
if [ -n "$REPO_ARG" ]; then
  spec=$REPO_ARG
  case "$spec" in
    *://*) spec=${spec#*://}; spec=${spec#*/} ;;
    github.com/*) spec=${spec#github.com/} ;;
  esac
  spec=${spec%/}
  spec=${spec%.git}
  case "$spec" in
    */*/*|*/) exec "$REAL" "$@" ;;
    */*) SELECTOR=(--repo "$spec") ;;
    # A bare name is expanded by gh against its own active account; there is
    # nothing here to key an account off.
    *) exec "$REAL" "$@" ;;
  esac
fi

if [ ! -x "$FM_GH_ACCOUNT_BIN" ]; then
  if [ "$("$REAL" auth status 2>&1 | grep -c 'Logged in to github\.com account')" -gt 1 ]; then
    printf 'fm-gh-shim: %s is unreachable and more than one GitHub account is logged in, so this call could run as the wrong one; restore that path, or remove this wrapper (%s) to go back to plain gh\n' \
      "$FM_GH_ACCOUNT_BIN" "$(self_path || printf '%s' "$0")" >&2
    exit 1
  fi
  exec "$REAL" "$@"
fi

SELECT_RC=0
ACCOUNT=$("$FM_GH_ACCOUNT_BIN" resolve "${SELECTOR[@]}") || SELECT_RC=$?
case "$SELECT_RC" in
  0) exec "$FM_GH_ACCOUNT_BIN" exec --account "$ACCOUNT" -- "$REAL" "$@" ;;
  3) exec "$REAL" "$@" ;;
  *)
    printf 'fm-gh-shim: not running gh as an unintended account for this repository (reason above); remove this wrapper (%s) to go back to plain gh\n' \
      "$(self_path || printf '%s' "$0")" >&2
    exit 1
    ;;
esac
