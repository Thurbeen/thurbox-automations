#!/usr/bin/env bash
#
# The pane under a real Lua 5.4, against a thurbox interface's own `lib/`.
#
#   THURBOX_REPO=/path/to/thurbox tests/run.sh
#
# THURBOX_REPO is a directory holding thurbox's `ui/` — a checkout, or
# `git archive <tag> ui | tar x` somewhere outside this working copy. CI pins
# the tag (THURBOX_TAG in .github/workflows/ci.yml).
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${THURBOX_REPO:?set THURBOX_REPO to a directory holding the thurbox ui/ tree}"
UI="$REPO/ui"

# The plugin VM is Lua 5.4; a newer `lua` on PATH is not the same language.
LUA="${LUA:-lua}"
command -v "$LUA" >/dev/null || { echo "$LUA not found (set LUA to a Lua 5.4)" >&2; exit 1; }
[ -f "$UI/lib/widgets.lua" ] || { echo "no interface at $UI" >&2; exit 1; }

status=0
for suite in model pane; do
  echo "== $suite"
  REPO="$HERE" UI="$UI" "$LUA" "$HERE/tests/$suite.lua" || status=1
done
exit "$status"
