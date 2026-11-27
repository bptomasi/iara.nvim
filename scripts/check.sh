#!/bin/sh
# Run every repository check: StyLua formatting, the quality checker, and
# the test suite. Exits nonzero when any check fails; all checks run.
#
# Usage: scripts/check.sh
set -u

IARA_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
STYLUA="$IARA_DIR/.tools/bin/stylua"
failed=""

run_check() {
  name=$1
  shift
  echo "==> $name"
  if "$@"; then
    echo "==> $name: ok"
  else
    echo "==> $name: FAILED"
    failed="$failed $name"
  fi
}

if [ ! -x "$STYLUA" ]; then
  echo "check.sh: StyLua is missing; run scripts/tools.sh" >&2
  exit 1
fi

cd "$IARA_DIR" || exit 1
run_check stylua "$STYLUA" --check --config-path .stylua.toml \
  --respect-ignores init.lua lua scripts tests
run_check quality env NVIM_LOG_FILE=/dev/null "${NVIM_BIN:-nvim}" \
  --clean -l scripts/quality.lua "$IARA_DIR"
run_check tests "$IARA_DIR/scripts/test.sh"

if [ -n "$failed" ]; then
  echo "check.sh: failed:$failed"
  exit 1
fi
echo "check.sh: all checks passed"
