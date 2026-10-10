#!/usr/bin/env bash
#
# The gate: lint, the pane's tests, and the plugin installed and loaded the way
# the README says, in a throwaway profile.
#
#   THURBOX_REPO=/path/to/thurbox scripts/check.sh
#
# THURBOX_REPO holds the thurbox `ui/` tree the tests load (CI uses the pinned
# tag). `thurbox-cli` on PATH is the release the install is checked against.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${THURBOX_REPO:?set THURBOX_REPO to a directory holding the thurbox ui/ tree}"

stylua --check plugins lib tests
selene plugins lib
rumdl check README.md
tests/run.sh
scripts/loads.sh
