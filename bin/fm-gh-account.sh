#!/usr/bin/env bash
# fm-gh-account.sh - choose the GitHub account for the repository being operated
# on, and hand that account's credential to exactly one child process.
#
# A home with two logged-in accounts has no way to guess which one a given
# repository needs: worker copies and firstmate homes live outside any
# per-directory shell hook, so whichever account happens to be globally active
# is inherited, and a repository that account cannot see fails late with
# "Could not resolve to a Repository". This script keys the account off the
# repository's own origin owner instead, and passes the chosen account's token
# to one child through GH_TOKEN. It never runs "gh auth switch": global gh state
# is untouched, so concurrent workers on different accounts cannot disturb each
# other.
#
# Usage:
#   fm-gh-account.sh resolve [<selector>]     print the chosen account login
#   fm-gh-account.sh token   [<selector>]     print that account's token
#   fm-gh-account.sh env     [<selector>]     print a shell snippet to eval
#   fm-gh-account.sh exec    [<selector>] -- <command> [args...]
#                                             run <command> with GH_TOKEN set
#   fm-gh-account.sh --help
#
# Selectors, default --dir .:
#   --dir <path>         read the owner from that checkout's origin remote
#   --repo <owner/name>  name the repository explicitly
#   --account <login>    skip resolution and use this logged-in account
#
# Resolution order for --dir and --repo, first match wins:
#   1. FM_GH_ACCOUNT=<login>, the per-run override; FM_GH_ACCOUNT=none selects
#      nothing (exit 3).
#   2. config/gh-accounts, "<owner> <account>" lines.
#   3. origin owner equal to a logged-in account login, needing no network.
#   4. the visibility probe: the account whose own token can read the
#      repository, breaking a tie on the strongest recorded permission.
#
# Exit status:
#   0  an account was chosen
#   1  the account could not be determined, or its token could not be obtained;
#      the reason and its fix go to stderr, no command runs, and no caller may
#      fall back to the active account
#   2  usage error
#   3  no selection applies, so gh keeps whatever the caller already had: gh is
#      absent, no account is logged in, exactly one account is logged in,
#      FM_GH_ACCOUNT=none, or origin is not a github.com repository
#
# "token" and "env" refuse to write to a terminal, so a credential reaches only
# a command substitution and never a pane's scrollback. "env" is also the one
# mode that reports failure on stdout: it emits a snippet unconditionally, and
# on failure that snippet sets GH_TOKEN to an unusable placeholder so the shell
# cannot silently keep operating as another identity. Evaluate its output only
# on exit 0 or 1; on exit 3 there is nothing to evaluate.
#
# Consumers: bin/fm-spawn.sh resolves the account before launch and exports it
# into the worker's shell, so every gh, gh-axi, and pipeline call in that lane
# inherits the right identity; bin/fm-pr-check.sh, bin/fm-pr-merge.sh, and
# bin/fm-teardown.sh wrap their own forge reads and the merge itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ACCOUNT_MAP="$CONFIG/gh-accounts"

# Placeholder GH_TOKEN for a failed "env": gh rejects it loudly instead of
# reaching for the active account's credential.
UNUSABLE_TOKEN=fm-gh-account-unresolved

# Seconds allowed per network probe, when a timeout command is available.
PROBE_TIMEOUT=${FM_GH_ACCOUNT_TIMEOUT:-10}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

warn() {
  printf 'fm-gh-account: %s\n' "$*" >&2
}

# --- gh plumbing ------------------------------------------------------------

