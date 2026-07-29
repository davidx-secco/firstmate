#!/usr/bin/env bash
# fm-install-gh-shim.sh - install, inspect, or remove the repository-keyed gh
# wrapper (bin/fm-gh-shim.sh), which owns what the wrapper does.
#
# The wrapper has to be entered by processes this repo does not launch - above
# all no-mistakes' shared daemon, whose environment is fixed when it starts - so
# it is installed as a "gh" in a directory that precedes the real gh on their
# PATH. That shadows gh for everything on the machine, including manual use,
# which is why the wrapper is a pass-through for every command it does not need
# and why removing it is a single command.
#
# Usage:
#   fm-install-gh-shim.sh [--target <dir>]     install or refresh the wrapper
#   fm-install-gh-shim.sh --check [--target <dir>]
#                                              report what is installed, which gh
#                                              is the real one, and whether a gh
#                                              call made with this PATH enters
#                                              the wrapper ("in effect: yes")
#   fm-install-gh-shim.sh --uninstall [--target <dir>]
#                                              remove a wrapper this repo wrote
#   fm-install-gh-shim.sh --help
#
# --target defaults to ~/.local/bin. Installing writes a self-contained copy
# rather than a link, so losing this repo degrades to the wrapper's own
# unreachable-helper handling instead of breaking gh outright; re-run this script
# after changing bin/fm-gh-shim.sh to refresh that copy.
#
# Because that copy records the absolute path of the account helper it calls, and
# because it then answers for every gh call on the machine, installing is refused
# from a linked task worktree: that path disappears with the worktree's cleanup,
# and every repository call would start refusing afterwards. Install from a real
# checkout, which for firstmate means the primary home.
#
# FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 accepts that risk deliberately, for this
# repo's own tests and for the window in which the change is still landing and
# only the task copy holds the helper. It prints what it recorded and what has to
# happen next, because whoever sets it owns re-running the install from a durable
# checkout before that copy goes away.
#
# It refuses to replace a gh this repo did not write, and --uninstall removes
# only a file carrying the wrapper's marker, so a real gh installed in the target
# directory is never touched. A target that does not precede the real gh on this
# shell's PATH is reported, not refused: the PATH that matters belongs to the
# processes being corrected, not to this one.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/fm-gh-shim.sh"
HELPER="$SCRIPT_DIR/fm-gh-account.sh"
MARKER='# fm-gh-shim: installed by bin/fm-install-gh-shim.sh'
TARGET_DIR="$HOME/.local/bin"
MODE=install

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

warn() {
  printf 'fm-install-gh-shim: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --target) [ "$#" -ge 2 ] || { warn "--target needs a directory"; exit 2; }; TARGET_DIR=$2; shift 2 ;;
    --uninstall) MODE=uninstall; shift ;;
    --check) MODE=check; shift ;;
    *) warn "unexpected argument '$1'; see --help"; exit 2 ;;
  esac
done

TARGET="$TARGET_DIR/gh"

is_our_shim() {  # <path>
  [ -f "$1" ] && grep -qxF "$MARKER" "$1" 2>/dev/null
}

# The real gh: the first one on PATH that is not the installed wrapper.
real_gh() {
  local dir candidate resolved target_resolved
  target_resolved=$(cd "$TARGET_DIR" 2>/dev/null && pwd -P)/gh || target_resolved=$TARGET
  local IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || dir=.
    candidate="$dir/gh"
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    resolved=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/gh || continue
    [ "$resolved" = "$target_resolved" ] && continue
    printf '%s\n' "$resolved"
    return 0
  done
  return 1
}

