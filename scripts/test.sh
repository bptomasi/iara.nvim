#!/bin/sh
# Run the headless mini.test suite in an isolated Neovim environment.
#
# Usage: scripts/test.sh [TEST_FILE...]
#
# Each test file runs in its own headless Neovim with NVIM_APPNAME=iara-test
# and temporary XDG directories below one root that is removed afterwards,
# so tests never read or write ~/.config/nvim, the NvChad data directories,
# or a real Iara installation. IARA_TEST_JOBS files run at a time (default:
# the CPU count); IARA_TEST_FILE_TIMEOUT limits each file (seconds, 600).
# See tests/suite_runner.lua for the summary and the file markers.
set -eu

IARA_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ ! -f "$IARA_DIR/.tools/mini.nvim/lua/mini/test.lua" ]; then
  echo "test.sh: mini.nvim is missing; run scripts/tools.sh" >&2
  exit 1
fi

IARA_TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/iara-test.XXXXXX")
trap 'rm -rf "$IARA_TEST_TMP"' EXIT
trap 'exit 130' INT TERM

export IARA_TEST_TMP
export NVIM_APPNAME=iara-test
export XDG_CONFIG_HOME="$IARA_TEST_TMP/config"
export XDG_DATA_HOME="$IARA_TEST_TMP/data"
export XDG_STATE_HOME="$IARA_TEST_TMP/state"
export XDG_CACHE_HOME="$IARA_TEST_TMP/cache"
unset IARA_SAFE IARA_PERSONAL VIMINIT MYVIMRC

"${NVIM_BIN:-nvim}" --clean -l "$IARA_DIR/scripts/test_runner.lua" "$@"
