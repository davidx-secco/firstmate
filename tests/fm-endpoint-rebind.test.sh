#!/usr/bin/env bash
# tests/fm-endpoint-rebind.test.sh - the evidence contract for
# bin/fm-endpoint-rebind.sh, the sanctioned repair for a Herdr task whose
# metadata predates fm-spawn.sh stamping endpoint_task_id=.
#
# The whole point of that script is that it establishes the binding from what
# the live server says, never from a field anyone can write, so these tests are
# written against a fake `herdr` CLI that models the two response shapes the
# real binary produces (verified against 0.7.5): a success body on stdout with
# exit 0, and an error body - carrying the error.code these checks read - on
# STDERR with exit 1.
#
# Two outcomes may be written and nothing else: endpoint_task_id= when the
# server proves the recorded pane is this task's, endpoint_released= when it
# proves the task has no endpoint at the recorded address. Every other answer
# must leave the record untouched, so most cases below assert a refusal with a
# byte-identical metadata file afterwards.
#
# The complementary teardown-side assertions - what each recorded field then
# authorizes, and that unlanded work still refuses - live in
# tests/fm-teardown-endpoint-safety.test.sh and tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# fm_pr_file_mode is the repo's portable file-mode reader. Sourced with
# source=/dev/null, the convention for every test outside the callback/variable
# interop suites tests/fm-lint.test.sh allowlists for production source context.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

REBIND="$ROOT/bin/fm-endpoint-rebind.sh"
TMP_ROOT=$(fm_test_tmproot fm-endpoint-rebind)
ID=task-x1

# A fake `herdr` that answers `pane get` and `tab list` from canned bodies and
# reproduces the real binary's stdout/exit-0 vs stderr/exit-1 split, so the
# checks under test see exactly the stream and status they see in production.
# <name>.raw is the escape hatch for a non-JSON failure (an unreachable server).
make_case() {  # <name> -> echoes case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/resp"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
RESP="${FM_REBIND_RESP:?}"
{ printf 'herdr'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } >> "${FM_REBIND_LOG:?}"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.5","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
case "${1:-} ${2:-}" in
  "pane get") body="$RESP/pane" ;;
  "tab list") body="$RESP/tab" ;;
  *) echo "fake herdr: unexpected call: $*" >&2; exit 99 ;;
esac
if [ -f "$body.raw" ]; then cat "$body.raw" >&2; exit 1; fi
[ -f "$body.out" ] || { echo "fake herdr: no canned response for $*" >&2; exit 98; }
if grep -q '"error"' "$body.out"; then cat "$body.out" >&2; exit 1; fi
cat "$body.out"
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  : > "$dir/herdr.log"
  printf '%s\n' "$dir"
}

# The legacy record every case starts from: structurally complete and internally
# consistent, with no endpoint_task_id= at all. This is the shape real 2026-07
# metadata has.
write_legacy_meta() {  # <dir> [extra-field...]
  local dir=$1
  shift
  fm_write_meta "$dir/state/$ID.meta" \
    "window=lab:w1:p2" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr" \
    "herdr_session=lab" \
    "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" \
    "herdr_pane_id=w1:p2" \
    "$@"
}

pane_live() {  # <dir> [pane] [tab] [workspace]
  local dir=$1 pane=${2:-w1:p2} tab=${3:-w1:t2} ws=${4:-w1}
  cat > "$dir/resp/pane.out" <<EOF
{"id":"cli:pane:get","result":{"pane":{"pane_id":"$pane","tab_id":"$tab","workspace_id":"$ws","agent_status":"idle"}}}
EOF
}

