#!/usr/bin/env bash
#
# The pane in a real thurbox, driven from a real terminal.
#
#   THURBOX_BIN=/path/to/thurbox/target/debug tests/e2e.sh
#
# THURBOX_BIN holds `thurbox` and `thurbox-cli` from a release with the
# automation create/edit commands. Everything runs in a profile made for the
# purpose — HOME, XDG, thurbox's config and data, and a private tmux socket
# directory — so no real session, automation or interface is read or touched.
# The automations it seeds run harmless `printf`/`exit` commands inside that
# profile. Screens are kept under .cache/e2e/ for inspection; the README's
# screenshots come from them.
#
# Needs tmux and git. It installs HEAD: commit before running it.
#
# RECORD=media/demo.gif also records the run with asciinema and renders it
# with agg (both then needed); the narrow-terminal step is left out of a
# recording, since a cast keeps the size it started at.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(cd "${THURBOX_BIN:?set THURBOX_BIN to a directory holding thurbox and thurbox-cli}" && pwd)"
root="$HERE/.cache/e2e"
rm -rf "$root"
mkdir -p "$root"/{home,config,data,cache,state,xdg-config,xdg-data,screens}

# A socket path must stay under ~100 bytes, so the tmux directory is short and
# separate. It is removed, servers and all, however the script ends.
sockets="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tbxa.XXXXXX")"
cleanup() {
  for socket in "$sockets"/tmux-*/*; do
    [ -S "$socket" ] && tmux -S "$socket" kill-server >/dev/null 2>&1 || true
  done
  rm -rf "$sockets"
}
trap cleanup EXIT

export HOME="$root/home"
export XDG_CONFIG_HOME="$root/xdg-config" XDG_DATA_HOME="$root/xdg-data"
export XDG_CACHE_HOME="$root/cache" XDG_STATE_HOME="$root/state"
export THURBOX_CONFIG_DIR="$root/config" THURBOX_DATA_DIR="$root/data"
export THURBOX_SOCKET="tbxa-e2e" TMUX_TMPDIR="$sockets" TERM=xterm-256color
export PATH="$BIN:$PATH"
unset TMUX THURBOX_SOCKET_FOR THURBOX_UI_DIR NO_COLOR
for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR; do
  unset "$var"
done

cat >"$THURBOX_CONFIG_DIR/settings.toml" <<'TOML'
[features]
version_check = false
auto_update = false
TOML

cli() { thurbox-cli "$@"; }
json() { thurbox-cli "$@" --json; }
fail() {
  echo "FAIL: $*" >&2
  tmux -L e2e capture-pane -p -t e2e >&2 || true
  exit 1
}
pass() { echo "ok   $*"; }

# ── the plugin, installed as the README says ───────────────────────────────
git clone --quiet "$HERE" "$root/thurbox-automations"
cli plugin install "git+file://$root/thurbox-automations" --text >/dev/null
cli plugin check --text >/dev/null || fail "plugin check"
pass "installed and checked in the isolated profile"

# ── automations to manage, with a run history ──────────────────────────────
# A neutral path rather than one under this profile, so no screen or recording
# carries the machine's own home directory. Nothing spawns there: the
# automation fires on weekdays at 09:00 UTC, long after this script is done.
cli automation create --name nightly-review --trigger weekdays --time 09:00 \
  --timezone UTC --repo /home/user/src/app --worktree auto/review \
  --prompt "Review open pull requests and summarise them" --disabled >/dev/null
cli automation create --name sync-tasks --trigger "cron:0 0 1 1 *" \
  --command "printf 'synced 3 tasks'" >/dev/null
cli automation create --name flaky-export --trigger "cron:0 0 1 1 *" \
  --command "echo 'export failed: connection refused' >&2; exit 2" >/dev/null
id_of() { json automation list | python3 -c "import json,sys; print(next(a['id'] for a in json.load(sys.stdin) if a['name']==sys.argv[1]))" "$1"; }
field_of() { json automation show "$1" | python3 -c "import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print('' if v is None else v)" "$2"; }
cli automation run "$(id_of sync-tasks)" >/dev/null
cli automation run "$(id_of flaky-export)" >/dev/null
cli automation tick >/dev/null

# ── the TUI, in a terminal tmux holds ──────────────────────────────────────
if [ -n "${RECORD:-}" ]; then
  tmux -L e2e new-session -d -s e2e -x 120 -y 34 \
    "asciinema rec --quiet --overwrite -c thurbox '$root/demo.cast'"
  pause() { sleep 1.2; }
else
  tmux -L e2e new-session -d -s e2e -x 140 -y 40 "thurbox"
  pause() { :; }
fi
screen() { tmux -L e2e capture-pane -p -t e2e; }
keys() { tmux -L e2e send-keys -t e2e "$@"; }
type_text() { tmux -L e2e send-keys -t e2e -l "$1"; }
wait_for() {
  local what="$1" tries="${2:-60}"
  for _ in $(seq "$tries"); do
    if screen | grep -qF -- "$what"; then
      return 0
    fi
    sleep 0.25
  done
  fail "never saw: $what"
}
wait_cli() {
  local why="$1"
  shift
  for _ in $(seq 60); do
    if "$@"; then
      return 0
    fi
    sleep 0.25
  done
  fail "$why"
}
keep() { screen >"$root/screens/$1.txt"; }
select_by_filter() {
  keys /
  type_text "$1"
  keys Enter
  sleep 0.5
}
clear_filter() {
  keys Escape
  sleep 0.3
}

wait_for "Automations" 120
keys M-a
wait_for "flaky-export"
wait_for "connection refused"
pause
pass "alt+a opens the pane; the failed run and its output are shown"
keep normal

# Narrow: the list stacks over the detail.
if [ -z "${RECORD:-}" ]; then
  tmux -L e2e resize-window -t e2e -x 72 -y 40
  sleep 1
  keep narrow
  screen | grep -qF "flaky-export" || fail "narrow view lost the list"
  tmux -L e2e resize-window -t e2e -x 140 -y 40
  sleep 1
  pass "narrow view renders"
fi

# Run history: the failed run's whole detail, filtered to errors.
select_by_filter flaky-export
keys Tab
wait_for "exit 2: export failed"
keys f
wait_for "errors only"
keep runs
pause
keys f f Tab
clear_filter
pass "run history filters to errors and shows the run's detail"

# Untrusted, an exec automation's command is not written — the pane says how
# to trust it, and thurbox would refuse it anyway.
keys n
wait_for "New automation"
type_text "untrusted-exec"
keys Tab Right Right Tab
type_text "daily"
keys Tab Tab Tab Tab
type_text "printf no"
keys Enter
wait_for "needs this pane trusted"
keep untrusted
keys Escape
json automation list | grep -q '"untrusted-exec"' && fail "an untrusted pane wrote an exec automation"
pass "untrusted, an exec command is refused with the way to trust the pane"

# Trust it the way a user does: settings → Interface → t on its row.
keys F6
wait_for "Settings"
keys "]"
wait_for "30_automations.lua"
for _ in $(seq 30); do
  screen | grep -qE "▸ . thurbox-automations/plugins/30_automations.lua" && break
  keys j
  sleep 0.1
done
keys t
wait_for "trusted · from thurbox-automations"
keys Escape
sleep 0.5
keys M-a
wait_for "Automations ("
pass "trusted through settings → Interface"

# Create an exec automation through the form.
keys n
wait_for "New automation"
type_text "e2e-created"
keys Tab Right Right Tab
type_text "daily"
keys Tab
type_text "06:30"
keys Tab Tab
type_text "UTC"
keys Tab
type_text "printf hello"
sleep 0.5
keep form
pause
keys Enter
wait_for "saved e2e-created"
pause
created="$(id_of e2e-created)"
[ "$(field_of "$created" schedule)" != "" ] || fail "created automation has no schedule"
[ -n "$(field_of "$created" next_run_at)" ] || fail "created automation is not scheduled"
pass "created through the form, scheduled by the host"

# An invalid schedule keeps the form open with the host's reason.
keys n
type_text "broken"
keys Tab Right Right Tab
type_text "cron:61 * * * *"
keys Tab Tab Tab Tab
type_text "true"
keys Enter
wait_for "invalid cron expression"
keep invalid
pause
keys Escape
json automation list | grep -q '"broken"' && fail "an invalid automation was stored"
pass "an invalid schedule is refused and explained"

# Enable a disabled automation: it must be scheduled again.
select_by_filter nightly-review
keys Space
nightly="$(id_of nightly-review)"
wait_cli "enabled from the pane but not scheduled" \
  sh -c "[ \"\$(thurbox-cli automation show $nightly --json | python3 -c 'import json,sys; a=json.load(sys.stdin); print(a[\"enabled\"] and a.get(\"next_run_at\") is not None)')\" = True ]"
pass "enabling schedules the next run"

# Edit keeps the target.
keys e
wait_for "Edit automation"
# Ctrl+U is thurbox's global restore chord, so a field is emptied with
# backspace (or word by word with Ctrl+W).
for _ in $(seq 20); do keys BSpace; done
type_text "morning-review"
keys Enter
wait_for "saved morning-review"
json automation show "$nightly" | grep -q "auto/review" || fail "the edit lost the target"
clear_filter
pass "edit renames and keeps the spawn target"

# Run now: due, then fired by a tick, then in the history.
select_by_filter sync-tasks
keys r
wait_for "heartbeat fires it"
cli automation tick >/dev/null
wait_for "2 runs"
clear_filter
pass "run now marks it due; the tick fires it; the history shows it"

# Delete asks first.
select_by_filter e2e-created
keys x
wait_for "Delete e2e-created"
pause
keys n
sleep 0.5
json automation list | grep -q '"e2e-created"' || fail "no deleted it"
keys x
wait_for "Delete e2e-created"
keys y
wait_cli "yes did not delete" sh -c "! thurbox-cli automation list --json | grep -q '\"e2e-created\"'"
clear_filter
keep after
pass "delete asks, no keeps, yes deletes"

# Leaving: the same chord, or Esc, gives the centre back to the agent.
gone() { ! screen | grep -qF "Automations ("; }
keys M-a
wait_cli "alt+a did not leave the pane" gone
keys M-a
wait_for "Automations ("
keys Escape
wait_cli "esc did not leave the pane" gone
pass "alt+a and esc both leave"

if [ -n "${RECORD:-}" ]; then
  pause
  keys C-q
  for _ in $(seq 40); do
    tmux -L e2e has-session -t e2e 2>/dev/null || break
    sleep 0.25
  done
  agg --idle-time-limit 1.5 --font-size 14 "$root/demo.cast" "$RECORD"
  echo "recorded $RECORD"
fi
# The way out the README names.
cli plugin remove automations --text >/dev/null || fail "plugin remove automations"
[ ! -e "$THURBOX_CONFIG_DIR/ui/thurbox-automations" ] || fail "the clone is still there"
pass "plugin remove takes it out"

echo "e2e: all passed (screens in $root/screens)"
