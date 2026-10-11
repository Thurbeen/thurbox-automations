#!/usr/bin/env bash
#
# Re-record media/demo.gif: the pane in a real thurbox, in its Doom theme.
#
#   scripts/record-demo.sh                       # thurbox + thurbox-cli on PATH
#   THURBOX_BIN=/path/to/bin scripts/record-demo.sh
#
# Needs tmux, git, python3, asciinema 2.x and agg. It installs HEAD: commit
# before running it.
#
# Everything runs in a profile made for the purpose under .cache/demo/ — HOME,
# XDG, thurbox's config and data, and a private tmux socket directory — so no
# real session, automation, theme or interface is read or touched. The
# automations it seeds run harmless `printf`/`exit` commands. The theme is
# thurbox's built-in `doom` preset, set the way thurbox's own demo recorders set
# it: `active_theme` in the profile's database.
#
# The recording fails rather than ship a frame that shows a home directory or
# the recording user's name.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${THURBOX_BIN:-}" ]; then
  PATH="$(cd "$THURBOX_BIN" && pwd):$PATH"
fi
OUT="${OUT:-$HERE/media/demo.gif}"
COLS=120 ROWS=34
real_home="$HOME" real_user="$(id -un)"
for bin in thurbox thurbox-cli tmux git python3 asciinema agg; do
  command -v "$bin" >/dev/null || {
    echo "error: $bin not found on PATH" >&2
    exit 1
  }
done

root="$HERE/.cache/demo"
rm -rf "$root"
mkdir -p "$root"/{home,config,cache,state,xdg-config,xdg-data}
# A socket path must stay under ~100 bytes, and thurbox keeps its interface
# control socket in its data directory, so both live in a short runtime
# directory. It is removed, servers and all, however the script ends.
sockets="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tbxd.XXXXXX")"
mkdir -p "$sockets/data"
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
export THURBOX_CONFIG_DIR="$root/config" THURBOX_DATA_DIR="$sockets/data"
export THURBOX_SOCKET="tbxd-demo" TMUX_TMPDIR="$sockets" TERM=xterm-256color
unset TMUX THURBOX_SOCKET_FOR THURBOX_UI_DIR NO_COLOR
for var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR; do
  unset "$var"
done

# Both features reach the network, and an upgrade notice would date the clip.
cat >"$THURBOX_CONFIG_DIR/settings.toml" <<'TOML'
[features]
version_check = false
auto_update = false
TOML

cli() { thurbox-cli "$@" >/dev/null; }
id_of() {
  thurbox-cli automation list --json |
    python3 -c "import json,sys; print(next(a['id'] for a in json.load(sys.stdin) if a['name']==sys.argv[1]))" "$1"
}
fail() {
  echo "FAIL: $*" >&2
  tmux -L demo capture-pane -p -t demo >&2 || true
  exit 1
}

# ── the plugin, installed as the README says ───────────────────────────────
git clone --quiet "$HERE" "$root/thurbox-automations"
cli plugin install "git+file://$root/thurbox-automations" --text
cli plugin check --text || fail "plugin check"

# ── synthetic automations with a run history ───────────────────────────────
# Schedules fire long after the recording ends; runs come from `run` + `tick`.
# The spawn target is a placeholder path that never exists.
cli automation create --name nightly-review --trigger weekdays --time 09:00 \
  --timezone UTC --repo /home/user/src/app --worktree auto/review \
  --prompt "Review open pull requests and summarise them"
cli automation create --name sync-tasks --trigger "cron:0 0 1 1 *" --timezone UTC \
  --command "printf 'synced 3 tasks'"
# Its first run succeeds and every later one fails, for a mixed history.
cli automation create --name flaky-export --trigger "cron:0 0 1 1 *" --timezone UTC \
  --command "if [ -e \"\$HOME/.exported\" ]; then printf 'export: 412 rows read\n'; echo 'upload failed: connection refused' >&2; exit 2; fi; touch \"\$HOME/.exported\"; printf 'exported 398 rows'"
