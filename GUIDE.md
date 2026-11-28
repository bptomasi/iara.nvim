# Iara user guide

[Back to the README](README.md)

Iara is a personal Neovim distribution. It adds four workflows to a
plain, readable editing baseline:

- **Search**: Find files lists the project's files and narrows them by
  name (fuzzy); Find in files greps their contents (literal or regex),
  grouped by file. Chained steps hand the files of one step to the next
  (`Ctrl-g`), with a path glob, hidden and ignored switches, Vim keys
  for the list, and quickfix export.
- **Project terminal**: a panel at the bottom, top, left, right, or
  floating, with one main shell per project (`F7`); hiding the panel
  never stops the process.
- **Structured data**: the JSON path under the cursor, copy it, search
  keys, jump to them; YAML keeps yaml-revealer and `Space ys`.
- **Agents**: Claude Code and Codex run as native CLIs in their own
  panel, positioned like the terminal; editor context is previewed and
  copied, never typed in.

Iara runs as `NVIM_APPNAME=iara` with its own configuration and data.
The optional `make install-default` target makes plain `nvim` open Iara.

## Requirements

- Linux (other platforms are not verified).
- Neovim 0.12.3 or newer (0.12.3 is the validated baseline).
- `git` 2.19 or newer, `curl`, and `tar` for installation.
- `rg` (ripgrep) for search.
- A C compiler (`cc`) for parser builds. Optional parsers also require
  `tree-sitter` 0.26.1 or newer.
- Optional: `stylua` for Lua formatting, `lua-language-server` for Lua
  LSP, `claude` and `codex` for the agents.

`:checkhealth iara` reports what is missing and how to fix it.

### Tree-sitter languages

Iara ships with JSON and YAML parsers and uses the parsers bundled
with Neovim. In Iara, install additional languages with:

```vim
:TSInstall hcl terraform bash go c cpp java javascript typescript tsx rust
```

`:TSInstall` completes language names and also accepts other languages
from nvim-treesitter. `:TSUpdate` updates the installed extras and
`:TSUninstall` removes them. Reopen the file after installing its
parser to enable highlighting. Parser downloads run on request, and
extras are shared across Iara releases for the same profile.

## Installation

Clone the repository, then run the bootstrap with absolute paths:

```sh
NVIM_APPNAME=iara nvim -l /abs/path/to/iara/scripts/bootstrap.lua \
  --launcher ~/.local/bin/iara
```

The bootstrap builds a *release* in a temporary directory with a copy of
this checkout's configuration, lazy.nvim and
every plugin at the commits in `lazy-lock.json`, and the parsers pinned
in `parsers-lock.txt`. It verifies every commit, loads every parser,
and starts Iara once from the release in separate directories. Only a
release that passes all of this is published and made current. Then it
links `~/.config/iara` to the current release and links the launcher.
It refuses any destination that already exists (including dangling
symlinks) and removes what it created when it fails. The checkout is
not used after installation; you may move or update it.

Start Iara with the launcher, which sets `NVIM_APPNAME=iara` for Neovim
only:

```sh
iara [files...]
```

Then run `:checkhealth iara`. Ordinary startup never installs or updates
anything, and never runs a project's `.lazy.lua`.

Only one provisioning command runs at a time: a second one started
meanwhile stops without changing anything. If a run is interrupted
(killed, power loss), every command except `--repair` refuses to start
until you repair.

### Install with make

Run GNU make from the repository root. `DRY_RUN=1` previews the commands.

```sh
make install          # Iara as `iara`; `nvim` keeps its own config
make install-default  # `nvim` opens Iara; the old nvim setup is saved
make backups          # list backups
make restore          # undo the latest backup (or BACKUP=<dir>)
```

`make install` moves any existing `~/.config/iara`, `~/.local/share/iara`,
`~/.local/state/iara`, `~/.cache/iara`, and launcher (`LAUNCHER=`,
default `~/.local/bin/iara`) into a backup, then runs the bootstrap
above with `--launcher`.

`make install-default` installs Iara first when it is missing. Then it
moves `~/.config/nvim`, `~/.local/share/nvim`, `~/.local/state/nvim`,
and `~/.cache/nvim` (for example NvChad) into a backup and replaces
each with a symbolic link to the matching `iara` path. Plain `nvim`
then loads Iara with Iara's plugins, state, and cache, wherever `nvim`
is on `PATH` and however it is started. The trade-offs: `nvim` and
`iara` share one installation (same shada, undo, and theme), and a tool
that expects NvChad's files in `~/.local/share/nvim` sees Iara's. A
launcher named `nvim` on `PATH` would avoid moving anything, but
depends on `PATH` order and is bypassed by `/usr/bin/nvim`. Running it
again when `nvim` opens Iara already changes nothing.

