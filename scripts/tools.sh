#!/bin/sh
# Install pinned development tools into the gitignored iara/.tools/
# directory. Nothing is installed system-wide.
#
#   iara/.tools/bin/stylua   StyLua release binary (checksum verified)
#   iara/.tools/mini.nvim    mini.nvim checkout (provides mini.test)
#
# Re-running is safe: tools already at the pinned version are kept.
set -eu

STYLUA_VERSION="2.6.0"
STYLUA_ASSET="stylua-linux-x86_64-musl.zip"
STYLUA_SHA256="48ee7db28346f96f4bd545e190ab080a88a7b5a664e97649cf5d5c60426f402d"
STYLUA_BASE="https://github.com/JohnnyMorganz/StyLua/releases/download"

MINI_REPO="https://github.com/nvim-mini/mini.nvim"
# Tag v0.18.0.
MINI_COMMIT="1345d191bb3da9c7b0e977f4387c5761f9bff68d"

IARA_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS_DIR="$IARA_DIR/.tools"
BIN_DIR="$TOOLS_DIR/bin"

fail() {
  echo "tools.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

stylua_is_current() {
  [ -x "$BIN_DIR/stylua" ] || return 1
  "$BIN_DIR/stylua" --version 2>/dev/null | grep -q " $STYLUA_VERSION\$"
}

install_stylua() {
  if stylua_is_current; then
    echo "stylua $STYLUA_VERSION already installed"
    return
  fi
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) ;;
    *) fail "pinned StyLua is only available for Linux x86_64" ;;
  esac
  require_command curl
  require_command unzip
  require_command sha256sum
  work=$(mktemp -d "${TMPDIR:-/tmp}/iara-tools.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  url="$STYLUA_BASE/v$STYLUA_VERSION/$STYLUA_ASSET"
  echo "downloading $url"
  curl --fail --location --silent --show-error \
    --output "$work/$STYLUA_ASSET" "$url"
  echo "$STYLUA_SHA256  $work/$STYLUA_ASSET" | sha256sum --check --quiet \
    || fail "checksum mismatch for $STYLUA_ASSET"
  unzip -q "$work/$STYLUA_ASSET" -d "$work/unpacked"
  mkdir -p "$BIN_DIR"
  install -m 0755 "$work/unpacked/stylua" "$BIN_DIR/stylua"
  rm -rf "$work"
  trap - EXIT
  stylua_is_current || fail "installed stylua reports an unexpected version"
  echo "installed stylua $STYLUA_VERSION"
}

install_mini() {
  dest="$TOOLS_DIR/mini.nvim"
  if [ -d "$dest/.git" ] \
    && [ "$(git -C "$dest" rev-parse HEAD)" = "$MINI_COMMIT" ]; then
    echo "mini.nvim $MINI_COMMIT already installed"
    return
  fi
  require_command git
  rm -rf "$dest"
  git init --quiet "$dest"
  git -C "$dest" fetch --quiet --depth 1 "$MINI_REPO" "$MINI_COMMIT"
  git -C "$dest" checkout --quiet --detach FETCH_HEAD
  [ "$(git -C "$dest" rev-parse HEAD)" = "$MINI_COMMIT" ] \
    || fail "mini.nvim checkout does not match the pinned commit"
  echo "installed mini.nvim $MINI_COMMIT"
}

install_stylua
install_mini
"$(dirname "$0")/parsers.sh"
