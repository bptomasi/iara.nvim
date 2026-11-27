# Search fixture corpus

Task S1. `../make_search_fixture.lua` builds a reproducible corpus from
`corpus.lua` in a temporary directory and returns a manifest of
expectations. Nothing here is committed as a built tree: Git must be
initialized by the generator.

```sh
nvim -l tests/fixtures/make_search_fixture.lua DIR
```

```lua
local fixture = dofile(helpers.iara_dir
  .. "/tests/fixtures/make_search_fixture.lua")
local manifest = fixture.build(helpers.temp_dir())
local paths = fixture.eligible(manifest, false, false, "broad")
local hits = fixture.expected_matches(manifest, "needle", paths)
```

`DIR` must be absent or empty. The command line writes
`DIR/manifest.json` with `vim.json.encode`; path bytes stay raw (one name
is invalid UTF-8), so read it back with `vim.json.decode`.

`tests/test_search_fixture.lua` checks every expectation against the real
`rg --no-config`, so the manifest is evidence rather than a guess.

## Layout

| Path | Purpose |
| --- | --- |
| `DIR/project/` | Project root and Git repository (`manifest.root`). |
| `DIR/home/.gitconfig` | Sets `core.excludesFile` to the global ignore. |
| `DIR/home/global-ignore` | Global ignore file: `*.tmp`. |
| `DIR/.ignore` | Parent ignore file: `parent-ignored.txt`. |
| `DIR/outside/target.txt` | Target of the external symlink. |

Run Git and ripgrep with `manifest.env`. It sets `HOME` and
`XDG_CONFIG_HOME` (ripgrep finds the global ignore through
`$HOME/.gitconfig`), `GIT_CONFIG_GLOBAL`, and `GIT_CONFIG_NOSYSTEM=1`, so
the user's own Git configuration cannot leak into the results. Ancestors
of `DIR` must not contain `.ignore` or `.rgignore` files; use a temporary
directory.

## Eligibility

A path is eligible when ripgrep lists it for the switches, it passes the
strict hidden rule (no dot-prefixed component when hidden is off), it has
no `.git` component, and, with a glob, ripgrep also lists it under
`--hidden --no-ignore -g GLOB`. Symlinks are never eligible: following is
off and ripgrep does not list them.

| Category | Examples | Hidden | Ignored |
| --- | --- | --- | --- |
| Plain files | `content-only.txt`, `bulk/bulk-001.txt` | no | no |
| Special names | spaces, Unicode, `-x`, `--x`, `:`, tab, newline | no | no |
| Re-included | `keep.log` (`.ignore` beats `.gitignore`) | no | no |
| Ignore files | `.gitignore`, `.ignore`, `.rgignore` | yes | no |
| Whitelisted | `.env.example`, `.wl-git/`, `.wl-rg/` | yes | no |
| Dotfolders | `.config/app/`, `src/.cache/deep/.hidden/` | yes | no |
| Ignored | `debug.log`, `build/`, `src/generated/` | no | yes |
| Ignored elsewhere | `notes.tmp` (global), `parent-ignored.txt` | no | yes |
| Other ignores | `rg-ignored.txt`, `tracked-ignored.txt` | no | yes |
| Both | `.env`, `.hidden-ignored.log` | yes | yes |
| Git metadata | `.git/`, `vendor/lib/.git` (gitfile) | never | never |
| Symlinks | file, directory, broken, loop, external, `.git` | never | never |

So the four switch combinations without a glob are:

- **hidden off, ignored off:** plain, special, and re-included files.
- **hidden on, ignored off:** adds ignore files, whitelisted paths, and
  dotfolders.
- **hidden off, ignored on:** adds the ignored, non-hidden files.
- **hidden on, ignored on:** every regular file outside Git metadata.

The ignore files include `src/.gitignore`; `.wl-ignore/` is whitelisted
too. `manifest.special.whitelisted_hidden` lists every whitelisted path.

Whitelisted hidden paths appear in `rg --files` without `--hidden`; only
the strict hidden rule removes them. `my.git/readme.txt` is not metadata.

Glob kinds: `none`; `broad` (`*`, equals the no-glob set); `ignored_name`
(`.env`, eligible only with both switches, otherwise empty); `exclusion`
(`!*.txt`).

## Manifest format

```text
format        1
root          absolute project root
env           { HOME, XDG_CONFIG_HOME, GIT_CONFIG_GLOBAL,
                GIT_CONFIG_NOSYSTEM }
ignore_files  { global, parent } absolute paths
globs         { broad, ignored_name, exclusion } kind -> glob
eligible      list of { hidden, ignored, glob = kind, paths } for all
              4 x 4 cases; paths sorted, relative, without "./"
queries       list of { id, query, regex, matches?, binary_paths?,
              error?, file_count?, occurrence_count? }
special       paths with notable properties (see below)
```

Each occurrence is `{ path, line, byte_start, byte_end }`: 1-based line,
0-based half-open byte offsets into the raw line, as ripgrep reports with
`--encoding none` (the BOM counts). `matches` covers every non-binary
file in any combination; filter it with `fixture.expected_matches`.
Queries are case-sensitive.

| id | Query | Expectation |
| --- | --- | --- |
| `needle` | `needle` | 13 occurrences; binary file discarded |
| `alpha_dashes` | `alpha -- beta` | searched verbatim, one occurrence |
| `regex_optional` | `colou?r` (regex) | `color`, `colour` |
| `literal_optional` | `colou?r` | only the literal text |
| `literal_paren` | `(unclosed` | one occurrence |
| `invalid_regex` | `(unclosed` (regex) | `error = true`; rg exits 2 |
| `long_line` | `longlinemarker` | on a line above 256 KiB |
| `bulk` | `bulkmark` | 1,200 occurrences in 240 files |

`special` names: `names` (spaces, unicode, leading_dash, double_dash,
colon, tab, newline, invalid_utf8), `name_only`, `content_only`,
`name_and_content`, `repeated_same_line`, `nested_dotfolder`,
`whitelisted_hidden`, `ignored_hidden`, `tracked_ignored`,
`git_metadata`, `not_git_metadata`, `symlinks` (`{ path, target, kind }`),
`crlf`, `bom`, `unicode_content`, `binary` (`{ path, nul_offset }`, NUL
past ripgrep's first 64 KiB buffer, with `needle` before and after),
`long_line` (`{ path, line_bytes }`), and `bulk`
(`{ directory, name_query, file_count }`, more than 200 names).
