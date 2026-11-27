#!/bin/sh
# Build the pinned Tree-sitter parsers listed in iara/parsers-lock.txt
# with the local C compiler. Nothing is installed system-wide.
#
#   scripts/parsers.sh [DEST]
#
# DEST defaults to the gitignored iara/.tools/treesitter. Each parser is
# written to DEST/parser/<language>.so and the commit it was built from to
# DEST/stamps/<language>. Add DEST to 'runtimepath' to load them.
# Re-running is safe: a parser already built from its pinned commit is
# kept. IARA_GIT_URL_FORMAT overrides "https://github.com/%s.git", for
# example to build from a local mirror.
set -eu

IARA_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LOCK="$IARA_DIR/parsers-lock.txt"
TS_DIR=${1:-"$IARA_DIR/.tools/treesitter"}
PARSER_DIR="$TS_DIR/parser"
STAMP_DIR="$TS_DIR/stamps"
URL_FORMAT=${IARA_GIT_URL_FORMAT:-"https://github.com/%s.git"}

fail() {
  echo "parsers.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

# Builds parser/<lang>.so from the grammar's src/ at a pinned commit.
build_parser() {
  lang=$1
  repo=$2
  commit=$3
  stamp="$STAMP_DIR/$lang"
  if [ -f "$PARSER_DIR/$lang.so" ] && [ -f "$stamp" ] \
    && [ "$(cat "$stamp")" = "$commit" ]; then
    echo "$lang parser $commit already built"
    return
  fi
  require_command git
  require_command cc
  work=$(mktemp -d "${TMPDIR:-/tmp}/iara-parsers.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  git init --quiet "$work/src"
  git -C "$work/src" fetch --quiet --depth 1 "$repo" "$commit"
  git -C "$work/src" checkout --quiet --detach FETCH_HEAD
  [ "$(git -C "$work/src" rev-parse HEAD)" = "$commit" ] \
    || fail "$lang grammar checkout does not match the pinned commit"
  sources="$work/src/src/parser.c"
  # External scanners (yaml) live next to the generated parser.
  if [ -f "$work/src/src/scanner.c" ]; then
    sources="$sources $work/src/src/scanner.c"
  fi
  mkdir -p "$PARSER_DIR" "$STAMP_DIR"
  # shellcheck disable=SC2086 # sources is a list of paths without spaces
  cc -O2 -shared -fPIC -I "$work/src/src" -o "$work/$lang.so" $sources
  # A stale stamp would let an interrupted copy pass as current.
  rm -f "$stamp"
  install -m 0755 "$work/$lang.so" "$PARSER_DIR/$lang.so"
  echo "$commit" >"$stamp"
  rm -rf "$work"
  trap - EXIT
  echo "built $lang parser $commit"
}

# Builds the entry collected so far, if any.
build_entry() {
  [ -n "$lang_entry" ] || return 0
  [ -n "$repo_entry" ] && [ -n "$commit_entry" ] \
    || fail "$LOCK: parser $lang_entry needs a repo and a commit"
  # shellcheck disable=SC2059 # the URL format is a printf format
  url=$(printf "$URL_FORMAT" "$repo_entry")
  build_parser "$lang_entry" "$url" "$commit_entry" </dev/null
}

build_all() {
  [ -f "$LOCK" ] || fail "missing parser lock $LOCK"
  lang_entry=""
  repo_entry=""
  commit_entry=""
  while read -r key value; do
    case $key in
      "" | "#"*) ;;
      parser)
        build_entry
        lang_entry=$value
        repo_entry=""
        commit_entry=""
        ;;
      repo) repo_entry=$value ;;
      commit) commit_entry=$value ;;
      tag) ;;
      *) fail "$LOCK: unknown key '$key'" ;;
    esac
  done <"$LOCK"
  build_entry
}

build_all