Nothing is deleted. Each action renames paths (within one filesystem)
into `~/.local/share/iara-backups/<UTC time>-<action>/` and records
them in its `MANIFEST`, one tab-separated line each: type (`dir`,
`link`, `file`), original path, backup path, and a link's target. An
existing backup directory is never reused; the run stops instead.

`make restore` checks the backup against its `MANIFEST` and refuses a
mismatch without changing anything. Whatever occupies an original path
(the Iara links after `install-default`) is first moved into a new
`restore` backup, then the saved paths move back unchanged and the
backup is marked `RESTORED`. So `make restore` after `install-default`
gives you NvChad back exactly as it was. `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` are honored.

The same targets cover the steps below: `make update` (this checkout),
`make repair` and `make rollback` (the current release's stored
bootstrap, see "Repair"), and `make uninstall`.

### Update

Get the new revision into a checkout (for example `git pull`), then run
the bootstrap *of that checkout* with `--update`:

```sh
NVIM_APPNAME=iara nvim -l /abs/path/to/iara/scripts/bootstrap.lua --update
```

The update prints the checkout path, branch, and revision. When its
files match the verified current release, Iara keeps both releases.
Otherwise, it builds and starts a candidate before switching over.
Clean plugins and parsers at the same pins can be reused offline. If
activation fails, the current release stays active and the error says
why. After a successful switch, Iara retains the prior release for
rollback and prunes obsolete releases. Restart Iara to load the update.

Your personal file `~/.config/iara/lua/user.lua` lives in the current
release; the update copies it into the new one.

An installation made before releases existed (plugins directly in
`~/.local/share/iara/lazy`, `~/.config/iara` linked to the checkout)
keeps working. `--update` turns it into a release and points
`~/.config/iara` at it; the old `lazy`, `lazy-lock.json`, and
`treesitter` entries stay in `~/.local/share/iara` for you to remove.

### Rollback

```sh
NVIM_APPNAME=iara nvim -l \
  ~/.local/share/iara/current/config/scripts/bootstrap.lua --rollback
```

Rollback makes the previous release current again and the current one
previous (so a second rollback undoes the first). It uses only the
retained release: no network, no Git, no `:Lazy sync`. Before it
switches anything it checks the previous release against its manifest
(the checksum of every configuration file except your `lua/user.lua`,
the plugin commits and recorded content checksums, and the parser
checksums) and starts Iara from it
once in separate temporary directories, which must reach full mode
without errors (a broken `lua/user.lua` fails this too). A damaged
release, or one that does not start, is refused without changing
anything, and the error says why. A release built before configuration
checksums were recorded cannot be verified and is refused too; run
`--update` from a checkout to build a verified one. Restart Iara
afterwards. Mason packages (`~/.local/share/iara/mason`)
are shared by all releases and not rolled back.

### Repair

A pinned plugin missing from the installation (for example after a
`git pull` of a checkout-linked installation adds a plugin) does not
break startup: Iara disables it and every plugin that needs it, the
features that use them fall back (Markdown stays raw, search explains
that it needs Snacks), and one notice after startup names them:

```text
Iara: 1 pinned plugin is missing (render-markdown.nvim); run :IaraRepair
```

`:IaraRepair` runs the repair below in a terminal window at the bottom
and reports when it ends; restart Iara afterwards to load the repaired
plugins. `:checkhealth iara` lists missing plugins too.

When a plugin, the plugin manager, a parser, or the configuration link
of the current release is missing, or after an interrupted run, run the
current release's own bootstrap, stored in the data directory (this is
what `:IaraRepair`, `:checkhealth iara`, and `make repair` use):

```sh
NVIM_APPNAME=iara nvim -l \
  ~/.local/share/iara/current/config/scripts/bootstrap.lua --repair
```

This path works when `~/.config/iara` is gone: the repair recreates the
link. (`~/.config/iara/scripts/bootstrap.lua` is the same file only
while that link exists.) With `XDG_DATA_HOME` set, use
`$XDG_DATA_HOME/iara/current/...`. An installation made before releases
has no `current`; use the bootstrap of the checkout it links to.

Repair restores the current release at its recorded revisions (network
is needed for anything it must download). After an interrupted run it
removes that run's temporary files first. It never replaces a tree at
another revision: a parser built from another commit or an unknown
lazy.nvim tree is reported; move it away and repair again.

### Safe mode

```sh
IARA_SAFE=1 iara
```

Safe mode skips plugins, personal configuration, project policy, and
hooks; you get native editing with the Iara options and theme. Iara also
falls back to safe mode when the personal configuration fails to load
(the error and its traceback are reported).

### Uninstall

Iara owns only these paths (with default XDG directories):

| Path | Content |
| --- | --- |
| `~/.config/iara` | link to the current release's configuration |
| `~/.local/share/iara` | releases (`releases/`, `current`, `previous`), Mason |
| `~/.local/state/iara` | theme choice, undo, shada, logs |
| `~/.cache/iara` | bytecode cache |
| `~/.local/bin/iara` | launcher link (the path you chose) |

