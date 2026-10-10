#!/usr/bin/env bash
#
# Install the committed plugin the way the README says and load the interface
# the way thurbox does — in a profile made for the purpose, so nothing real is
# read or written. HOME, the XDG directories and thurbox's own config and data
# directories all point under .cache/loads/, which is removed first.
#
# It installs HEAD: commit before running it.
set -euo pipefail
cd "$(dirname "$0")/.."

root="$PWD/.cache/loads"
rm -rf "$root"
mkdir -p "$root/home" "$root/config" "$root/data" "$root/cache" "$root/state"

# Cloned under the repository's own name, which is the name the pane requires
# its module by — a checkout in a directory called anything else would not be
# what a user's install produces.
git clone --quiet "$PWD" "$root/thurbox-automations"

export HOME="$root/home"
export XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data"
export XDG_CACHE_HOME="$root/cache" XDG_STATE_HOME="$root/state"
unset THURBOX_UI_DIR THURBOX_CONFIG_DIR THURBOX_DATA_DIR

thurbox-cli plugin install "git+file://$root/thurbox-automations" --text
thurbox-cli plugin check --text
thurbox-cli plugin check --json > "$root/check.json"

# One `automations` pane, loaded and placed, and no warning: a chord conflict
# or a dropped pill would be one.
python3 - "$root/check.json" <<'PY'
import json, sys
check = json.load(open(sys.argv[1]))
assert check["ok"], check
assert "automations" in check["loaded"], check["loaded"]
assert not check.get("warnings"), check["warnings"]
print("installed and loaded in an isolated profile")
PY
