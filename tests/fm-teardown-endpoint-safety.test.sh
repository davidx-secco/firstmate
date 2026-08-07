#!/usr/bin/env bash
# Regression tests for cleanup endpoint identity validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  # Logged, never canned: these suites assert that cleanup issues no runtime
  # endpoint command at all in the cases below, so any herdr call is a failure.
  cat > "$TMP_ROOT/$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse" \
    "$TMP_ROOT/$dir/fakebin/herdr"
  printf '%s\n' "$TMP_ROOT/$dir"
}

# The legacy Herdr record at the centre of these cases: structurally complete and
# internally consistent, but written before fm-spawn.sh stamped
# endpoint_task_id=. Extra fields let a case add a binding or release marker.
write_legacy_herdr_meta() {  # <case> <id> [extra-field...]
  local dir=$1 id=$2
  shift 2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=scout" "mode=no-mistakes" "backend=herdr" \
    "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2" "$@"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

# The refusal this whole feature is built around must survive it. An opaque Herdr
# record with no proven identity still refuses, --force included, and now points
# at the sanctioned repair instead of leaving the operator with no move.
test_unbound_herdr_endpoint_still_refuses_and_names_the_repair() {
  local dir id=endpoint-legacy
  dir=$(make_case legacy-unbound)
  write_legacy_herdr_meta "$dir" "$id"
  assert_refused_without_mutation "$dir" "$id" "legacy unbound Herdr endpoint"
  grep -q 'lacks an exact task binding' "$dir/stderr" \
    || fail "legacy unbound Herdr endpoint: refusal lost its reason: $(cat "$dir/stderr")"
  grep -q 'fm-endpoint-rebind.sh' "$dir/stderr" \
    || fail "legacy unbound Herdr endpoint: refusal did not name the sanctioned repair"
  grep -q 'no forcing path' "$dir/stderr" \
    || fail "legacy unbound Herdr endpoint: refusal did not rule out forcing"
  pass "fm-teardown: an unproven Herdr endpoint still refuses under --force and names the sanctioned repair"
}

# The release marker is a narrow authorization, not a second force flag: anything
# other than exactly one marker naming exactly this task refuses.
test_malformed_release_markers_refuse() {
  local dir id=endpoint-release

  dir=$(make_case release-empty)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_released="
  assert_refused_without_mutation "$dir" "$id" "empty release marker"

  dir=$(make_case release-duplicate)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_released=$id" "endpoint_released=$id"
  assert_refused_without_mutation "$dir" "$id" "duplicate release marker"

  dir=$(make_case release-foreign)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_released=other-task"
  assert_refused_without_mutation "$dir" "$id" "release marker naming another task"

  dir=$(make_case release-with-binding)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_task_id=$id" "endpoint_released=$id"
  assert_refused_without_mutation "$dir" "$id" "release marker alongside a binding"

  # A release marker cannot smuggle a broken record past the structural checks.
  dir=$(make_case release-inconsistent)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p99" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=scout" "backend=herdr" "endpoint_released=$id" \
    "herdr_session=lab" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  assert_refused_without_mutation "$dir" "$id" "release marker on an inconsistent record"

  pass "fm-teardown: an empty, duplicated, foreign, contradictory, or inconsistent release marker refuses"
}

# The marker is written only from Herdr's empirically verified live identity
# surface, so on any other backend it can only be hand-written. Honoring it there
# would retire the record while leaving a live window running untracked, so the
# validator refuses before any mutation or runtime call.
test_release_marker_on_a_non_herdr_backend_refuses() {
  local dir id=endpoint-foreign-release

  dir=$(make_case release-tmux)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=scout" "mode=no-mistakes" "backend=tmux" "endpoint_released=$id"
  assert_refused_without_mutation "$dir" "$id" "release marker on a tmux record"
  grep -q 'no verified release path' "$dir/stderr" \
    || fail "release marker on a tmux record: refusal lost its reason: $(cat "$dir/stderr")"

  dir=$(make_case release-zellij)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:2" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=scout" "mode=no-mistakes" "backend=zellij" "zellij_session=lab" \
    "zellij_tab_id=1" "zellij_pane_id=2" "endpoint_released=$id"
  assert_refused_without_mutation "$dir" "$id" "release marker on a Zellij record"

  pass "fm-teardown: an endpoint release marker on a non-Herdr record refuses before any mutation or runtime call"
}

# A released record's meta is removed, so its presentation journal could never be
# associated with a task again. It is retired as ordinary volatile state, by a
# plain file removal that issues no herdr command of any kind.
test_released_record_retires_its_presentation_journal() {
  local dir id=endpoint-released-journal
  dir=$(make_case release-presentation)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_released=$id"
  printf 'workspace_id=w1\npane_id=w1:p2\n' > "$dir/home/state/$id.herdr-presentation"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "released presentation teardown failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.herdr-presentation" \
    "released presentation teardown left its journal behind forever"
  assert_absent "$dir/home/state/$id.meta" "released presentation teardown kept the task record"
  grep -q '^herdr' "$dir/runtime.log" \
    && fail "released presentation teardown commanded herdr: $(cat "$dir/runtime.log")"
  pass "fm-teardown: a released Herdr record's presentation journal is removed without any herdr command"
}

# The release outcome's whole promise: cleanup completes without commanding the
# runtime endpoint even once.
test_released_endpoint_cleans_up_without_touching_the_runtime() {
  local dir id=endpoint-released
  dir=$(make_case release-completes)
  write_legacy_herdr_meta "$dir" "$id" "endpoint_released=$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "released endpoint teardown failed: $(cat "$dir/stderr")"
  grep -q '^herdr' "$dir/runtime.log" \
    && fail "released endpoint teardown commanded herdr: $(cat "$dir/runtime.log")"
  grep -q '^tmux' "$dir/runtime.log" \
    && fail "released endpoint teardown commanded tmux: $(cat "$dir/runtime.log")"
  grep -q '^treehouse' "$dir/runtime.log" \
    || fail "released endpoint teardown skipped the worktree return: $(cat "$dir/runtime.log")"
  assert_absent "$dir/home/state/$id.meta" "released endpoint teardown kept the task record"
  grep -q 'left untouched' "$dir/stdout" \
    || fail "released endpoint teardown did not report the untouched endpoint: $(cat "$dir/stdout")"
  pass "fm-teardown: a released Herdr record is retired and its recorded endpoint is never commanded"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"
  [ "$FM_BACKEND_VALIDATED_ENDPOINT_ACTION" = allowed ] \
    || fail "a proven Herdr binding did not authorize endpoint action"

  # A released record validates for cleanup but withholds endpoint authority.
  id=herdr-released-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_released=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "released Herdr endpoint refused"
  [ "$FM_BACKEND_VALIDATED_ENDPOINT_ACTION" = forbidden ] \
    || fail "a released record still authorized endpoint action"
  fm_backend_meta_endpoint_action_forbidden "$dir/home/state/$id.meta" \
    || fail "the released record's endpoint predicate did not forbid endpoint action"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  for backend in tmux herdr zellij orca cmux; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_invalid_endpoint_records_refuse_before_mutation
test_unbound_herdr_endpoint_still_refuses_and_names_the_repair
test_malformed_release_markers_refuse
test_release_marker_on_a_non_herdr_backend_refuses
test_released_record_retires_its_presentation_journal
test_released_endpoint_cleans_up_without_touching_the_runtime
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
