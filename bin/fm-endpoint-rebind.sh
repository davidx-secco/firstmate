#!/usr/bin/env bash
# fm-endpoint-rebind.sh - the sanctioned repair for a Herdr task whose metadata
# predates fm-spawn.sh stamping endpoint_task_id=.
#
# THE PROBLEM. bin/fm-backend.sh refuses cleanup for an opaque non-tmux endpoint
# with no exact task binding, and that refusal is correct: Herdr panes live in a
# namespace shared by every firstmate home, and a pane id is a short reused
# counter, so closing an unproven address could hit another task or another
# home's live work. But a task that can never be retired holds its worktree slot
# and its pane forever and keeps waking supervision, so a repair has to exist.
#
# THE REPAIR. This script never trusts a hand-written field and never accepts a
# field written by its operator: it asks the live Herdr server what is actually
# at the recorded address, and takes exactly one of two outcomes.
#
#   adopt   The server proves the recorded pane is this task's - it echoes back
#           the recorded pane, tab, and workspace, and that tab's live label is
#           exactly fm-<task-id> (the label fm-spawn.sh writes at spawn) on a
#           single-pane tab. Identity is now established from the runtime, so
#           endpoint_task_id=<id> is recorded and ordinary teardown proceeds
#           unchanged, endpoint close included.
#
#   release The server proves the task has no endpoint at its recorded address -
#           the pane is not found, and its workspace holds neither a tab labeled
#           fm-<task-id> nor a tab at the recorded tab id (or the workspace is
#           itself gone). Nothing is there to close, so endpoint_released=<id> is
#           recorded instead. That marker authorizes the non-endpoint half of
#           cleanup and forbids every endpoint command, so teardown releases the
#           backlog, worktree, and state records while touching no pane at all.
#           This is the safer outcome and needs no claim about a pane's identity,
#           because it declines to act on one.
#
# bin/backends/herdr.sh owns both evidence procedures and is fail-safe toward
# refusal; bin/fm-backend.sh owns what each recorded field then authorizes.
#
# WHAT THIS IS NOT. There is no --force, no override flag, and no environment
# escape. Anything short of one of the two proofs above - a live pane whose label
# or tab disagrees, an unreachable server, a non-JSON or unparseable answer,
# ambiguous metadata, a non-Herdr backend, or a record that already carries a
# binding - refuses and changes nothing. Agent state is deliberately not
# consulted: what adopt proves is the recorded pane's IDENTITY, not its
# liveness, so a pane with no registered agent is adopted like any other once
# the recorded pane, tab, and workspace agree and that tab's live label is
# fm-<task-id> on a single-pane tab. Nor does
# a proof of absence license closing the recorded address anyway: the pane id can
# be reallocated between this read and any later command, which is exactly the
# hazard the original refusal exists to prevent.
#
# This repairs firstmate's own record of the task and nothing else. It never
# touches the worktree, its commits, or its branch; teardown's unlanded-work
# refusals run afterwards, unchanged, and still block cleanup on their own.
#
# Usage: fm-endpoint-rebind.sh <task-id>
#        fm-endpoint-rebind.sh --dry-run <task-id>   report the outcome, write nothing
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

DRY_RUN=0
if [ "${1-}" = --dry-run ]; then
  DRY_RUN=1
  shift
fi
if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "${1-}"; then
  echo "usage: fm-endpoint-rebind.sh [--dry-run] <task-id>" >&2
  exit 2
fi
ID=$1
# Fail closed before touching a task record, exactly as the other lifecycle
# entry points do (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "REFUSED: task $ID has no regular endpoint metadata at $META; nothing to repair." >&2
  exit 1
}

BACKEND=$(fm_backend_of_meta "$META")
[ "$BACKEND" = herdr ] || {
  echo "REFUSED: task $ID records backend '$BACKEND'; only Herdr records have a verified live identity proof." >&2
  exit 1
}

if grep -q '^endpoint_task_id=' "$META"; then
  echo "REFUSED: task $ID already records an endpoint binding; nothing to repair." >&2
  exit 1
fi
if grep -q '^endpoint_released=' "$META"; then
  echo "REFUSED: task $ID already records a released endpoint; nothing to repair." >&2
  exit 1
fi

