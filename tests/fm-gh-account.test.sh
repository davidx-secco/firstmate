#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-account.sh and the account selection fm-spawn.sh
# performs before a launch.
#
# The failure these cover: a home with two accounts logged in to gh hands a
# worker whichever account is globally active, because the worker's copy lives
# outside any per-directory shell hook, and a repository that account cannot see
# then fails late with "Could not resolve to a Repository". Selection must come
# from the repository's own origin owner, must never switch the active account,
# and must refuse rather than guess.
#
# A fake gh stands in for both accounts so every case is deterministic and
# offline. It records each invocation, so the tests can assert what was NOT run:
# no "auth switch", no repository probe on the paths that need no network, and no
# credential leaking into account introspection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GHA="$ROOT/bin/fm-gh-account.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-account)

# What the child of "exec" reports about the credential it inherited.
# shellcheck disable=SC2016  # deliberate: the child shell expands this, not the test shell
SHOW_TOKEN='printf "%s\n" "${GH_TOKEN:-none}"'

# --- fake gh ----------------------------------------------------------------
#
# FM_FAKE_GH_ACCOUNTS  space-separated logins that are logged in
# FM_FAKE_GH_ACCESS    "<login>=<rank>" pairs; a login absent from it cannot see
#                      the repository at all
# FM_FAKE_GH_LOG       every invocation, plus violation markers, one per line

make_fake_gh() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_GH_LOG:?FM_FAKE_GH_LOG unset}
printf 'gh %s\n' "$*" >> "$log"
case "${1:-} ${2:-}" in
  "auth status")
    # Account introspection must never see an injected credential: a stale
    # GH_TOKEN would otherwise decide which accounts are visible.
    [ -z "${GH_TOKEN:-}" ] || printf 'VIOLATION token-visible-to-auth-status\n' >> "$log"
    [ -z "${GITHUB_TOKEN:-}" ] || printf 'VIOLATION github-token-visible-to-auth-status\n' >> "$log"
    printf 'github.com\n'
    for a in ${FM_FAKE_GH_ACCOUNTS:-}; do
      printf '  x Logged in to github.com account %s (keyring)\n' "$a"
    done
    exit 0
    ;;
  "auth token")
    [ "${3:-}" = --user ] || { printf 'VIOLATION token-without-user\n' >> "$log"; exit 1; }
    for a in ${FM_FAKE_GH_ACCOUNTS:-}; do
      if [ "$a" = "${4:-}" ]; then
        printf 'ghtoken-%s\n' "$a"
        exit 0
      fi
    done
    printf 'no oauth token found for github.com account %s\n' "${4:-}" >&2
    exit 1
    ;;
  "auth switch")
    printf 'VIOLATION auth-switch\n' >> "$log"
    exit 0
    ;;
esac
if [ "${1:-}" = api ]; then
  # The probe must act as one specific account, never as the active one.
  case "${GH_TOKEN:-}" in
    ghtoken-*) acting=${GH_TOKEN#ghtoken-} ;;
    *) printf 'VIOLATION api-without-account-token\n' >> "$log"; exit 1 ;;
  esac
  for pair in ${FM_FAKE_GH_ACCESS:-}; do
    if [ "${pair%%=*}" = "$acting" ]; then
      printf '%s\n' "${pair#*=}"
      exit 0
    fi
  done
  printf 'gh: Not Found (HTTP 404)\n' >&2
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# --- resolver cases ---------------------------------------------------------

# new_case <name> [origin-url] echoes "<case-dir>|<repo-dir>|<fakebin>|<log>".
new_case() {  # <name> [origin]
  local name=$1 origin=${2:-} dir repo fakebin log
  dir="$TMP_ROOT/$name"
  repo="$dir/repo"
  log="$dir/gh.log"
  fakebin=$(make_fake_gh "$dir")
  mkdir -p "$dir/config"
  fm_git_init_commit "$repo"
  [ -z "$origin" ] || git -C "$repo" remote add origin "$origin"
  : > "$log"
  printf '%s|%s|%s|%s\n' "$dir" "$repo" "$fakebin" "$log"
}

read_case() {  # <record>
  IFS='|' read -r CASE_DIR REPO_DIR FAKEBIN LOG <<EOF
$1
EOF
}

# run_gha <accounts> <access> <args...>: run fm-gh-account.sh against the fake
# gh, echo its combined output, and return its exit status.
run_gha() {
  local accounts=$1 access=$2
  shift 2
  FM_CONFIG_OVERRIDE="$CASE_DIR/config" \
    FM_FAKE_GH_ACCOUNTS="$accounts" FM_FAKE_GH_ACCESS="$access" \
    FM_FAKE_GH_LOG="$LOG" \
    PATH="$FAKEBIN:$PATH" \
    "$GHA" "$@" 2>&1
}