cli automation create --name weekly-report --trigger weekly --time 08:00 --timezone UTC \
  --command "printf 'report written'" --disabled
cli automation create --name old-cleanup --trigger daily --time 03:00 --timezone UTC \
  --command "printf 'nothing to clean'" --disabled
for _ in 1 2; do
  cli automation run "$(id_of sync-tasks)"
  cli automation tick
done
for _ in 1 2; do
  cli automation run "$(id_of flaky-export)"
  cli automation tick
done

# thurbox creates its database on the first call above; the TUI is not running
# yet, so this write is conflict-free.
python3 - "$THURBOX_DATA_DIR" <<'PY'
import pathlib, sqlite3, sys
db = next(pathlib.Path(sys.argv[1]).rglob("*.db"))
with sqlite3.connect(db) as con:
    con.execute(
        "INSERT INTO metadata (key, value) VALUES ('active_theme', 'doom') "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value"
    )
PY

# ── the TUI, recorded while real keys drive it ─────────────────────────────
tmux -L demo new-session -d -s demo -x "$COLS" -y "$ROWS" \
  "asciinema rec --quiet --overwrite --cols $COLS --rows $ROWS -c thurbox '$root/demo.cast'"
screen() { tmux -L demo capture-pane -p -t demo; }
keys() { tmux -L demo send-keys -t demo "$@"; }
type_text() { tmux -L demo send-keys -t demo -l "$1"; }
pause() { sleep "${1:-1.4}"; }
wait_for() {
  for _ in $(seq 80); do
    screen | grep -qF -- "$1" && return 0
    sleep 0.25
  done
  fail "never saw: $1"
}

wait_for "Automations"
pause 2
keys M-a
wait_for "flaky-export"
pause 2
for _ in 1 2 3; do
  keys j
  pause
done
keys k k k
pause 0.5
# The failed run: its output, then only the errors.
keys /
type_text "flaky"
keys Enter
wait_for "connection refused"
pause
keys Tab
pause
keys f
wait_for "errors only"
pause 2
keys f f Tab Escape
pause 0.8
# Run now: marked due, fired by the heartbeat (a tick here), then in the history.
keys /
type_text "sync"
keys Enter
pause
keys r
wait_for "heartbeat fires it"
pause
cli automation tick
wait_for "3 runs"
pause 2
keys Escape
pause 0.8
# Switch one off, then delete another after the confirmation.
keys /
type_text "nightly"
keys Enter
pause
keys Space
pause 2
keys Escape
keys /
type_text "old-cleanup"
keys Enter
pause
keys x
wait_for "Delete old-cleanup"
pause 2
keys y
for _ in $(seq 40); do
  thurbox-cli automation list --json | grep -q '"old-cleanup"' || break
  sleep 0.25
done
keys Escape
pause 2
keys M-a
pause 1.5
keys C-q
for _ in $(seq 40); do
  tmux -L demo has-session -t demo 2>/dev/null || break
  sleep 0.25
done

cast="$root/demo.cast"
[ -s "$cast" ] || fail "no cast recorded"
# The fixture's own /home/user is a placeholder; any other home is a leak.
if grep -oE "/(home|Users)/[A-Za-z0-9_.-]+" "$cast" | grep -qvx "/home/user" ||
  grep -qF -e "$real_home" -e "$real_user" "$cast"; then
  fail "the recording shows a home directory or user name"
fi
# The background and foreground are the Doom theme's own, for any cell thurbox
# leaves unpainted.
agg --idle-time-limit 2 --font-size 14 --last-frame-duration 2 \
  --theme 1a080a,e0e0e0,1a080a,ff3b30,6eff6e,ffa500,00d9ff,ff5c54,00d9ff,e0e0e0 \
  "$cast" "$OUT"
echo "recorded $OUT"
