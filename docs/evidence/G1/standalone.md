# Standalone checkout verification

The Iara repository starts on `main`. Its checked-in files provide the
configuration, launcher, bootstrap, local tools, and tests. The UI
tests and gallery use the linegrid and RPC helpers in `tests/`.

Git still fetches pinned plugin and parser revisions. Release metadata
uses the source checkout's own revision. The bootstrap also supports
source archives with an unknown revision.

## Checks

```sh
IARA_TEST_JOBS=4 make check
make lint
make bench BENCH_PATHS=1000
```

Tested with Neovim 0.12.3, Git 2.47.3, ripgrep 15.2.0, and StyLua 2.6.0.
The standalone smoke test exported the staged source files to a
temporary directory. It used an isolated XDG profile, a temporary
launcher, and a local mirror for the pinned plugins and parsers.
Installation, launch, a no-op update, a promotion after editing the
source, and rollback all succeeded. The archive release recorded an
unknown source revision.

The final full suite reported 1,224 cases across 80 files and zero
failures. The optional real Lua language-server case was skipped.