assert_no_violations() {  # <label>
  assert_no_grep VIOLATION "$LOG" "$1: fake gh recorded a forbidden call"
}

assert_no_probe() {  # <label>
  assert_no_grep 'gh api' "$LOG" "$1: resolution hit the network when it did not need to"
}

# The reported incident, from both sides: an org repository only the second
# account can read resolves to that account, and a repository owned by the first
# account's own login resolves to it with no network call at all.
test_both_accounts_resolve_from_the_repository() {
  local rec out status

  rec=$(new_case both-org git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "org repository should resolve"
  [ "$out" = davidx-secco ] || fail "org repository resolved to '$out', wanted davidx-secco"
  assert_no_violations "org repository"

  rec=$(new_case both-personal git@github.com:daveonthegit/Kyarafit.git)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'daveonthegit=50 davidx-secco=10' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "own-login repository should resolve"
  [ "$out" = daveonthegit ] || fail "own-login repository resolved to '$out', wanted daveonthegit"
  assert_no_probe "own-login repository"
  assert_no_violations "own-login repository"

  pass "each account is selected from the repository it owns access to, not from global gh state"
}

# https and ssh-with-port forms of the same origin resolve identically, and a
# repository on another forge selects nothing rather than guessing.
test_origin_forms_and_other_forges() {
  local rec out status
  while IFS='|' read -r name origin want; do
    [ -n "$name" ] || continue
    rec=$(new_case "form-$name" "$origin")
    read_case "$rec"
    out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
    status=$?
    case "$want" in
      3)
        expect_code 3 "$status" "$name: should select nothing"
        [ -z "$out" ] || fail "$name: selected '$out' for a repository it must leave alone"
        ;;
      *)
        expect_code 0 "$status" "$name: should resolve"
        [ "$out" = "$want" ] || fail "$name: resolved to '$out', wanted $want"
        ;;
    esac
  done <<'ROWS'
https|https://github.com/BG-Media-LLC/vsl-funnel.git|davidx-secco
https-no-suffix|https://github.com/BG-Media-LLC/vsl-funnel|davidx-secco
ssh-url|ssh://git@github.com/BG-Media-LLC/vsl-funnel.git|davidx-secco
ssh-url-port|ssh://git@github.com:22/BG-Media-LLC/vsl-funnel.git|davidx-secco
gitlab|git@gitlab.com:BG-Media-LLC/vsl-funnel.git|3
self-hosted|https://git.example.com/BG-Media-LLC/vsl-funnel.git|3
ROWS
  rec=$(new_case form-no-origin)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  expect_code 3 "$?" "a checkout with no origin should select nothing"
  pass "every github.com origin form resolves alike; other forges and originless checkouts select nothing"
}