# Read gh's own account records with any injected token scrubbed, so an
# already-exported GH_TOKEN cannot change which accounts gh reports.
gh_clean() {
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

# Run gh as one specific account, bounded when a timeout command exists.
gh_as() {  # <token> <gh-arg>...
  local token=$1
  shift
  local -a limit=()
  if command -v timeout >/dev/null 2>&1; then
    limit=(timeout "$PROBE_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then
    limit=(gtimeout "$PROBE_TIMEOUT")
  fi
  env -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
    GH_TOKEN="$token" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
    "${limit[@]+"${limit[@]}"}" gh "$@"
}

ACCOUNTS=
ACCOUNTS_LOADED=0

# Every login gh reports for github.com, newline separated. Other hosts are out
# of scope: this selection exists for github.com repositories only.
# Call this from the shell that then reads $ACCOUNTS: the memo cannot cross a
# command substitution, so a caller that only ever loads inside $(...) sees an
# empty list.
load_accounts() {
  [ "$ACCOUNTS_LOADED" = 1 ] && return 0
  ACCOUNTS_LOADED=1
  ACCOUNTS=$(gh_clean auth status 2>&1 \
    | sed -n 's/.*Logged in to github\.com account \([A-Za-z0-9][A-Za-z0-9-]*\).*/\1/p')
}

account_count() {
  load_accounts
  [ -n "$ACCOUNTS" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$ACCOUNTS" | wc -l | tr -d ' '
}

account_list() {
  load_accounts
  printf '%s\n' "$ACCOUNTS" | paste -sd, - | sed 's/,/, /g'
}

account_known() {  # <login>
  local want=$1 line
  load_accounts
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done <<EOF
$ACCOUNTS
EOF
  return 1
}

# The account's own oauth token. Rejects anything that is not a bare credential,
# so a token can never carry shell syntax into an eval'd snippet.
account_token() {  # <login>
  local login=$1 token
  token=$(gh_clean auth token --user "$login" 2>/dev/null) || return 1
  [ -n "$token" ] || return 1
  case "$token" in
    *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  printf '%s\n' "$token"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- repository identity ----------------------------------------------------

# "owner/repo" for a checkout whose origin is a github.com repository; non-zero
# for every other remote, including GitLab and an absent origin.
origin_repo() {  # <dir>
  local dir=$1 url rest host path owner repo
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  rest=$url
  case "$rest" in
    *://*) rest=${rest#*://} ;;
  esac
  rest=${rest#*@}
  case "$rest" in
    *:*/*) host=${rest%%:*}; path=${rest#*:} ;;
    */*) host=${rest%%/*}; path=${rest#*/} ;;
    *) return 1 ;;
  esac
  # An ssh URL may carry a port between host and path; a whole-numeric first
  # segment is that port, never an owner.
  case "$path" in
    */*)
      case "${path%%/*}" in
        '' ) ;;
        *[!0-9]*) ;;
        *) path=${path#*/} ;;
      esac
      ;;
  esac
  [ "$(lower "$host")" = github.com ] || return 1
  path=${path%/}
  path=${path%.git}
  owner=${path%%/*}
  repo=${path#*/}
  [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$path" ] || return 1
  case "$repo" in
    */*) return 1 ;;
  esac
  validate_repo "$owner/$repo" || return 1
  printf '%s/%s\n' "$owner" "$repo"
}

validate_repo() {  # <owner/repo>
  local spec=$1 owner repo
  owner=${spec%%/*}
  repo=${spec#*/}
  [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$spec" ] || return 1
  case "$owner" in
    *[!A-Za-z0-9-]*|-*|*-) return 1 ;;
  esac
  case "$repo" in
    .|..|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#owner}" -le 39 ] && [ "${#repo}" -le 100 ]
}

# --- resolution -------------------------------------------------------------

# The account config/gh-accounts records for an owner, if any.
mapped_account() {  # <owner>
  local owner=$1 line key value
  [ -f "$ACCOUNT_MAP" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//=/ }
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    key=${line%%[[:space:]]*}
    value=${line##*[[:space:]]}
    [ -n "$key" ] && [ -n "$value" ] && [ "$key" != "$value" ] || continue
    if [ "$(lower "$key")" = "$(lower "$owner")" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done < "$ACCOUNT_MAP"
  return 1
}

# The strength of an account's access to a repository, or non-zero when the
# account cannot see it at all. Ranking comes from the API's own permission
# record so a read-only collaborator never outranks the owner.
probe_rank() {  # <login> <owner/repo>
  local login=$1 spec=$2 token rank
  token=$(account_token "$login") || return 1
  rank=$(gh_as "$token" api "repos/$spec" --jq '
    if .permissions.admin then 50
    elif .permissions.maintain then 40
    elif .permissions.push then 30
    elif .permissions.triage then 20
    elif .permissions.pull then 10
    else 5 end' 2>/dev/null) || return 1
  case "$rank" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$rank"
}

# Print the chosen login. 0 chosen, 1 undeterminable, 3 nothing to select.
resolve_account() {  # <owner/repo or empty>
  local spec=$1 owner=${1%%/*} mapped candidate rank
  local best='' best_rank=0 tied=''

  command -v gh >/dev/null 2>&1 || return 3
  load_accounts
  [ -n "$ACCOUNTS" ] || return 3

  if [ -n "${FM_GH_ACCOUNT:-}" ]; then
    [ "$FM_GH_ACCOUNT" = none ] && return 3
    if account_known "$FM_GH_ACCOUNT"; then
      printf '%s\n' "$FM_GH_ACCOUNT"
      return 0
    fi
    warn "FM_GH_ACCOUNT=$FM_GH_ACCOUNT is not logged in to github.com (logged in: $(account_list)); log it in with 'gh auth login' or name one of those accounts"
    return 1
  fi

  [ -n "$spec" ] || return 3
  # One account is not a choice, so the whole selection stays out of the way and
  # gh behaves exactly as it did before this script existed.
  [ "$(account_count)" -gt 1 ] || return 3

  if mapped=$(mapped_account "$owner"); then
    if account_known "$mapped"; then
      printf '%s\n' "$mapped"
      return 0
    fi
    warn "$ACCOUNT_MAP maps $owner to $mapped, which is not logged in to github.com (logged in: $(account_list)); correct that line or log that account in"
    return 1
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "$(lower "$candidate")" = "$(lower "$owner")" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$ACCOUNTS
EOF

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    rank=$(probe_rank "$candidate" "$spec") || continue
    if [ "$rank" -gt "$best_rank" ]; then
      best=$candidate
      best_rank=$rank
      tied=
    elif [ "$rank" -eq "$best_rank" ]; then
      tied="${tied:+$tied, }$candidate"
    fi
  done <<EOF
$ACCOUNTS
EOF

  if [ -z "$best" ]; then
    warn "no logged-in GitHub account can read $spec (tried: $(account_list)); grant one of them access, or record the right account in $ACCOUNT_MAP as '$owner <account>'"
    return 1
  fi
  if [ -n "$tied" ]; then
    warn "$best and $tied have equal access to $spec, so the account for it is ambiguous; record the right one in $ACCOUNT_MAP as '$owner <account>', or set FM_GH_ACCOUNT for this run"
    return 1
  fi
  printf '%s\n' "$best"
  return 0
}

# --- command line -----------------------------------------------------------

MODE=${1:-}
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  resolve|token|env|exec) shift ;;
  '') warn "no mode given; see --help"; exit 2 ;;
  *) warn "unknown mode '$MODE'; see --help"; exit 2 ;;
esac

DIR=
REPO=
ACCOUNT=
CMD=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) [ "$#" -ge 2 ] || { warn "--dir needs a path"; exit 2; }; DIR=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || { warn "--repo needs owner/name"; exit 2; }; REPO=$2; shift 2 ;;
    --account) [ "$#" -ge 2 ] || { warn "--account needs a login"; exit 2; }; ACCOUNT=$2; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    *) warn "unexpected argument '$1'; see --help"; exit 2 ;;
  esac
done

[ -n "$DIR" ] && [ -n "$REPO" ] && { warn "--dir and --repo are mutually exclusive"; exit 2; }
if [ -n "$ACCOUNT" ] && { [ -n "$DIR" ] || [ -n "$REPO" ]; }; then
  warn "--account already names the account, so --dir/--repo cannot also apply"
  exit 2
fi
if [ "$MODE" = exec ] && [ "${#CMD[@]}" -eq 0 ]; then
  warn "exec needs '-- <command>'"
  exit 2
fi
if [ "$MODE" != exec ] && [ "${#CMD[@]}" -gt 0 ]; then
  warn "'--' and a command apply to exec only"
  exit 2
fi
if [ -n "$REPO" ] && ! validate_repo "$REPO"; then
  warn "--repo '$REPO' is not a valid owner/name"
  exit 2
fi

SPEC=
STATUS=0
if [ -n "$ACCOUNT" ]; then
  if account_known "$ACCOUNT"; then
    LOGIN=$ACCOUNT
  else
    warn "$ACCOUNT is not logged in to github.com (logged in: $(account_list)); log it in with 'gh auth login'"
    LOGIN=
    STATUS=1
  fi
else
  if [ -n "$REPO" ]; then
    SPEC=$REPO
  else
    SPEC=$(origin_repo "${DIR:-.}" || true)
  fi
  LOGIN=$(resolve_account "$SPEC") || STATUS=$?
fi

refuse_terminal() {
  [ -t 1 ] || return 0
  warn "$MODE writes a credential, so it refuses a terminal; use it inside \$(...) or use exec"
  exit 2
}

case "$MODE" in
  resolve)
    [ "$STATUS" = 0 ] || exit "$STATUS"
    printf '%s\n' "$LOGIN"
    ;;
  token)
    refuse_terminal
    [ "$STATUS" = 0 ] || exit "$STATUS"
    if ! TOKEN=$(account_token "$LOGIN"); then
      warn "no usable github.com token for $LOGIN; re-authenticate it with 'gh auth login'"
      exit 1
    fi
    printf '%s\n' "$TOKEN"
    ;;
  env)
    refuse_terminal
    [ "$STATUS" != 3 ] || exit 3
    if [ "$STATUS" = 0 ] && TOKEN=$(account_token "$LOGIN"); then
      printf "export GH_TOKEN='%s'\n" "$TOKEN"
      exit 0
    fi
    [ "$STATUS" = 0 ] && warn "no usable github.com token for $LOGIN; re-authenticate it with 'gh auth login'"
    # Fail closed inside the evaluating shell too: an unusable token is refused
    # by GitHub, where silence would have let the wrong account through.
    printf "export GH_TOKEN='%s'\n" "$UNUSABLE_TOKEN"
    printf "printf '%%s\\\\n' 'firstmate: no GitHub account selected for this repository; GitHub API calls are refused until %s is fixed' >&2\n" "$ACCOUNT_MAP"
    exit 1
    ;;
  exec)
    case "$STATUS" in
      3) exec "${CMD[@]}" ;;
      0) ;;
      *) exit "$STATUS" ;;
    esac
    if ! TOKEN=$(account_token "$LOGIN"); then
      warn "no usable github.com token for $LOGIN; re-authenticate it with 'gh auth login'"
      exit 1
    fi
    # Exported from this shell rather than passed through env's argument list,
    # which any process listing would show while env is still running.
    export GH_TOKEN="$TOKEN"
    unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    exec "${CMD[@]}"
    ;;
esac