case "$MODE" in
  check)
    if is_our_shim "$TARGET"; then
      printf 'installed: %s\n' "$TARGET"
    elif [ -e "$TARGET" ]; then
      printf 'not installed: %s exists and was not written by this repo\n' "$TARGET"
    else
      printf 'not installed: %s\n' "$TARGET"
    fi
    if real=$(real_gh); then
      printf 'real gh: %s\n' "$real"
    else
      printf 'real gh: not found on this PATH\n'
    fi
    # Whether a gh call made with this PATH enters the wrapper at all, which is
    # the only thing that decides whether the wrapper is correcting anything.
    # A file at --target that nothing resolves to corrects nothing, and a wrapper
    # installed elsewhere corrects everything if PATH reaches it first.
    path_gh=$(command -v gh 2>/dev/null) || path_gh=
    if [ -n "$path_gh" ] && is_our_shim "$path_gh"; then
      printf 'in effect: yes, gh resolves to %s\n' "$path_gh"
    elif [ -n "$path_gh" ]; then
      printf 'in effect: no, gh resolves to %s\n' "$path_gh"
    else
      printf 'in effect: no, no gh on this PATH\n'
    fi
    exit 0
    ;;
  uninstall)
    if [ ! -e "$TARGET" ]; then
      printf 'nothing to remove at %s\n' "$TARGET"
      exit 0
    fi
    if ! is_our_shim "$TARGET"; then
      warn "$TARGET was not written by this repo; leaving it alone"
      exit 1
    fi
    rm -f -- "$TARGET" || { warn "could not remove $TARGET"; exit 1; }
    printf 'removed %s; plain gh is in effect again\n' "$TARGET"
    exit 0
    ;;
esac

[ -f "$SOURCE" ] || { warn "missing $SOURCE"; exit 1; }
[ -x "$HELPER" ] || { warn "missing $HELPER, which the wrapper needs to choose an account"; exit 1; }

# The installed copy records $HELPER's path and then answers for every gh call on
# the machine, so that path has to outlive this command.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ROOT_IS_DURABLE=1
if ! fm_primary_scope_matches "$FM_ROOT" "$STATE"; then
  ROOT_IS_DURABLE=0
  if [ "${FM_GH_SHIM_ALLOW_LINKED_WORKTREE:-0}" != 1 ]; then
    warn "$FM_ROOT is not a durable checkout, so the account helper it holds would disappear and every repository call would start refusing; install from the primary home instead"
    exit 1
  fi
fi

if [ -e "$TARGET" ] && ! is_our_shim "$TARGET"; then
  warn "$TARGET already exists and was not written by this repo; move it aside or choose another --target"
  exit 1
fi

REAL=$(real_gh) || { warn "no gh found on PATH, so there is nothing to wrap"; exit 1; }

mkdir -p "$TARGET_DIR" || { warn "could not create $TARGET_DIR"; exit 1; }

TMP=$(mktemp "$TARGET_DIR/.fm-gh-shim.XXXXXX") || { warn "could not write in $TARGET_DIR"; exit 1; }
trap 'rm -f -- "$TMP"' EXIT
sed "s#__FM_GH_ACCOUNT_BIN__#$HELPER#" "$SOURCE" > "$TMP" || { warn "could not compose the wrapper"; exit 1; }
grep -qxF "$MARKER" "$TMP" || { warn "composed wrapper lost its marker; refusing to install"; exit 1; }
grep -q '__FM_GH_ACCOUNT_BIN__' "$TMP" && { warn "composed wrapper still holds an unsubstituted path; refusing to install"; exit 1; }
chmod 0755 "$TMP" || { warn "could not set permissions"; exit 1; }
mv -f -- "$TMP" "$TARGET" || { warn "could not install $TARGET"; exit 1; }
trap - EXIT

printf 'installed %s\n' "$TARGET"
printf 'wrapping %s, choosing the account with %s\n' "$REAL" "$HELPER"
if [ "$ROOT_IS_DURABLE" = 0 ]; then
  printf 'WARNING: %s is not a durable checkout. Re-run this install from the primary home before that path goes away, or every repository gh call will start refusing until it is removed.\n' \
    "$FM_ROOT" >&2
fi

# Advisory only: the PATH that decides whether the wrapper is entered belongs to
# the processes being corrected (no-mistakes' daemon, worker shells), not to this
# one.
TARGET_REAL=$(cd "$TARGET_DIR" && pwd -P)
REAL_DIR=$(dirname "$REAL")
FOUND_TARGET=0
IFS=: read -r -a PATH_DIRS <<< "$PATH"
for dir in "${PATH_DIRS[@]+"${PATH_DIRS[@]}"}"; do
  [ -n "$dir" ] || dir=.
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) || continue
  if [ "$resolved" = "$TARGET_REAL" ]; then
    FOUND_TARGET=1
    break
  fi
  if [ "$resolved" = "$REAL_DIR" ]; then
    break
  fi
done
[ "$FOUND_TARGET" = 1 ] || printf 'note: %s does not precede %s on this shell PATH, so this shell keeps using the real gh\n' \
  "$TARGET_DIR" "$REAL_DIR"
printf 'remove it with: %s --uninstall\n' "$SCRIPT_DIR/fm-install-gh-shim.sh"