# Nothing to choose between: gh missing, nobody logged in, or a single account.
# Each leaves gh exactly as the caller had it, which is what upstream homes with
# one account rely on.
test_nothing_to_choose_leaves_gh_alone() {
  local rec status out sandbox tool
  rec=$(new_case single git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"

  run_gha 'daveonthegit' 'daveonthegit=50' resolve --dir "$REPO_DIR" >/dev/null
  expect_code 3 "$?" "one logged-in account should select nothing"
  assert_no_probe "single account"

  run_gha '' '' resolve --dir "$REPO_DIR" >/dev/null
  expect_code 3 "$?" "no logged-in account should select nothing"

  # gh absent: a PATH holding only the tools the resolver itself needs.
  sandbox="$CASE_DIR/no-gh"
  mkdir -p "$sandbox"
  for tool in bash git sed tr paste wc env; do
    ln -sf "$(command -v "$tool")" "$sandbox/$tool"
  done
  out=$(FM_CONFIG_OVERRIDE="$CASE_DIR/config" PATH="$sandbox" "$GHA" resolve --dir "$REPO_DIR" 2>&1)
  status=$?
  expect_code 3 "$status" "absent gh should select nothing (output: $out)"
  pass "gh absent, nobody logged in, and a single account all leave gh untouched"
}

# The failure path: refuse loudly, name the fix, and never fall back to the
# account that happens to be active.
test_undeterminable_account_fails_closed() {
  local rec out status
  rec=$(new_case unreadable git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' '' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 1 "$status" "a repository no account can read must fail closed"
  assert_contains "$out" "no logged-in GitHub account can read BG-Media-LLC/vsl-funnel" \
    "refusal does not name the repository"
  assert_contains "$out" "gh-accounts" "refusal does not name the fix"
  assert_contains "$out" "daveonthegit, davidx-secco" "refusal does not name what was tried"
  assert_no_violations "unreadable repository"

  rec=$(new_case ambiguous git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'daveonthegit=30 davidx-secco=30' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 1 "$status" "equal access must be reported as ambiguous, not guessed"
  assert_contains "$out" "equal access" "ambiguity is not explained"

  rec=$(new_case ranked git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'daveonthegit=10 davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "unequal access should resolve to the stronger account"
  [ "$out" = davidx-secco ] || fail "stronger access lost to '$out'"
  pass "an undeterminable or ambiguous account is refused with its fix; unequal access resolves"
}

# config/gh-accounts answers an owner with no network, and a line naming an
# account that is not logged in is a reported configuration error.
test_recorded_mapping_wins() {
  local rec out status
  rec=$(new_case mapped git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  printf '# fleet mapping\n\nBG-Media-LLC davidx-secco\nother = daveonthegit\n' \
    > "$CASE_DIR/config/gh-accounts"
  out=$(run_gha 'daveonthegit davidx-secco' '' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "a recorded owner should resolve without a probe"
  [ "$out" = davidx-secco ] || fail "recorded mapping resolved to '$out'"
  assert_no_probe "recorded mapping"

  printf 'BG-Media-LLC not-logged-in\n' > "$CASE_DIR/config/gh-accounts"
  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 1 "$status" "a mapping to an unknown account must be reported"
  assert_contains "$out" "not-logged-in" "configuration error does not name the bad account"
  pass "config/gh-accounts decides an owner offline, and a bad line is reported not worked around"
}

# FM_GH_ACCOUNT overrides one invocation; "none" opts a lane out entirely.
test_per_invocation_override() {
  local rec out status
  rec=$(new_case override git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"

  out=$(FM_GH_ACCOUNT=daveonthegit run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "an explicit override should resolve"
  [ "$out" = daveonthegit ] || fail "override resolved to '$out'"
  assert_no_probe "explicit override"

  FM_GH_ACCOUNT=none run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR" >/dev/null
  expect_code 3 "$?" "FM_GH_ACCOUNT=none should select nothing"

  out=$(FM_GH_ACCOUNT=ghost run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 1 "$status" "an override naming an unknown account must fail closed"
  assert_contains "$out" ghost "override failure does not name the account"
  pass "FM_GH_ACCOUNT overrides one run, none opts out, and an unknown login is refused"
}

# exec lends the credential to one child and nothing else.
test_exec_lends_the_credential_to_one_child() {
  local rec out status
  rec=$(new_case exec-ok git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"

  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' \
    exec --dir "$REPO_DIR" -- sh -c "$SHOW_TOKEN")
  status=$?
  expect_code 0 "$status" "exec should run the command"
  assert_contains "$out" ghtoken-davidx-secco "exec did not export the selected account's credential"

  out=$(run_gha 'daveonthegit' 'daveonthegit=50' \
    exec --dir "$REPO_DIR" -- sh -c "$SHOW_TOKEN")
  status=$?
  expect_code 0 "$status" "exec should still run when no selection applies"
  assert_contains "$out" none "exec set a credential where it should have left gh alone"

  out=$(run_gha 'daveonthegit davidx-secco' '' exec --dir "$REPO_DIR" -- sh -c 'printf ITRAN')
  status=$?
  expect_code 1 "$status" "exec must not run a command with an undetermined account"
  assert_not_contains "$out" ITRAN "exec ran the command anyway"
  assert_no_violations "exec"
  pass "exec passes the credential to exactly one child, stands aside, or refuses to run"
}

# The snippet a worker's shell evaluates: the right credential on success, and an
# unusable one on failure, so the shell cannot keep operating as another account.
test_env_snippet_fails_closed_in_the_shell() {
  local rec out status
  rec=$(new_case env-snippet git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"

  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' env --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "env should succeed for a resolvable repository"
  [ "$out" = "export GH_TOKEN='ghtoken-davidx-secco'" ] \
    || fail "env snippet was '$out'"

  out=$(run_gha 'daveonthegit davidx-secco' '' env --dir "$REPO_DIR" 2>/dev/null)
  status=$?
  expect_code 1 "$status" "env should report an undeterminable account"
  assert_contains "$out" "export GH_TOKEN='fm-gh-account-unresolved'" \
    "failed env snippet left the shell free to use another account"

  out=$(FM_GH_ACCOUNT=none run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' env --dir "$REPO_DIR")
  status=$?
  expect_code 3 "$status" "an opted-out lane should get no snippet"
  [ -z "$out" ] || fail "opted-out lane received a snippet: $out"
  pass "the evaluated snippet carries the right credential, or an unusable one that fails loudly"
}

# --- spawn integration ------------------------------------------------------
#
# A real fm-spawn run against a fake tmux, so the assertions cover what the
# worker's own shell receives and what the durable record keeps.

make_spawn_case() {  # <name> <id> <origin>
  local name=$1 id=$2 origin=$3 dir home proj wt fakebin log
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  log="$dir/gh.log"
  fakebin=$(make_fake_gh "$dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?FM_FAKE_TMUX_LOG unset}"; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" remote add origin "$origin"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  : > "$log"
  printf '%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$proj" "$wt" "$fakebin" "$log"
}

read_spawn_case() {  # <record>
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LOG <<EOF
$1
EOF
  SENT_LOG="$CASE_DIR/tmux.log"
  : > "$SENT_LOG"
}

run_spawn() {  # <id> <accounts> <access>
  local id=$1 accounts=$2 access=$3
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$SENT_LOG" \
    FM_FAKE_GH_ACCOUNTS="$accounts" FM_FAKE_GH_ACCESS="$access" FM_FAKE_GH_LOG="$LOG" \
    PATH="$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1
}

# The end state the whole change exists for: the lane's own shell is handed the
# account that repository needs, the durable record says which one, and global gh
# state was never touched.
test_spawn_hands_the_lane_its_own_account() {
  local rec id out status
  while IFS='|' read -r name id origin accounts access want; do
    [ -n "$name" ] || continue
    rec=$(make_spawn_case "$name" "$id" "$origin")
    read_spawn_case "$rec"
    out=$(run_spawn "$id" "$accounts" "$access")
    status=$?
    expect_code 0 "$status" "$name: spawn failed: $out"
    assert_grep "gh_account=$want" "$HOME_DIR/state/$id.meta" \
      "$name: durable record does not name the selected account"
    assert_grep "env --account '$want'" "$SENT_LOG" \
      "$name: the worker's shell was not given the selected account"
    assert_no_grep "GH_TOKEN='ghtoken" "$SENT_LOG" \
      "$name: a credential was typed into the worker's pane"
    assert_no_violations "$name"
  done <<'ROWS'
spawn-org|gh-spawn-org-z1|git@github.com:BG-Media-LLC/vsl-funnel.git|daveonthegit davidx-secco|davidx-secco=50|davidx-secco
spawn-personal|gh-spawn-personal-z2|git@github.com:daveonthegit/Kyarafit.git|daveonthegit davidx-secco|daveonthegit=50|daveonthegit
ROWS
  pass "a spawned lane operates as the account its own repository needs, recorded and never switched globally"
}

# A single-account home spawns exactly as it did before this selection existed.
test_spawn_without_a_choice_is_unchanged() {
  local rec id out status
  id=gh-spawn-single-z3
  rec=$(make_spawn_case spawn-single "$id" git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_spawn_case "$rec"
  out=$(run_spawn "$id" 'davidx-secco' 'davidx-secco=50')
  status=$?
  expect_code 0 "$status" "single-account spawn failed: $out"
  assert_no_grep gh_account= "$HOME_DIR/state/$id.meta" \
    "a home with nothing to choose recorded an account anyway"
  assert_no_grep fm-gh-account.sh "$SENT_LOG" \
    "a home with nothing to choose still touched the worker's credentials"
  pass "a home with one logged-in account spawns exactly as it did before"
}

# An undeterminable account stops the lane at dispatch, before any window or
# durable record exists, rather than surfacing as a forge error mid-pipeline.
test_spawn_refuses_an_undeterminable_account() {
  local rec id out status
  id=gh-spawn-refuse-z4
  rec=$(make_spawn_case spawn-refuse "$id" git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_spawn_case "$rec"
  out=$(run_spawn "$id" 'daveonthegit davidx-secco' '')
  status=$?
  [ "$status" -ne 0 ] || fail "spawn continued without knowing which account to use"
  assert_contains "$out" "cannot select the GitHub account" "refusal is not stated"
  assert_contains "$out" "FM_GH_ACCOUNT=none" "refusal does not offer the opt-out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn still published a durable record"
  assert_no_grep send-keys "$SENT_LOG" "a refused spawn still drove the worker's shell"
  assert_no_violations "refused spawn"
  pass "a spawn with no determinable account stops at dispatch with the reason and its fix"
}

test_both_accounts_resolve_from_the_repository
test_origin_forms_and_other_forges
test_nothing_to_choose_leaves_gh_alone
test_undeterminable_account_fails_closed
test_recorded_mapping_wins
test_per_invocation_override
test_exec_lends_the_credential_to_one_child
test_env_snippet_fails_closed_in_the_shell
test_spawn_hands_the_lane_its_own_account
test_spawn_without_a_choice_is_unchanged
test_spawn_refuses_an_undeterminable_account

echo "# all fm-gh-account tests passed"