# Require the same structural consistency ordinary cleanup requires, so a repair
# can never bless a record teardown would still reject for another reason. The
# field-consistency predicate below is the validator's own, shared rather than
# restated so the two can never drift apart.
meta_field() {  # <key>
  fm_backend_meta_exact_value "$META" "$1" || return 1
}
WINDOW=$(meta_field window) || { echo "REFUSED: task $ID has a missing, empty, or ambiguous window endpoint." >&2; exit 1; }
SESSION=$(meta_field herdr_session) || SESSION=
WORKSPACE=$(meta_field herdr_workspace_id) || WORKSPACE=
TAB=$(meta_field herdr_tab_id) || TAB=
PANE=$(meta_field herdr_pane_id) || PANE=
if ! fm_backend_herdr_endpoint_fields_consistent "$WINDOW" "$SESSION" "$WORKSPACE" "$TAB" "$PANE"; then
  echo "REFUSED: Herdr endpoint metadata for task $ID is malformed or inconsistent; nothing to repair." >&2
  exit 1
fi

fm_backend_source herdr || exit 1
fm_backend_herdr_version_check || exit 1

OUTCOME=
if fm_backend_herdr_task_pane_identity_proven "$SESSION" "$WORKSPACE" "$TAB" "$PANE" "$ID"; then
  OUTCOME=adopt
elif fm_backend_herdr_task_endpoint_absent "$SESSION" "$WORKSPACE" "$TAB" "$PANE" "$ID"; then
  OUTCOME=release
else
  echo "REFUSED: the live Herdr server neither proved pane $PANE belongs to task $ID nor proved the task has no endpoint there." >&2
  echo "Nothing was changed. Inspect the recorded endpoint before retiring this task; there is no forcing path." >&2
  exit 1
fi

if [ "$OUTCOME" = adopt ]; then
  FIELD=endpoint_task_id
  echo "task $ID: live tab $TAB is labeled fm-$ID on a single pane $PANE; the recorded endpoint is proven to belong to this task."
else
  FIELD=endpoint_released
  echo "task $ID: pane $PANE is absent and workspace $WORKSPACE holds no tab for this task; it has no endpoint to close."
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "dry run: would record $FIELD=$ID in $META"
  exit 0
fi

# Rewrite through a temp file in the same directory and rename, so a concurrent
# reader sees either the old record or the repaired one, never a partial file.
# The record's own permissions carry over: a repair must not tighten or loosen
# them as a side effect (fm-pr-check.sh owns the one place meta mode changes).
META_MODE=$(fm_pr_file_mode "$META")
case "$META_MODE" in ''|*[!0-7]*) META_MODE=600 ;; esac
META_TMP=
rebind_cleanup() { [ -z "$META_TMP" ] || rm -f -- "$META_TMP"; }
trap rebind_cleanup EXIT
trap 'exit 1' HUP INT TERM
META_TMP=$(mktemp "$STATE/.fm-rebind-meta.XXXXXX") || exit 1
# Copy line by line rather than byte for byte, the way bin/fm-pr-check.sh does:
# a record whose final line has no newline would otherwise have the new field
# glued onto it, destroying that line and the repair in one write.
while IFS= read -r line || [ -n "$line" ]; do
  printf '%s\n' "$line" >> "$META_TMP" || exit 1
done < "$META"
printf '%s=%s\n' "$FIELD" "$ID" >> "$META_TMP" || exit 1
chmod "0$META_MODE" "$META_TMP" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=

# Prove the repaired record now validates, and that it authorizes exactly the
# endpoint action this outcome intended - never more.
fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
case "$OUTCOME:$FM_BACKEND_VALIDATED_ENDPOINT_ACTION" in
  adopt:allowed|release:forbidden) ;;
  *)
    echo "error: repaired record for $ID authorizes '$FM_BACKEND_VALIDATED_ENDPOINT_ACTION', not the $OUTCOME outcome" >&2
    exit 1
    ;;
esac

if [ "$OUTCOME" = adopt ]; then
  echo "recorded $FIELD=$ID; task $ID is now retirable and its proven endpoint will be closed by cleanup."
else
  echo "recorded $FIELD=$ID; task $ID is now retirable and cleanup will not touch its recorded endpoint."
fi
