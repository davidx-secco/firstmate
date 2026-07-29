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
#   - any invocation asking for help or a version, and a bare "gh"; a -h, -v, -V,
#     --help, or --version standing where another flag's value goes, or after a
#     "--", is a value rather than such a request
#   - a host other than github.com, from --hostname or GH_HOST
#   - a --repo naming a bare repository name, which only gh's own active account
#     can expand
#
# Keyed off the repository the call names rather than the directory it runs in:
#   - --repo/-R in all of gh's own forms, including "-Rowner/repo"
#   - an "api" endpoint whose path is repos/{owner}/{repo}/..., with or without a
#     leading slash or an https://api.github.com prefix; every other endpoint,
#     including one holding gh's own {owner}/{repo} placeholders, stays keyed off
#     the working directory
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

# Help and version output must be byte-identical to gh's own. Only a flag that is
# not standing where another flag's value goes counts as such a request, and
# nothing after "--" does: "gh pr comment --body -v" asks for no help, and
# passing it through unkeyed would run it as whichever account is active.
# Anything this misreads as repository work is still keyed rather than guessed,
# and gh's own help output does not depend on which account it runs as.
PREV=
for arg in "$@"; do
  [ "$arg" = -- ] && break
  case "$PREV" in
    # A value attached with "=" leaves the next argument free to be a flag.
    -*=*) ;;
    # Otherwise this argument may be the previous flag's value.
    -?*) PREV=$arg; continue ;;
  esac
  case "$arg" in
    -h|--help|-v|-V|--version) exec "$REAL" "$@" ;;
  esac
  PREV=$arg
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
    # pflag accepts a shorthand's value attached to it, so "-Rowner/repo" names a
    # repository exactly as "-R owner/repo" does.
    -R?*) REPO_ARG=${arg#-R} ;;
    --hostname=*) HOST_ARG=${arg#--hostname=} ;;
  esac
  PREV=$arg
done

# "gh api" carries its repository in the endpoint path instead of --repo, so a
# "repos/{owner}/{repo}/..." endpoint names the repository just as explicitly.
# gh's own "{owner}" and "{repo}" placeholders are expanded from the working
# directory, so a path holding them is left keyed off that directory, as is every
# endpoint that names no repository at all.
api_repo_from_endpoint() {  # <endpoint>
  local path=$1 owner repo rest
  case "$path" in
    https://api.github.com/*) path=${path#https://api.github.com/} ;;
    http://api.github.com/*) path=${path#http://api.github.com/} ;;
    *://*) return 1 ;;
  esac
  path=${path#/}
  case "$path" in
    repos/*) path=${path#repos/} ;;
    *) return 1 ;;
  esac
  case "$path" in
    */*) owner=${path%%/*}; rest=${path#*/} ;;
    *) return 1 ;;
  esac
  repo=${rest%%/*}
  [ -n "$owner" ] && [ -n "$repo" ] || return 1
  case "$owner$repo" in
    *'{'*|*'}'*) return 1 ;;
  esac
  printf '%s/%s\n' "$owner" "$repo"
}

if [ -z "$REPO_ARG" ] && [ "${1:-}" = api ]; then
  for arg in "$@"; do
    case "$arg" in
      -*) continue ;;
    esac
    if api_spec=$(api_repo_from_endpoint "$arg"); then
      REPO_ARG=$api_spec
      break
    fi
  done
fi

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
