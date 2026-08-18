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
    # A gh that reports a logged-in account in wording this repo cannot parse:
    # a different locale, an older gh, or a future rewording.
    if [ "${FM_FAKE_GH_STATUS_UNPARSEABLE:-0}" = 1 ]; then
      printf 'github.com\n  x Angemeldet bei github.com als daveonthegit (keyring)\n'
      exit 0
    fi
    # A home logged in to a GitHub Enterprise host only: gh exits 0, and there is
    # no github.com account anywhere in the output to get wrong. The value names
    # the host, so a hostname that merely contains "github.com" is covered too,
    # and gh's own documentation hint is printed alongside it.
    if [ "${FM_FAKE_GH_ENTERPRISE_ONLY:-0}" != 0 ]; then
      ghe_host=$FM_FAKE_GH_ENTERPRISE_ONLY
      [ "$ghe_host" = 1 ] && ghe_host=git.example.com
      printf '%s\n  x Logged in to %s account someone (keyring)\n' "$ghe_host" "$ghe_host"
      printf '  - See https://docs.github.com/en/authentication for details\n'
      exit 0
    fi
    # Real gh exits non-zero when nobody is logged in anywhere, which is what
    # tells this repo that an empty list means "nothing to select" rather than
    # "output this repo could not read".
    if [ -z "${FM_FAKE_GH_ACCOUNTS:-}" ]; then
      printf 'You are not logged into any GitHub hosts. To log in, run: gh auth login\n' >&2
      exit 1
    fi
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
# Any other command stands in for real work, and records the identity it ran as
# so a wrapper's pass-through and injection are both observable.
case "${GH_TOKEN:-}" in
  ghtoken-*) printf 'AS %s\n' "${GH_TOKEN#ghtoken-}" >> "$log" ;;
  '') printf 'AS active\n' >> "$log" ;;
  *) printf 'AS unusable\n' >> "$log" ;;
esac
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
https-port|https://github.com:443/BG-Media-LLC/vsl-funnel.git|davidx-secco
gitlab|git@gitlab.com:BG-Media-LLC/vsl-funnel.git|3
self-hosted|https://git.example.com/BG-Media-LLC/vsl-funnel.git|3
ROWS
  rec=$(new_case form-no-origin)
  read_case "$rec"
  out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  expect_code 3 "$?" "a checkout with no origin should select nothing"
  pass "every github.com origin form resolves alike; other forges and originless checkouts select nothing"
}

