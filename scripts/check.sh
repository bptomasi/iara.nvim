#!/bin/sh
# Run all repository checks with the same targets used during development.
#
# Usage: scripts/check.sh
set -eu

IARA_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$IARA_DIR"
exec "${MAKE:-make}" -k fmt-check lint test