Remove them to uninstall, or run `make uninstall`, which moves them
(and `nvim` links to them) into a backup and names the backup to
restore for your previous `nvim` setup.

## Configuration

Personal configuration is a Lua file returning a table, at
`~/.config/iara/lua/user.lua` (it lives in the current release and
updates copy it forward; in an older checkout-linked installation it
lives in the checkout, ignored by Git) or at the path in
`IARA_PERSONAL`. Layers apply in order:
defaults, personal configuration, then the policy of a trusted project.
Maps merge, lists replace, and `false` removes an optional capability.

```lua
return {
  ui = { theme = "gruvbox" }, -- explicit: wins over :IaraTheme
  options = { relativenumber = true },
  keymaps = {
    ["n <leader>x"] = false, -- remove an Iara default
    ["n <leader>q"] = { "<cmd>quit<CR>", desc = "Quit window" },
  },
  features = { structured = { breadcrumb = false } },
  extras = {
    agents = { claude = { argv = { "claude", "--verbose" } } },
  },
  trusted_projects = { "~/work/api" }, -- allows ~/work/api/.iara.lua
  hooks = {
    early = function()
      vim.opt.relativenumber = true
    end,
  },
}
```

Top-level keys: `options`, `keymaps`, `plugins` (lazy.nvim specs added
last), `features` (`search`, `terminal`, `structured`), `languages`,
`formatters`, `extras` (`agents`), `ui`, `trusted_projects`, and
`hooks` (`early` runs after options, `late` after every step).

**Project policy.** A file `.iara.lua` in the directory where Iara starts
is read only when that directory is listed in the personal
`trusted_projects`. It may not set `trusted_projects` or `hooks`, and
every `false` in the personal layer wins over it.

## Mappings and commands

The leader is `Space`. `Space wK` lists every mapping; which-key shows
the groups below.

### Search

| Key | Command | Action |
| --- | --- | --- |
| `Space ff` | `:IaraFiles [name]` | Find files by name (fuzzy) |
| `Space fw` | `:IaraGrep [text]` | Find text in files (literal or regex) |
| `Space fa` | | Find files, including hidden and ignored |
| `Space fr` | `:IaraSearchResume` | Resume the last search |

The picker opens in Insert mode in its prompt, so you can type at once.
`Esc` switches to Normal mode, where Vim keys move in the list; the
prompt glyph turns from `❯` into `❮`, a `NORMAL` chip appears, and the
footer lists the keys of the mode. A second `Esc` closes the picker.

In Normal mode:

| Key | Action |
| --- | --- |
| `j` / `k`, `Down` / `Up` | Next / previous result (counts: `5j`) |
| `gg` / `G` | First / last result |
| `Ctrl-d` / `Ctrl-u` | Half a page down / up |
| `Ctrl-f` / `Ctrl-b` | A page down / up |
| `H` / `M` / `L` | Top / middle / bottom of the visible results |
| `Enter`, `o`, `l` | Open |
| `v` / `s` | Open in a vertical / horizontal split |
| `p` | Hide or show the preview |
| `i` | Back to Insert mode where you left it |
| `a`, `A`, `/` | Insert mode at the end of the query |
| `I` | Insert mode at the start of the query |
| `q`, `Esc` | Close |

Movement skips the file headers of Find in files. In both modes:

| Key | Action |
| --- | --- |
| `Ctrl-g` | Next step: grep the files found, or filter files by name |
| `Ctrl-o`, or `Backspace` on an empty prompt | Back to the previous step |
| `Alt-g` | Path glob; offers a typed `*.lua` (empty clears) |
| `Alt-h` / `Alt-i` | Toggle hidden / ignored files |
| `Alt-r` | Toggle literal or regex text matching |
| `Alt-c` | Cycle case: smart, sensitive, insensitive |
| `Alt-s` | Cycle scope: root, file directory, file |
| `Alt-d` | Choose a directory to search in (below) |
| `Alt-x` | Search the whole project again (clear the scope) |
| `Tab` / `Shift-Tab`, `Ctrl-a` | Toggle selection / select all |
| `Enter`, `Ctrl-s`, `Ctrl-v`, `Ctrl-t` | Open (split, vsplit, tab) |
| `Ctrl-q` | Selected (or all shown) results to quickfix |
| `Ctrl-d` / `Ctrl-u` | Half a page down / up |
| `Ctrl-f` / `Ctrl-b` | Scroll the preview (Insert mode) |

Opening shows the result under the cursor in the current window (it
replaces the start screen); selected files also become buffers. Only
`Ctrl-q` makes a quickfix list.

The list and the preview are two panes of equal size, side by side on
editors at least 120 columns wide and stacked on narrower ones. JSON key
search (`Space ys`) has the same layout and modes.