# A GitHub login may be all digits, and an owner that looks like an ssh port must
# still reach the probe as the owner rather than being dropped as one.
test_numeric_owner_is_not_mistaken_for_a_port() {
  local rec out status
  while IFS='|' read -r name origin; do
    [ -n "$name" ] || continue
    rec=$(new_case "numeric-$name" "$origin")
    read_case "$rec"
    out=$(run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
    status=$?
    expect_code 0 "$status" "$name: a numeric owner should resolve like any other"
    [ "$out" = davidx-secco ] || fail "$name: resolved to '$out', wanted davidx-secco"
    assert_grep 'gh api repos/12345/vsl-funnel' "$LOG" \
      "$name: the probe did not ask about the repository the origin names"
  done <<'ROWS'
https|https://github.com/12345/vsl-funnel.git
scp|git@github.com:12345/vsl-funnel.git
ssh-url|ssh://git@github.com:22/12345/vsl-funnel.git
ROWS
  pass "an all-numeric owner survives the ssh-port handling instead of silently selecting nothing"
}

# gh reporting a login in wording this repo cannot read is not the same as nobody
# being logged in: it means the account cannot be determined, and guessing there
# is the wrong-identity failure this whole selection exists to prevent.
test_unparseable_auth_status_refuses() {
  local rec out status
  rec=$(new_case unparseable git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(FM_FAKE_GH_STATUS_UNPARSEABLE=1 run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' \
    resolve --dir "$REPO_DIR")
  status=$?
  expect_code 1 "$status" "an unreadable 'gh auth status' must fail closed, not fall back"
  assert_contains "$out" "no logged-in login could be read" "the parse failure is not explained"
  assert_contains "$out" "FM_GH_ACCOUNT" "the refusal does not offer the override"
  assert_no_probe "unparseable auth status"

  # An opted-out lane still needs nothing, so it is unaffected by the refusal.
  out=$(FM_FAKE_GH_STATUS_UNPARSEABLE=1 FM_GH_ACCOUNT=none \
    run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  expect_code 3 "$?" "FM_GH_ACCOUNT=none should still select nothing"

  # The override the refusal names has to actually work, and it is the only thing
  # an unreadable list cannot contradict.
  out=$(FM_FAKE_GH_STATUS_UNPARSEABLE=1 FM_GH_ACCOUNT=davidx-secco \
    run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' resolve --dir "$REPO_DIR")
  status=$?
  expect_code 0 "$status" "the named override should resolve despite an unreadable list"
  [ "$out" = davidx-secco ] || fail "the override resolved to '$out'"

  # No github.com repository to select for means no identity was ever needed, so
  # such a lane is not refused even where the list cannot be read.
  rec=$(new_case unparseable-gitlab git@gitlab.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(FM_FAKE_GH_STATUS_UNPARSEABLE=1 run_gha 'daveonthegit davidx-secco' '' resolve --dir "$REPO_DIR")
  expect_code 3 "$?" "a non-GitHub checkout must not be refused over an unreadable list"

  rec=$(new_case unparseable-no-origin)
  read_case "$rec"
  out=$(FM_FAKE_GH_STATUS_UNPARSEABLE=1 run_gha 'daveonthegit davidx-secco' '' resolve --dir "$REPO_DIR")
  expect_code 3 "$?" "an originless checkout must not be refused over an unreadable list"
  pass "an unreadable 'gh auth status' refuses only where an account was needed, and its override works"
}

# A home logged in to a GitHub Enterprise host only has no github.com account to
# get wrong, so it must keep behaving exactly as it did before this selection
# existed rather than being refused.
test_enterprise_only_home_is_untouched() {
  local rec out host
  # The second host merely contains "github.com" in its name, and both outputs
  # carry a docs.github.com hint: neither is github.com being authenticated.
  for host in 1 github.company.com; do
    rec=$(new_case "enterprise-only-$host" git@github.com:BG-Media-LLC/vsl-funnel.git)
    read_case "$rec"
    out=$(FM_FAKE_GH_ENTERPRISE_ONLY="$host" run_gha 'daveonthegit davidx-secco' 'davidx-secco=50' \
      resolve --dir "$REPO_DIR")
    expect_code 3 "$?" "$host: an enterprise-only home should select nothing (output: $out)"
    [ -z "$out" ] || fail "$host: an enterprise-only home produced output: $out"
    assert_no_probe "enterprise-only home $host"
  done
  pass "a home logged in to another host only is left exactly as it was, whatever that host is called"
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
  # fm_git_worktree seeds its own local bare origin, so point that existing
  # remote at the forge URL under test rather than adding a second one.
  git -C "$proj" remote set-url origin "$origin"
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
  # Whether a gh call enters the wrapper decides how a lane gets its identity, and
  # fm-install-gh-shim.sh answers that from $HOME and from PATH, so every spawn
  # case owns both instead of inheriting whatever this machine has installed.
  SPAWN_HOME="$CASE_DIR/fakehome"
  SPAWN_PATH_PREFIX=
  mkdir -p "$SPAWN_HOME"
}

MARKER='# fm-gh-shim: installed by bin/fm-install-gh-shim.sh'

# A wrapper installed at the default target that no PATH lookup reaches, which
# corrects nothing at all.
install_shim_off_path() {
  mkdir -p "$SPAWN_HOME/.local/bin"
  {
    printf '#!/bin/sh\n'
    printf '%s\n' "$MARKER"
    printf 'exit 0\n'
  } > "$SPAWN_HOME/.local/bin/gh"
  chmod +x "$SPAWN_HOME/.local/bin/gh"
}

# A wrapper installed somewhere other than the default target that a gh call does
# reach: the fake gh's own behavior plus the wrapper's marker, so resolution still
# works while gh resolves to a wrapper.
install_shim_in_path() {
  local dir="$CASE_DIR/shimbin"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$MARKER"
    tail -n +2 "$FAKEBIN/gh"
  } > "$dir/gh"
  chmod +x "$dir/gh"
  SPAWN_PATH_PREFIX="$dir"
}

run_spawn() {  # <id> <accounts> <access>
  local id=$1 accounts=$2 access=$3
  HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_TMUX_LOG="$SENT_LOG" \
    FM_FAKE_GH_ACCOUNTS="$accounts" FM_FAKE_GH_ACCESS="$access" FM_FAKE_GH_LOG="$LOG" \
    PATH="${SPAWN_PATH_PREFIX:+$SPAWN_PATH_PREFIX:}$FAKEBIN:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude --mode no-mistakes --yolo off 2>&1
}

# The end state the whole change exists for, in a home without the gh wrapper:
# the lane's own shell is handed the account that repository needs, the durable
# record says which one, and global gh state was never touched.
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

# Where the wrapper is installed it keys every call off the repository that call
# names, so the lane must not also be pinned to one account: a lane-wide
# credential would win over the wrapper and make a call against the other
# account's repository run as this lane's account instead.
test_spawn_leaves_the_credential_to_the_wrapper() {
  local rec id out status
  id=gh-spawn-wrapper-z5
  rec=$(make_spawn_case spawn-wrapper "$id" git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_spawn_case "$rec"
  # Installed away from the default target, but ahead of the real gh.
  install_shim_in_path
  out=$(run_spawn "$id" 'daveonthegit davidx-secco' 'davidx-secco=50')
  status=$?
  expect_code 0 "$status" "spawn with the wrapper in effect failed: $out"
  assert_grep "gh_account=davidx-secco" "$HOME_DIR/state/$id.meta" \
    "the durable record stopped naming the selected account"
  assert_no_grep fm-gh-account.sh "$SENT_LOG" \
    "the lane was pinned to one account even though the wrapper re-keys per repository"
  assert_no_grep GH_TOKEN "$SENT_LOG" "a credential was sent into the worker's pane"
  assert_no_violations "wrapper-in-effect spawn"
  pass "where a gh call enters the wrapper a lane exports nothing and keeps per-repository keying"
}

# The other direction: a wrapper that exists but that no gh call reaches corrects
# nothing, so the lane still needs its own credential. Trusting the file alone
# would leave such a home with neither mechanism.
test_spawn_exports_when_the_wrapper_is_not_reached() {
  local rec id out status
  id=gh-spawn-offpath-z6
  rec=$(make_spawn_case spawn-offpath "$id" git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_spawn_case "$rec"
  install_shim_off_path
  out=$(run_spawn "$id" 'daveonthegit davidx-secco' 'davidx-secco=50')
  status=$?
  expect_code 0 "$status" "spawn with an unreachable wrapper failed: $out"
  assert_grep "env --account 'davidx-secco'" "$SENT_LOG" \
    "a lane whose gh calls never enter the wrapper was left with no identity at all"
  assert_no_grep "GH_TOKEN='ghtoken" "$SENT_LOG" \
    "a credential was typed into the worker's pane"
  assert_no_violations "unreachable-wrapper spawn"
  pass "an installed wrapper nothing resolves to still leaves the lane its own credential"
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

# --- the gh wrapper --------------------------------------------------------
#
# The wrapper exists for calls this repo does not launch, above all no-mistakes'
# shared daemon. It shadows gh for everything on the machine, so the assertions
# below are as much about what it leaves alone as about what it corrects.

SHIM="$ROOT/bin/fm-gh-shim.sh"
INSTALLER="$ROOT/bin/fm-install-gh-shim.sh"

# run_shim <accounts> <access> <cwd> <args...>
run_shim() {
  local accounts=$1 access=$2 cwd=$3
  shift 3
  ( cd "$cwd" && FM_CONFIG_OVERRIDE="$CASE_DIR/config" \
      FM_GH_REAL="$FAKEBIN/gh" FM_GH_ACCOUNT_BIN="$GHA" \
      FM_FAKE_GH_ACCOUNTS="$accounts" FM_FAKE_GH_ACCESS="$access" \
      FM_FAKE_GH_LOG="$LOG" \
      PATH="$FAKEBIN:$PATH" \
      "$SHIM" "$@" 2>&1 )
}

assert_ran_as() {  # <login|active> <label>
  assert_grep "AS $1" "$LOG" "$2: the wrapper did not run gh as $1"
}

# Every command whose subject is the account, the local install, or help must
# reach gh exactly as it always did - manual "gh auth" work depends on it.
test_shim_leaves_gh_alone_where_it_must() {
  local rec out
  rec=$(new_case shim-passthrough git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  while IFS='|' read -r label args; do
    [ -n "$label" ] || continue
    : > "$LOG"
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" $args)
    expect_code 0 "$?" "$label: should pass through cleanly"
    assert_no_grep 'AS davidx-secco' "$LOG" "$label: the wrapper injected an account it should not have"
    assert_no_grep 'gh api repos' "$LOG" "$label: the wrapper resolved an account it should not have"
    assert_not_contains "$out" ghtoken "$label: a credential reached the output"
  done <<'ROWS'
auth status|auth status
config get|config get git_protocol
gh with no arguments|
help flag on a repository command|pr list --help
help flag after a positional argument|pr view 123 -h
version flag|--version
another host by flag|pr list --hostname git.example.com
bare repository name|pr list --repo justaname
ROWS
  : > "$LOG"
  out=$(GH_HOST=git.example.com run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" pr list)
  expect_code 0 "$?" "GH_HOST elsewhere: should pass through"
  assert_no_grep 'AS davidx-secco' "$LOG" "GH_HOST elsewhere: the wrapper still injected an account"

  # "gh auth token" prints a credential by design, so it is asserted on its own:
  # it must reach gh untouched, which is also what keeps account resolution from
  # re-entering this wrapper.
  : > "$LOG"
  out=$(run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" auth token --user daveonthegit)
  expect_code 0 "$?" "auth token: should pass through"
  [ "$out" = ghtoken-daveonthegit ] || fail "auth token did not reach gh untouched: $out"
  assert_no_grep 'gh api repos' "$LOG" "auth token triggered account resolution"
  pass "the wrapper passes account, config, help, and other-host commands straight to gh"
}

# An explicit credential always wins, which is also what keeps the account
# probes from re-entering the wrapper.
test_shim_never_overrides_an_explicit_credential() {
  local rec
  rec=$(new_case shim-explicit-token git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  GH_TOKEN=ghtoken-daveonthegit run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" \
    pr list >/dev/null
  expect_code 0 "$?" "an explicit credential should pass through"
  assert_ran_as daveonthegit "explicit credential"
  assert_no_grep 'gh api repos' "$LOG" "the wrapper resolved despite an explicit credential"
  pass "a call that already carries a credential is never re-pointed at another account"
}

# The correction itself, from both sides, plus an explicit --repo outranking the
# directory the call happens to run in.
test_shim_runs_repository_work_as_its_own_account() {
  local rec
  rec=$(new_case shim-org git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" pr list >/dev/null
  expect_code 0 "$?" "org repository work should run"
  assert_ran_as davidx-secco "org repository"

  : > "$LOG"
  run_shim 'daveonthegit davidx-secco' 'daveonthegit=50 davidx-secco=10' "$REPO_DIR" \
    pr list --repo daveonthegit/Kyarafit >/dev/null
  expect_code 0 "$?" "explicit repository work should run"
  assert_ran_as daveonthegit "explicit --repo"

  : > "$LOG"
  rec=$(new_case shim-gitlab git@gitlab.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" pr list >/dev/null
  assert_ran_as active "another forge"

  : > "$LOG"
  run_shim 'davidx-secco' 'davidx-secco=50' "$REPO_DIR" pr list >/dev/null
  assert_ran_as active "single account"
  assert_no_violations "wrapper"
  pass "repository work runs as that repository's own account; nothing to choose leaves gh alone"
}

# Every form in which a call names its own repository outranks the directory it
# happens to run in, and an argument that only looks like a help flag does not
# hand the call to whichever account is active.
test_shim_keys_off_every_named_repository() {
  local rec
  rec=$(new_case shim-named git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"

  # pflag accepts a shorthand's value attached to it.
  run_shim 'daveonthegit davidx-secco' 'daveonthegit=50 davidx-secco=10' "$REPO_DIR" \
    pr list -Rdaveonthegit/Kyarafit >/dev/null
  expect_code 0 "$?" "an attached -R value should run"
  assert_ran_as daveonthegit "attached -R"

  # A value that reads like a help flag is a value, not a request for help.
  : > "$LOG"
  run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" \
    pr comment 7 --body -v >/dev/null
  expect_code 0 "$?" "a repository command whose value looks like a flag should run"
  assert_ran_as davidx-secco "help-looking flag value"

  # gh api names its repository in the endpoint path instead of --repo.
  : > "$LOG"
  run_shim 'daveonthegit davidx-secco' 'daveonthegit=50 davidx-secco=10' "$REPO_DIR" \
    api repos/daveonthegit/Kyarafit/pulls >/dev/null
  expect_code 0 "$?" "an api call naming a repository should run"
  assert_grep 'gh api repos/daveonthegit/Kyarafit/pulls' "$LOG" \
    "the api call itself never reached gh"
  assert_no_grep 'repos/BG-Media-LLC/vsl-funnel' "$LOG" \
    "the api call was keyed off the directory instead of the repository it names"

  : > "$LOG"
  run_shim 'daveonthegit davidx-secco' 'daveonthegit=50 davidx-secco=10' "$REPO_DIR" \
    api https://api.github.com/repos/daveonthegit/Kyarafit >/dev/null
  assert_no_grep 'repos/BG-Media-LLC/vsl-funnel' "$LOG" \
    "an absolute api URL was keyed off the directory instead of the repository it names"

  # gh expands its own {owner}/{repo} placeholders from the working directory, so
  # such a path stays keyed off that directory.
  : > "$LOG"
  run_shim 'daveonthegit davidx-secco' 'davidx-secco=50' "$REPO_DIR" \
    api 'repos/{owner}/{repo}/pulls' >/dev/null
  expect_code 0 "$?" "a placeholder api path should run"
  assert_grep 'repos/BG-Media-LLC/vsl-funnel' "$LOG" \
    "a placeholder api path was not keyed off the working directory"
  assert_no_violations "named repositories"
  pass "an attached -R, an api endpoint path, and a flag-looking value are all keyed off the right repository"
}

# Refusals: an undeterminable account, and a helper this repo can no longer
# reach while more than one account is logged in.
test_shim_refuses_rather_than_guessing() {
  local rec out status
  rec=$(new_case shim-refuse git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  out=$(run_shim 'daveonthegit davidx-secco' '' "$REPO_DIR" pr list)
  status=$?
  [ "$status" -ne 0 ] || fail "the wrapper ran gh without knowing which account to use"
  assert_no_grep 'AS ' "$LOG" "the wrapper ran gh anyway"
  assert_contains "$out" "not running gh as an unintended account" "refusal is not stated"
  assert_contains "$out" "remove this wrapper" "refusal does not say how to undo the wrapper"

  # Which account a help request runs as cannot change its output, and flag arity
  # is not knowable here, so a help flag anywhere prints gh's own help rather than
  # turning into a refusal plain gh would never have produced.
  : > "$LOG"
  out=$(run_shim 'daveonthegit davidx-secco' '' "$REPO_DIR" pr list --draft --help)
  expect_code 0 "$?" "a help request must print help rather than be refused: $out"
  assert_ran_as active "help request on the refusal path"
  assert_not_contains "$out" "not running gh as an unintended account" \
    "a help request was refused instead of passed through"

  : > "$LOG"
  out=$( cd "$REPO_DIR" && FM_GH_REAL="$FAKEBIN/gh" FM_GH_ACCOUNT_BIN="$CASE_DIR/gone.sh" \
    FM_FAKE_GH_ACCOUNTS='daveonthegit davidx-secco' FM_FAKE_GH_LOG="$LOG" \
    PATH="$FAKEBIN:$PATH" "$SHIM" pr list 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "an unreachable helper with two accounts should refuse"
  assert_contains "$out" "unreachable" "unreachable-helper refusal is not explained"
  assert_no_grep 'AS ' "$LOG" "the wrapper ran gh with no way to choose an account"

  : > "$LOG"
  out=$( cd "$REPO_DIR" && FM_GH_REAL="$FAKEBIN/gh" FM_GH_ACCOUNT_BIN="$CASE_DIR/gone.sh" \
    FM_FAKE_GH_ACCOUNTS='davidx-secco' FM_FAKE_GH_LOG="$LOG" \
    PATH="$FAKEBIN:$PATH" "$SHIM" pr list 2>&1 )
  expect_code 0 "$?" "an unreachable helper with one account should pass through: $out"
  assert_ran_as active "unreachable helper, one account"
  pass "an undeterminable account is refused, and an unreachable helper refuses only when a wrong account is possible"
}

# Installing is reversible and never touches a gh this repo did not write.
test_installer_is_reversible_and_careful() {
  local rec target out installed status
  rec=$(new_case installer git@github.com:BG-Media-LLC/vsl-funnel.git)
  read_case "$rec"
  target="$CASE_DIR/bin"

  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --target "$target" 2>&1)
  expect_code 0 "$?" "install failed: $out"
  installed="$target/gh"
  assert_present "$installed" "the wrapper was not installed"
  [ -x "$installed" ] || fail "the installed wrapper is not executable"
  assert_grep 'fm-gh-shim: installed by' "$installed" "the installed wrapper carries no marker"
  assert_no_grep '__FM_GH_ACCOUNT_BIN__' "$installed" "the installed wrapper kept its placeholder"
  assert_grep "$ROOT/bin/fm-gh-account.sh" "$installed" "the installed wrapper does not point at the helper"

  # Reinstalling refreshes in place, and the copy stays the tracked wrapper apart
  # from that one substituted line.
  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --target "$target" 2>&1)
  expect_code 0 "$?" "reinstall failed: $out"
  [ "$(diff "$SHIM" "$installed" | grep -c '^[<>]')" -eq 2 ] \
    || fail "the installed wrapper differs from the tracked one beyond the substituted path"

  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --check --target "$target" 2>&1)
  assert_contains "$out" "installed: $installed" "--check does not report the install"
  # What decides whether the wrapper corrects anything is which gh a call reaches,
  # not whether a copy exists, so --check answers that question too.
  assert_contains "$out" "in effect: no" "--check calls a wrapper no gh lookup reaches effective"
  out=$(PATH="$target:$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --check --target "$target" 2>&1)
  assert_contains "$out" "in effect: yes" "--check does not report a wrapper a gh lookup does reach"

  # A machine-wide wrapper must not record a path that disappears with a task
  # worktree, so installing from one is refused on its own.
  out=$(PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$CASE_DIR/not-a-checkout" "$INSTALLER" --target "$target" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install accepted a root that will not outlive it"
  assert_contains "$out" "not a durable checkout" "the durable-checkout refusal is not explained"

  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --uninstall --target "$target" 2>&1)
  expect_code 0 "$?" "uninstall failed: $out"
  assert_absent "$installed" "uninstall left the wrapper behind"

  # A gh this repo did not write is never replaced or removed.
  printf '#!/bin/sh\nexit 0\n' > "$installed"
  chmod +x "$installed"
  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --target "$target" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install replaced a gh it did not write"
  assert_contains "$out" "not written by this repo" "install refusal is not explained"
  out=$(PATH="$FAKEBIN:$PATH" FM_GH_SHIM_ALLOW_LINKED_WORKTREE=1 "$INSTALLER" --uninstall --target "$target" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "uninstall removed a gh it did not write"
  assert_present "$installed" "uninstall deleted a foreign gh"
  pass "installing is idempotent and reversible, and a foreign gh is never replaced or removed"
}

test_both_accounts_resolve_from_the_repository
test_origin_forms_and_other_forges
test_numeric_owner_is_not_mistaken_for_a_port
test_unparseable_auth_status_refuses
test_enterprise_only_home_is_untouched
test_nothing_to_choose_leaves_gh_alone
test_undeterminable_account_fails_closed
test_recorded_mapping_wins
test_per_invocation_override
test_exec_lends_the_credential_to_one_child
test_env_snippet_fails_closed_in_the_shell
test_spawn_hands_the_lane_its_own_account
test_spawn_leaves_the_credential_to_the_wrapper
test_spawn_exports_when_the_wrapper_is_not_reached
test_spawn_without_a_choice_is_unchanged
test_spawn_refuses_an_undeterminable_account
test_shim_leaves_gh_alone_where_it_must
test_shim_never_overrides_an_explicit_credential
test_shim_runs_repository_work_as_its_own_account
test_shim_keys_off_every_named_repository
test_shim_refuses_rather_than_guessing
test_installer_is_reversible_and_careful

echo "# all fm-gh-account tests passed"
