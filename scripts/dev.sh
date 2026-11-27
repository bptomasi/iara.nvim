#!/bin/sh
# Open the live checkout. Bootstrap a private dependency store per lock.
set -eu

iara_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
nvim_bin=${NVIM_BIN:-nvim}
dev="$iara_dir/.tools/dev"
locks=$(sha256sum "$iara_dir/lazy-lock.json" "$iara_dir/parsers-lock.txt")
version=$("$nvim_bin" --version)
key=$(printf '%s\n' "$locks" "$version" | sha256sum)
# Keep paths short for Neovim's path-encoded Lua bytecode cache.
key=$(printf '%.20s' "${key%% *}")

export NVIM_APPNAME=iara-dev-checkout
export XDG_DATA_HOME="$dev/deps/$key"
export XDG_STATE_HOME="$dev/state"
export XDG_CACHE_HOME="$dev/cache"
unset IARA_SAFE IARA_PERSONAL VIMINIT MYVIMRC

if [ ! -f "$XDG_DATA_HOME/$NVIM_APPNAME/current/release.json" ]; then
  export XDG_CONFIG_HOME="$XDG_DATA_HOME/config"
  "$nvim_bin" --clean -l "$iara_dir/scripts/bootstrap.lua"
fi

export XDG_CONFIG_HOME="$dev/config"
exec "$nvim_bin" -u "$iara_dir/init.lua" "$@"