Chained filters narrow step by step. For example, `Space ff`, type
`test`, press `Ctrl-g`, and type `useEffect`: the title reads
`Files: test (5) › Contains: useEffect`, and only those five files are
searched. `Ctrl-g` again keeps the files that contain matches and lets
you filter them by name; `Ctrl-o` goes back with the previous query and
results. A step hands over every file it collected, at most 200 names
(or the files of 1,000 matches), and says so when there were more; a
glob without a name query hands over every matching file.

Find files lists the project's files as soon as it opens, like
Telescope's `find_files`: the buffers you used recently first, then
shallow paths before deep ones, in path order. It shows 200 rows and
the full count (`1,284 files`); type to narrow. `Ctrl-g` from that list
searches every eligible file, not only the rows shown. Find in files
waits for text.

`Alt-d` lists the project's directories in the same frame, starting at
the current scope, to search in one of them. The title shows where
you are (`Find files › 󰉋
project/lua/iara`); `.` searches here, `..` goes up (never above the
project root), and the shown directory is a tree: its subdirectories,
each with how many searchable files it holds, then its files. Only
eligible entries are listed, so hidden and ignored ones follow `Alt-h`
/ `Alt-i`, and `.git` never shows.

| Key | Action |
| --- | --- |
| `Enter` | Expand or collapse the directory; open a file; `.` searches here |
| `l` (Normal mode) | Go into the directory |
| `h`, `-`, `Backspace` on an empty prompt | Go up |
| `E` (Normal mode) | Open Oil for the selected directory or file |
| Typing | Filter every directory below by name |
| `lua/iara/core`, `../tests` then `Enter` | Jump to the typed path |
| `Tab` | Complete the typed path |
| `Alt-d` | Search in the shown (or typed) directory |
| `Alt-x` | Search the whole project |
| `Ctrl-o` | Back to the search, scope unchanged |

Use Oil to create, rename, or delete entries. `E` opens the directory
under the cursor or the directory containing the selected file.
`Space d` also opens Oil directly from the editor.

The search then reads `Find files · lua/iara/core/`, and `Ctrl-g`
chains keep that scope.

The pane with the focus has its frame and title in the accent; the
other pane, earlier chain steps, and the preview's title are quiet.
The title is followed by the switches that are not at their defaults
(`· hidden`, `ignored`,
`regex`, `case`, scope). The row under the cursor has a `▎` bar. The
prompt shows the count (`37 files`, `128 matches in 12 files`), in the
theme's tide color with a spinner while results still arrive;
truncation and errors get one tinted notice line, and "No matches"
names the switches that could find more (`A-h hidden`, `A-i
ignored`). The preview's title names the file and, for a match, its
line. While you hold `j` or `Ctrl-n`, the list never waits for the
preview: it shows each file's first screen as plain text and adds the
highlighting once you stop. Search reads saved files on disk, never
unsaved buffer text, always excludes `.git`, and does not follow
symlinks.

### Terminal

| Key | Command | Action |
| --- | --- | --- |
| `F7` (normal and terminal) | `:IaraTermToggle` | Toggle main terminal |
| `Ctrl-h/j/k/l` | | Move focus to the adjacent window |
| `Space tt` | | Toggle main terminal |
| | `:IaraTermFocus` | Show and focus it, never hide |
| `Space tn` | `:IaraTermNew` | New terminal at the project root |
| `Space tl` | `:IaraTermSelect` | Choose a terminal of any project |
| `Space t.` | `:IaraTermHere` | New terminal in the file directory |
| `Space ts` | | Main terminal at the side (right) |
| `Space tv` | `:IaraTermPosition` | Move the panel to the next position |
| | `:IaraTermPosition top` | Panel at a position (see below) |
| | `:IaraTermExit` | Leave terminal input |
| | `:IaraTermStop` | Stop this terminal's job |
| | `:IaraTermRestart` | Restart this terminal |
| | `:IaraTermDispose` | Remove this exited terminal |

`Esc` and `Ctrl-c` go to the program; `Ctrl-\ Ctrl-n` leaves terminal
input as in plain Neovim. In Iara's terminal panels, `Ctrl-h/j/k/l` move
focus directly from terminal input. Moving into a live panel with those
shortcuts resumes terminal input. With no window in that direction, the
key goes to the running program.