pane_absent() {  # <dir>
  cat > "$1/resp/pane.out" <<'EOF'
{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"},"id":"cli:pane:get"}
EOF
}

tabs() {  # <dir> <tabs-json-array>
  cat > "$1/resp/tab.out" <<EOF
{"id":"cli:tab:list","result":{"tabs":$2}}
EOF
}

tab_matching() {  # <dir> [label] [pane_count] [tab_id]
  local dir=$1 label=${2:-fm-$ID} count=${3:-1} tab=${4:-w1:t2}
  tabs "$dir" "[{\"tab_id\":\"$tab\",\"label\":\"$label\",\"pane_count\":$count}]"
}

run_rebind() {  # <dir> [args...]
  local dir=$1
  shift
  FM_GATE_REFUSE_BYPASS=1 \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_REBIND_RESP="$dir/resp" \
  FM_REBIND_LOG="$dir/herdr.log" \
  PATH="$dir/fakebin:$PATH" \
    "$REBIND" "$@"
}

# Assert the repair refuses and left the record byte-identical. A repair that
# refuses must never leave a half-written or "helpfully" annotated record.
assert_refused_unchanged() {  # <dir> <description> [args...]
  local dir=$1 description=$2 rc before after
  shift 2
  before=$(cat "$dir/state/$ID.meta")
  set +e
  run_rebind "$dir" "$@" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: repair unexpectedly succeeded"
  after=$(cat "$dir/state/$ID.meta")
  [ "$before" = "$after" ] || fail "$description: metadata changed despite refusal"
  local leftover
  for leftover in "$dir/state"/.fm-rebind-meta.*; do
    [ -e "$leftover" ] && fail "$description: left a temporary metadata file behind"
  done
  return 0
}

meta_field_count() {  # <dir> <key>
  grep -c "^$2=" "$1/state/$ID.meta" 2>/dev/null || true
}

meta_field_value() {  # <dir> <key>
  grep "^$2=" "$1/state/$ID.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

test_proven_live_identity_adopts_binding() {
  local dir
  dir=$(make_case adopt-proven)
  write_legacy_meta "$dir"
  pane_live "$dir"
  tab_matching "$dir"

  run_rebind "$dir" "$ID" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "adopt: repair refused a provably-owned pane: $(cat "$dir/stderr")"
  [ "$(meta_field_count "$dir" endpoint_task_id)" = 1 ] \
    || fail "adopt: did not record exactly one endpoint_task_id"
  [ "$(meta_field_value "$dir" endpoint_task_id)" = "$ID" ] \
    || fail "adopt: recorded binding does not name the task"
  [ "$(meta_field_count "$dir" endpoint_released)" = 0 ] \
    || fail "adopt: also recorded a release marker"
  grep -q 'proven to belong to this task' "$dir/stdout" \
    || fail "adopt: did not report the proof: $(cat "$dir/stdout")"
  pass "fm-endpoint-rebind: a live pane the server binds to fm-<id> on a single-pane tab adopts the binding"
}

test_absent_endpoint_releases_without_touching_it() {
  local dir
  dir=$(make_case release-absent)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  tabs "$dir" '[{"tab_id":"w1:t9","label":"fm-other-task","pane_count":1}]'

  run_rebind "$dir" "$ID" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "release: repair refused a provably absent endpoint: $(cat "$dir/stderr")"
  [ "$(meta_field_count "$dir" endpoint_released)" = 1 ] \
    || fail "release: did not record exactly one endpoint_released"
  [ "$(meta_field_value "$dir" endpoint_released)" = "$ID" ] \
    || fail "release: recorded marker does not name the task"
  [ "$(meta_field_count "$dir" endpoint_task_id)" = 0 ] \
    || fail "release: invented an endpoint binding for an unproven pane"
  # The repair reads the runtime; it must never command it.
  grep -qE 'herdr <(pane|tab|workspace) <(close|kill|delete)' "$dir/herdr.log" \
    && fail "release: repair issued a destructive herdr command: $(cat "$dir/herdr.log")"
  pass "fm-endpoint-rebind: an absent endpoint releases the record and issues no runtime command"
}

test_missing_workspace_releases() {
  local dir
  dir=$(make_case release-workspace-gone)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  cat > "$dir/resp/tab.out" <<'EOF'
{"error":{"code":"workspace_not_found","message":"workspace w1 not found"},"id":"cli:tab:list"}
EOF

  run_rebind "$dir" "$ID" >/dev/null 2> "$dir/stderr" \
    || fail "workspace-gone: repair refused: $(cat "$dir/stderr")"
  [ "$(meta_field_count "$dir" endpoint_released)" = 1 ] \
    || fail "workspace-gone: did not release the record"
  pass "fm-endpoint-rebind: a vanished workspace subsumes its panes and releases the record"
}

test_unproven_live_pane_refuses() {
  local dir

  # A live pane whose tab carries ANOTHER task's label is the exact accident the
  # original refusal exists to prevent: adopting it would authorize closing
  # someone else's pane.
  dir=$(make_case refuse-foreign-label)
  write_legacy_meta "$dir"
  pane_live "$dir"
  tab_matching "$dir" "fm-someone-elses-task"
  assert_refused_unchanged "$dir" "foreign tab label" "$ID"
  grep -q 'no forcing path' "$dir/stderr" \
    || fail "foreign tab label: refusal did not state that no forcing path exists"

  # A multi-pane tab means the label no longer names one pane, so the recorded
  # pane is not individually identified.
  dir=$(make_case refuse-multi-pane)
  write_legacy_meta "$dir"
  pane_live "$dir"
  tab_matching "$dir" "fm-$ID" 2
  assert_refused_unchanged "$dir" "multi-pane tab" "$ID"

  # The pane reports a different tab than the record claims.
  dir=$(make_case refuse-tab-mismatch)
  write_legacy_meta "$dir"
  pane_live "$dir" w1:p2 w1:t7 w1
  tab_matching "$dir"
  assert_refused_unchanged "$dir" "pane reports another tab" "$ID"

  # The pane reports a different workspace than the record claims.
  dir=$(make_case refuse-workspace-mismatch)
  write_legacy_meta "$dir"
  pane_live "$dir" w1:p2 w1:t2 w9
  tab_matching "$dir"
  assert_refused_unchanged "$dir" "pane reports another workspace" "$ID"

  # The recorded tab is absent from its workspace while the pane reads live.
  dir=$(make_case refuse-tab-absent)
  write_legacy_meta "$dir"
  pane_live "$dir"
  tabs "$dir" '[{"tab_id":"w1:t9","label":"fm-other","pane_count":1}]'
  assert_refused_unchanged "$dir" "recorded tab absent" "$ID"

  pass "fm-endpoint-rebind: a live pane refuses unless label, tab, workspace, and pane count all agree"
}

test_ambiguous_absence_refuses() {
  local dir

  # The recorded pane is gone but a tab still labeled fm-<id> survives: the task
  # DOES own a pane here, just not the recorded one. Releasing would abandon it.
  dir=$(make_case refuse-surviving-label)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  tabs "$dir" "[{\"tab_id\":\"w1:t8\",\"label\":\"fm-$ID\",\"pane_count\":1}]"
  assert_refused_unchanged "$dir" "surviving task-labeled tab" "$ID"

  # The recorded tab id survives with the recorded pane gone. herdr closes a tab
  # with its last pane, so that id now names either a multi-pane tab or a reused
  # counter - either way, not something to declare absent.
  dir=$(make_case refuse-surviving-tab-id)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  tabs "$dir" '[{"tab_id":"w1:t2","label":"something-else","pane_count":1}]'
  assert_refused_unchanged "$dir" "surviving recorded tab id" "$ID"

  pass "fm-endpoint-rebind: an absent pane refuses while its workspace still shows a tab for the task"
}

test_inconclusive_reads_refuse() {
  local dir

  # An unreachable server produces a non-JSON failure. That is not absence.
  dir=$(make_case refuse-unreachable)
  write_legacy_meta "$dir"
  printf '%s\n' 'Error: Os { code: 2, kind: NotFound, message: "No such file or directory" }' \
    > "$dir/resp/pane.raw"
  assert_refused_unchanged "$dir" "unreachable server" "$ID"

  # A pane_get error that is NOT pane_not_found proves nothing either way.
  dir=$(make_case refuse-other-error)
  write_legacy_meta "$dir"
  cat > "$dir/resp/pane.out" <<'EOF'
{"error":{"code":"internal_error","message":"boom"},"id":"cli:pane:get"}
EOF
  tab_matching "$dir"
  assert_refused_unchanged "$dir" "non-absence pane error" "$ID"

  # The pane is absent but the workspace read itself fails without a code.
  dir=$(make_case refuse-tab-unreadable)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  printf '%s\n' 'not json at all' > "$dir/resp/tab.raw"
  assert_refused_unchanged "$dir" "unreadable workspace read" "$ID"

  pass "fm-endpoint-rebind: an unreachable server or unparseable answer refuses instead of guessing"
}

test_records_that_need_no_repair_refuse() {
  local dir

  dir=$(make_case refuse-already-bound)
  write_legacy_meta "$dir" "endpoint_task_id=$ID"
  pane_live "$dir"
  tab_matching "$dir"
  assert_refused_unchanged "$dir" "already bound" "$ID"

  dir=$(make_case refuse-already-released)
  write_legacy_meta "$dir" "endpoint_released=$ID"
  pane_absent "$dir"
  tabs "$dir" '[]'
  assert_refused_unchanged "$dir" "already released" "$ID"

  # A hand-written binding for ANOTHER task must not be repairable into a valid
  # one; the record stays refused for the operator to look at.
  dir=$(make_case refuse-foreign-binding)
  write_legacy_meta "$dir" "endpoint_task_id=other-task"
  pane_live "$dir"
  tab_matching "$dir"
  assert_refused_unchanged "$dir" "binding names another task" "$ID"

  pass "fm-endpoint-rebind: a record that already carries a binding or release marker is never rewritten"
}

test_out_of_scope_and_malformed_records_refuse() {
  local dir

  # Only Herdr has a verified live identity proof; no other backend may be
  # repaired on the strength of this one.
  dir=$(make_case refuse-non-herdr)
  fm_write_meta "$dir/state/$ID.meta" \
    "window=lab:7" "worktree=$dir/wt" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  assert_refused_unchanged "$dir" "non-herdr backend" "$ID"
  [ ! -s "$dir/herdr.log" ] || fail "non-herdr backend: queried herdr anyway"

  # window= must still equal <session>:<pane>, exactly as cleanup requires, so a
  # repair can never bless a record teardown would reject for another reason.
  dir=$(make_case refuse-inconsistent-window)
  write_legacy_meta "$dir"
  fm_write_meta "$dir/state/$ID.meta" \
    "window=lab:w1:p99" "worktree=$dir/wt" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  assert_refused_unchanged "$dir" "window disagrees with pane" "$ID"
  [ ! -s "$dir/herdr.log" ] || fail "inconsistent window: queried herdr anyway"

  # An ambiguous duplicate field is not something to choose between.
  dir=$(make_case refuse-duplicate-pane)
  fm_write_meta "$dir/state/$ID.meta" \
    "window=lab:w1:p2" "worktree=$dir/wt" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "herdr_pane_id=w1:p3"
  assert_refused_unchanged "$dir" "duplicate pane field" "$ID"

  pass "fm-endpoint-rebind: non-Herdr backends and malformed Herdr records refuse without a runtime query"
}

# The repair adds one field. It must not change the record's permissions as a
# side effect: bin/fm-pr-check.sh owns the one place meta mode legitimately
# changes, and a task whose poll is armed must stay private afterwards.
test_record_permissions_are_preserved() {
  local dir mode
  for mode in 644 600; do
    dir=$(make_case "mode-$mode")
    write_legacy_meta "$dir"
    chmod "0$mode" "$dir/state/$ID.meta"
    pane_absent "$dir"
    tabs "$dir" '[]'
    run_rebind "$dir" "$ID" >/dev/null 2> "$dir/stderr" \
      || fail "mode-$mode: repair refused: $(cat "$dir/stderr")"
    [ "$(fm_pr_file_mode "$dir/state/$ID.meta")" = "$mode" ] \
      || fail "mode-$mode: repair changed the record's permissions to $(fm_pr_file_mode "$dir/state/$ID.meta")"
  done
  pass "fm-endpoint-rebind: the repaired record keeps the permissions it had"
}

# A record whose final line has no newline must not have the new field glued onto
# it: that would destroy the last field and the repair in the same write, and the
# only copy of the record is already gone by then.
test_record_without_a_trailing_newline_is_repaired_well_formed() {
  local dir
  dir=$(make_case no-trailing-newline)
  write_legacy_meta "$dir"
  printf '%s' "$(cat "$dir/state/$ID.meta")" > "$dir/state/$ID.meta.trimmed"
  mv "$dir/state/$ID.meta.trimmed" "$dir/state/$ID.meta"
  [ -n "$(tail -c 1 "$dir/state/$ID.meta")" ] \
    || fail "no-trailing-newline: fixture still ends with a newline"
  pane_absent "$dir"
  tabs "$dir" '[]'

  run_rebind "$dir" "$ID" >/dev/null 2> "$dir/stderr" \
    || fail "no-trailing-newline: repair refused: $(cat "$dir/stderr")"
  [ "$(meta_field_count "$dir" endpoint_released)" = 1 ] \
    || fail "no-trailing-newline: did not record exactly one endpoint_released"
  [ "$(meta_field_value "$dir" endpoint_released)" = "$ID" ] \
    || fail "no-trailing-newline: recorded marker does not name the task"
  [ "$(meta_field_count "$dir" herdr_pane_id)" = 1 ] \
    || fail "no-trailing-newline: the record's last field did not survive the repair"
  [ "$(meta_field_value "$dir" herdr_pane_id)" = "w1:p2" ] \
    || fail "no-trailing-newline: the record's last field was corrupted by the append"
  pass "fm-endpoint-rebind: a record with no trailing newline is repaired into a well-formed record"
}

test_dry_run_writes_nothing() {
  local dir
  dir=$(make_case dry-run)
  write_legacy_meta "$dir"
  pane_absent "$dir"
  tabs "$dir" '[]'
  local before after
  before=$(cat "$dir/state/$ID.meta")
  run_rebind "$dir" --dry-run "$ID" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "dry run failed: $(cat "$dir/stderr")"
  after=$(cat "$dir/state/$ID.meta")
  [ "$before" = "$after" ] || fail "dry run modified the record"
  grep -q "would record endpoint_released=$ID" "$dir/stdout" \
    || fail "dry run did not report the outcome it would write: $(cat "$dir/stdout")"
  pass "fm-endpoint-rebind: --dry-run reports the outcome and writes nothing"
}

# The repair exists BECAUSE forcing must stay unavailable. This guards both the
# behavior and the source, so a future flag cannot quietly reintroduce one.
test_no_forcing_path_exists() {
  local dir forcing
  dir=$(make_case no-force)
  write_legacy_meta "$dir"
  # An unproven live pane, i.e. the case someone would reach for --force on.
  pane_live "$dir"
  tab_matching "$dir" "fm-someone-elses-task"

  assert_refused_unchanged "$dir" "--force" "$ID" --force
  assert_refused_unchanged "$dir" "-f" "$ID" -f
  assert_refused_unchanged "$dir" "leading --force" --force "$ID"

  # An environment escape must not exist either.
  local rc before after
  before=$(cat "$dir/state/$ID.meta")
  set +e
  FM_ENDPOINT_REBIND_FORCE=1 FM_FORCE=1 FM_BACKEND_VALIDATED_ENDPOINT_ACTION=allowed \
    run_rebind "$dir" "$ID" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an environment variable forced an unproven adoption"
  after=$(cat "$dir/state/$ID.meta")
  [ "$before" = "$after" ] || fail "an environment variable changed the record"

  # No force/bypass switch in the script itself, comments aside.
  forcing=$(grep -vE '^[[:space:]]*#' "$REBIND" | grep -nEi 'force|bypass' || true)
  [ -z "$forcing" ] || fail "fm-endpoint-rebind.sh gained a forcing path: $forcing"

  pass "fm-endpoint-rebind: no flag, argument, or environment variable can force an unproven repair"
}

test_proven_live_identity_adopts_binding
test_absent_endpoint_releases_without_touching_it
test_missing_workspace_releases
test_unproven_live_pane_refuses
test_ambiguous_absence_refuses
test_inconclusive_reads_refuse
test_records_that_need_no_repair_refuse
test_out_of_scope_and_malformed_records_refuse
test_record_permissions_are_preserved
test_record_without_a_trailing_newline_is_repaired_well_formed
test_dry_run_writes_nothing
test_no_forcing_path_exists