Shells share one panel and agent sessions share another, so a shell at
the bottom and Claude Code at the right can be visible together. Each
panel opens at `bottom`, `top`, `left`, `right` (full width or height
of the tab), or `float` (centered, with a straight border and the
terminal's name as title). `Space tv` and `:IaraTermPosition` without
an argument cycle bottom, right, top, left, float. Moving keeps the
running shell, each position remembers the size you leave it at, and a
panel shown in another tab moves there instead of being duplicated.

The status line of a terminal shows a clean name, such as
`Terminal · zsh`, `Terminal 2 · zsh in src`, or `Claude Code`, with
its state (`running`, `exited 1`) and the project, never the
`term://...` buffer name; the tab line names terminal tabs the same
way.

When a shell exits (`exit`, `Ctrl-d` at an empty prompt, or an error), its
panel closes and focus returns to the window you were editing. An agent
session closes after a successful exit and keeps its transcript after a
failure, so the error stays readable. To change this:

```lua
features = {
  terminal = { position = "top", close_on_exit = false },
},
extras = {
  agents = {
    position = "float", -- default "right"
    codex = { position = "left" }, -- per agent
    close_on_exit = "success", -- or true, false
  },
},
```

### Agents

| Key | Command | Action |
| --- | --- | --- |
| `Space ac` | `:IaraAgent claude` | Open Claude Code |
| `Space ax` | `:IaraAgent codex` | Open Codex |
| `Space aa` | `:IaraAgent` | Choose an agent session |
| `Space at` | `:IaraAgentToggle` | Show or hide the agent panel |
| `Space ap` | `:IaraAgentPosition` | Move the agent panel (next position) |
| | `:IaraAgent claude left` | Open an agent at a position |
| | `:IaraAgentPosition float` | Agent panel at a position |
| `Space as` (Visual) | | Preview the selection for an agent |
| `Space af` | `:IaraAgentFile` | Preview a file reference |

The agent panel opens at the right unless configured otherwise.
`:IaraAgent <name> <position>` remembers the position for that agent;
`:IaraAgentPosition` and `Space ap` apply to every agent. `F7` inside a
focused agent panel hides it, like `Space at`.

In a preview, `y` copies the exact payload and `q` closes it; paste it
into the agent yourself.

#### Ask AI about a selection

| Key | Command | Action |
| --- | --- | --- |
| `Space ai` (Visual) | `:'<,'>IaraAsk [question]` | Ask AI (Codex by default) |
| `Space ac` (Visual) | | Ask Claude in a popup |

Select text (Visual mode or the mouse), press `Space ai`, type a
question, and press Enter. Codex streams its answer into the popup.
When Codex is unavailable, the default tries Claude Code.
Use `Space ac` to choose Claude explicitly.

Inside the popup, `Enter` asks, `Ctrl-j` adds a line and `Ctrl-c`
cancels an answer in progress. `Esc` closes the popup from either pane.
Drag the top border with the left mouse button to move both panes
together. `Tab` switches between the panes, `i` edits the question,
`y` copies the answer, `o` shows the whole excerpt and `q` also closes
in Normal mode. Each follow-up sends the excerpt and earlier answers.

Each question runs the CLI once, read-only and without tools (Claude
Code with no tools and no MCP servers, Codex in its read-only sandbox),
with your sign-in; Iara stores nothing and never inserts the answer into
a buffer. Override the backend for `Space ai` and `:IaraAsk` with
`extras = { ai = { backend = "claude" } }`. `argv` changes the command
for the configured backend, and `timeout_ms` sets its deadline
(default 180000).

### Structured data

| Key | Command | Action |
| --- | --- | --- |
| `Space ys` | `:IaraStructuredSearch` | Search keys (YAML: path prompt) |
| `Space yp` | `:IaraStructuredPath` | Show the path at the cursor |
| `Space yc` | `:IaraStructuredCopy` | Copy the path |
| `Space yt` | `:IaraStructuredBreadcrumb` | Toggle the JSON breadcrumb |
| | `:IaraYamlResume` | Resume yaml-revealer after a large file |

In YAML, type a key name or a path at the `Space ys` prompt and press
`Enter`. For example, `server.http.port` selects a nested key and
`items[0].name` selects a key in the first list item. Use quotes for a
component containing a dot, as in `config."app.port"`.

### Editing, files, Git, and LSP

| Key | Command | Action |
| --- | --- | --- |
| `Ctrl-n` / `Space e` | | Toggle / focus the file explorer |
| `Space d` | `:Oil` | Open the current file's directory in Oil |
| `H` / `I` in the explorer | | Toggle dotfiles / Git-ignored files |
| `Ctrl-s` | | Save file |
| `Tab` / `Shift-Tab` | | Next / previous buffer |
| `Space x` / `Space b` | | Close buffer / new buffer |
| `Ctrl-h/j/k/l` | | Move between windows |
| `Space /` | | Toggle comment |
| `Space n` / `Space rn` | | Line numbers / relative numbers |
| `Space sd` | | Diagnostics to location list |
| `Space fm` (Lua) | `:IaraFormat` | Format with StyLua |
| `Space mr` (Markdown) | `:IaraMarkdownToggle` | Markdown rendering on/off |
| `Space gp` / `gs` / `gr` / `gb` | | Hunk preview / stage / reset / blame |
| `gd` / `gD` | | Definition / declaration (LSP) |
| `Space D` / `Space ra` | | Type definition / rename (LSP) |

Oil opens an editable directory buffer in the current window. Press
`Enter` on `..` or press `-` to go up. The parent entry is visible even
when hidden files are off. Edit the listing and use `:write` to apply
changes. Deleted files go to the system trash.

### PDFs

Open a local PDF with `:IaraPDF path/to/file.pdf`, `:edit`, or by selecting
it in Oil or the file picker. Graphical pages are centered in their split.
Scroll continuously with the mouse wheel, `j`, `k`, `Ctrl-d`, or `Ctrl-u`.
Use `]p` and `[p` to jump by page, `gg` and `G` to jump to either end,
and `q` to close the viewer. The page counter stays in the statusline.
Use `+` and `-` to zoom and `0` to restore the original fit. Zoom
keeps the same reading position. On Foot, each split has its own zoom
level up to 600%, and the page is clipped to that split's bounds.
When the page extends past the sides, drag or click its bottom scrollbar,
use `h` and `l`, or scroll horizontally with the mouse.

The file picker previews the first page. Graphical viewing uses Poppler
(`pdfinfo` and `pdftoppm`), ImageMagick, and a compatible terminal. Foot
uses Sixel and can use `img2sixel` for faster encoding. Kitty and
Ghostty use the Kitty graphics protocol. The
viewer renders visible pages and preloads adjacent ones. With text-only
viewing, the picker uses `pdftotext` and `j` and `k` move by page in the
viewer. Poppler's commands are in `poppler-utils` on Debian and Ubuntu.

Set `features = { pdf = false }` in your personal configuration and
restart Iara to disable the PDF command, automatic opening, and preview.

### Formatting

Formatting is explicit only. It needs `stylua` and a `stylua.toml` or
`.stylua.toml` between the file and the project root, or the absolute
paths in `languages.lua.stylua` and `languages.lua.stylua_config`.

### Project root and disk conflicts

| Command | Action |
| --- | --- |
| `:IaraRoot` | Show the project root and where it came from |
| `:IaraRootSet {path}` | Override the root for this session |
| `:IaraRootReset` | Remove the override |
| `:IaraCheckDisk` | Check loaded buffers for external changes |
| `:IaraCompareDisk` | Diff the buffer against its disk snapshot |
| `:IaraKeepBuffer` | Keep the buffer text and clear the conflict |
| `:IaraLoadDisk` | Replace the buffer text with the file on disk |

The root is the nearest Git repository of the current buffer, else the
startup directory. A buffer you modified is never reloaded when its file
changes on disk: the statusline shows a conflict until you resolve it.

### Themes

| Key | Command | Action |
| --- | --- | --- |
| `Space th` | `:IaraTheme` | Theme picker with live preview |
| | `:IaraTheme {name}` | Apply and remember a theme |
| | `:IaraToggleBackground` | Toggle the terminal background |

Themes: `chocolate` (default), `catppuccin`, `everforest`,
`github_dark`, `github_light` (light), `gruvbox`, `gruvbox_light`
(light), `kanagawa`, `nord`, `onedark`, `rosepine`, `tokyonight`. Each is
also `:colorscheme iara-<name>`.

The picker previews the theme under the cursor and has the same modes
as the search pickers: type to filter, `Esc` for Normal mode, where
`j`/`k`, counts, `gg`/`G`, `Ctrl-d`/`Ctrl-u`, `Ctrl-f`/`Ctrl-b`, and
`H`/`M`/`L` move; `Enter`, `o`, or `l` apply and remember the theme;
`q` or a second `Esc` cancel and bring back the previous theme; `i`,
`a`, `A`, `I`, `/` return to typing. Each row shows the theme's type
(`dark` or `light`; type it to filter), `✓` on the remembered theme,
and swatches of its background, chrome, accent, tide, and state
colors.

Precedence at startup: `ui.theme` set in your personal configuration (or
a trusted project), then the last `:IaraTheme` choice (stored in
`~/.local/state/iara/iara/theme`), then `chocolate`. Unknown names fall
back to `chocolate`. Safe mode is themed too.

### Appearance

Iara uses your terminal's background by default for the editor, start
screen, tab line, split headers, and panel surfaces. These include the
shell, agents, explorers, and floating pickers. `:IaraToggleBackground`
switches between the terminal and palette backgrounds for the session.
Set `ui = { terminal_background = false }` in your personal configuration
to start with the palette background.

Icons need a Nerd Font in the terminal (as nvim-web-devicons does).
Every frame, chip, and bar is built from straight lines and whole
cells, so no corner ever shows a second color (terminal cells are
rectangles; rounded corners and round caps leave part of a cell
unpainted).

- **Start screen.** `nvim` without files opens a start screen with a
  Braille wave aligned to the menu. Use `:IaraToggleWaveAnimation` to
  toggle motion for the session, or `ui = { wave_animation = false }`
  to start with a still wave. The wave keeps moving while the start
  screen is visible behind another panel. Use `f` to find
  files, `w` to find in files, `r` for recent files (`:IaraRecent`),
  `e` new file, `t` terminal, `h` themes, `q` quit; `j`/`k` move the
  selection bar and Enter runs it, and `i` starts typing in a new
  buffer. "Recent in <project>" lists up to five files of the project
  you opened before; `1`-`5` open them. The footer shows the project,
  its branch, the Neovim version, and the startup time (from Iara's
  `init.lua` to VimEnter, so Neovim's own launch is not counted). It
  closes when a file opens. Turn it off with
  `ui = { start_screen = false }`.
- **Status line.** The mode as a solid block colored per mode, then
  flat segments set apart by spacing and color: the file icon and name
  with a dot while modified, the Git branch and change counts,
  then the conservative-mode reason or disk conflict when there is one,
  diagnostic counts, the LSP client (wide windows), the project root,
  `[safe]`, and the cursor position. Terminals and agents keep their
  clean name and state.
- **Tab line.** With one tab page it lists open files (shown from two
  files on; click to switch, `Tab`/`Shift-Tab` cycle); with several tab
  pages it names each tab by its file or terminal. Set
  `options = { showtabline = N }` to manage it yourself.
- **Windows.** One thin straight frame on every float (pickers, hover,
  signature, diagnostics, completion, which-key, the terminal float,
  the agent context preview, Mason, and lazy.nvim), with titles on the
  top edge (`┌─ Find files ──┐`) and key hints on the bottom edge
  (`└─ ⏎ open · q close ─┘`). Focus is the frame's color: the float
  you are in has an accent frame and title, others a quiet one
  (`IaraFloatBorderFocus`, `FloatBorder`, `FloatTitle`); thin Git
  change bars (added green,
  changed blue, removed red), no `~` past the end of a buffer.
- **Choices.** Lists that ask you to choose (`Space tl` terminals,
  `Space aa` agents, the structured copy prompt, the theme list in safe
  mode) open in a small centered frame: the question as the title,
  numbered items, `j`/`k` to move, `Enter` or a digit to choose, `q`
  or `Esc` to cancel. Lists of more than 12 items open a filtering
  picker with the search pickers' modes.
- **Editing view.** Indent guides (`│`) at every 'shiftwidth' of
  leading spaces and every leading tab, drawn natively by 'listchars'
  in file buffers only; large or long-line files (conservative mode)
  show none. Set `options = { list = ... }` or `listchars` to manage
  them yourself. Line numbers are readable text and the cursor's
  number is the theme accent. Diagnostics put a severity icon in the
  sign column of every line and color the number of error lines; the
  message appears after the line only on the cursor's line, and the
  diagnostic float (titled "Diagnostics") adds the code, and the source
  when there are several.
- **Markdown.** Markdown files render like Obsidian's live preview
  (render-markdown.nvim, loaded with the first Markdown buffer):
  `_italic_`, `**bold**`, and `~~struck~~` hide their markers;
  headings get a numbered icon and a band in their level's color;
  tables become straight grids with aligned columns; code blocks sit on
  a darker block with the language on top; tasks show checkboxes (also
  Obsidian's `[/]` in progress, `[-]` cancelled, `[>]` forwarded,
  `[!]` important, `[?]` question), done and cancelled tasks are
  struck through; quotes get a bar and callouts (`> [!NOTE]`,
  `> [!WARNING]`, ...) an icon and title in their state color; links,
  bullets, and rules are drawn too. The line under the cursor shows
  its raw text, and Insert mode shows the whole note raw (like
  Obsidian's source mode), so you always type exactly what is in the
  file; leaving Insert mode renders it again. (Rendering while typing
  cost several milliseconds per key.) `Space mr` or
  `:IaraMarkdownToggle` turns rendering off
  and on for every Markdown buffer. Large or long-line files
  (conservative mode) show raw text.
- **Completion** shows the kind icon and name and the source; the
  documentation opens beside it. **The file tree** shows the project
  name with the Iara mark and the branch, folders in the theme's tide
  color, open files in its accent, and one dot after a name for its Git
  state: yellow modified, green new or staged, red deleted or in
  conflict, dim ignored (`g?` in the tree lists the keys).
- **Health.** `:checkhealth iara` heads each module with its counts
  (`∿ iara ─── 12 ok · 1 warning · 0 errors`), marks reports with
  `✓ ▲ ✗`, and shows advice muted after `→`. The text underneath is
  unchanged, so copying from it still gives Neovim's report.
- **Agent context preview.** Titled "Agent context", with the payload
  size against its 128 KiB cap (yellow above 80%), a summary of what was
  captured above the payload, and the reminder that nothing is sent.
- **Messages (experimental).** `ui = { messages = "ui2" }` switches to
  Neovim 0.12's experimental message UI: notices show for 4 s in a small
  float, `:messages` opens a pager, and the history is kept. The default
  is `"native"`.

## Agents

The agents module is enabled by default. It only registers the commands
and mappings above; nothing starts until you ask. Each CLI runs with its
own argv, configuration, login, permissions, and model; Iara adds no
flags, stores no credentials, and refuses a configured argv with a
permission-bypass flag. A missing CLI is reported and changes nothing.
Hiding the panel (`F7`) does not stop an agent. To disable the module:

```lua
return { extras = { agents = false } }
```

Editing, search, terminals, and navigation keep working without it.

## Layout

```text
init.lua                 entry point; adds this directory to runtimepath
lua/iara/init.lua        ordered composition (setup steps, safe mode)
lua/iara/config.lua      defaults, personal and trusted project layers
lua/iara/contracts.md    public module interfaces
lua/iara/core/           options, status and tab lines, start screen,
                         mappings, root, eligibility, processes
lua/iara/plugins/        lazy.nvim plugin specs
lua/iara/features/       search, terminal, structured navigation
lua/iara/languages/      explicit language policy
lua/iara/extras/         optional agents
lua/iara/theme/          theme engine and palettes
colors/                  :colorscheme iara-<name> entry points
scripts/                 bootstrap, tools, checks, tests, quality checker
bin/                     launcher
tests/                   mini.test suites, helpers, fixtures
```

## Development

```sh
scripts/tools.sh   # pinned development tools into .tools/
scripts/check.sh   # StyLua, Luacheck, quality checker, test suite
scripts/test.sh [tests/test_x.lua ...]        # tests only
nvim --clean -l scripts/quality.lua [PATH...] # quality checker only
```

The development tool installer targets Linux x86-64. `make lint-lua`
runs Luacheck for undefined globals, unused variables, and shadowing.
`make lint` also checks line length, function size, and complexity.
The pinned Luacheck binary requires glibc 2.38. Export `LUACHECK_BIN` to
use a locally installed Luacheck with `make tools`, lint, and pre-commit.

With `pre-commit` installed, enable the hook once per clone:

```sh
make tools
pre-commit install
```

The hook runs `make -k fmt-check lint` before each commit. GitHub Actions
runs `make check` on pull requests and pushes to `main`.

`test.sh` runs each test file in its own headless Neovim with its own
temporary XDG directories, `IARA_TEST_JOBS` files at a time (default:
the CPU count; `IARA_TEST_JOBS=1` runs them one by one). It prints one
line per file (status, seconds, cases), the slowest cases, the total,
then every failure and note; it exits nonzero when a case fails or a
file ends without a result (crash, or longer than
`IARA_TEST_FILE_TIMEOUT` seconds, default 600). Fixtures that several
files need, such as the plugin mirror, are built once per run
(`helpers.shared`). A file whose first lines contain
`-- iara-test: serial` runs alone after the others; `-- iara-test: slow`
starts it first.

Set `IARA_TEST_LUA_LS` to a `lua-language-server` executable to run the
optional LuaLS integration test.

### Make targets

Run `make` from the repository root (`make help` lists the targets). Each target
calls the scripts above; targets that change your directories accept
`DRY_RUN=1`.

| Target | Does |
| --- | --- |
| `tools` | `scripts/tools.sh` (run once) |
| `fmt`, `fmt-check` | StyLua write, or check only |
| `lint` | quality checker and Luacheck |
| `lint-quality` | length and complexity checks only |
| `lint-lua` | Luacheck only |
| `test` | all tests in parallel, or one file: `TEST=tests/test_x.lua` |
| `check` | `scripts/check.sh` (fmt-check, lint, tests) |
| `bench` | filename scoring benchmark, optional `BENCH_PATHS=100000` |
| `dev` | Open the live checkout with an isolated development profile |
| `gallery` | `scripts/gallery.lua $(GALLERY)` (default `start`) |
| `install`, `install-default` | see "Install with make" |
| `update`, `repair`, `rollback` | bootstrap `--update` and so on |
| `restore`, `backups` | restore latest or `BACKUP=<dir>`; list |
| `uninstall` | move Iara's paths into a backup |
| `clean` | remove `iara-test.*` and similar dirs in `$TMPDIR` |

`NVIM_BIN` selects Neovim (`NVIM` is the server address in terminals).
Run `make test TEST=tests/test_x.lua` while editing and `make check`
before integrating. The suite caches its test mirrors in
`.tools/test-mirrors`, keyed by pins and the mirror recipe. Set
`IARA_TEST_MIRROR_CACHE` to another absolute directory to use a
different cache.

Git is used to fetch pinned plugins and to report the checkout's revision
when available. `make update` builds from the local source files. Use
`git pull` first if you want to update those files from a configured remote.

`make dev` loads the checkout's `init.lua` and modules directly. Its
configuration, state, and pinned dependencies live in `.tools/dev`.
The first run for a set of pins and a Neovim version provisions the
dependencies. To pass Neovim arguments, use `scripts/dev.sh <args>`.
A pinned plugin missing after `git pull` is fixed by `:IaraRepair` or
`make repair`.

Try a checkout without installing it or touching any configuration:

```sh
NVIM_APPNAME=iara-dev nvim -u /absolute/path/to/iara/init.lua
```

Run `make lint` to check the code quality rules in `scripts/quality.lua`.
