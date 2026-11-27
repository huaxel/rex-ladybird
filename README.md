# rex-extensions

Ways to extend and customize [Rex](https://www.superlogical.com/rex), the terminal
multiplexer: small modules that add actions, pickers, panes and palettes to it, plus
the notes on Rex's extension surfaces that make writing your own one cheap.

Each extension is a plain Rex module — a directory on Rex's `package.path` with an
`init.lua` — so nothing here is a plugin API. The repository is a collection, an
installer, and a shared test rig; you can take one extension and ignore the rest.

| extension | what it gives you | needs |
| --- | --- | --- |
| [`rex-ladybird`](extensions/rex-ladybird/) | A real browser in a Rex pane: pick an address from Chrome's history, follow a page's links, click its controls, switch tabs. Plus `ladyctl`, which drives the same browser from a script or an agent with no Rex at all | a Ladybird build with terminal mode |
| [`tui-launcher`](extensions/tui-launcher/) | One key, a list of the tools you actually run (from atuin history), launched in the focused pane's folder | `atuin`, `sqlite3` |
| [`appearance`](extensions/appearance/) | Terminal palettes applied through the terminal's own `set_theme`, Tokyo Night included, no restart | nothing |
| [`rexchat`](extensions/rexchat/) | A read-only local web view of sessions as conversations, sorted by which one is waiting on you | `python3` |

[`docs/extending-rex.md`](docs/extending-rex.md) is the guide: every surface Rex
exposes to Lua, what each one is good for, and which extension here demonstrates it.

### Elsewhere

Some Rex extensions are big enough to want their own repository, their own CI and
their own release notes. They are not vendored here; these are the ones this
collection is built alongside:

| project | what it gives you |
| --- | --- |
| [`rex-worktrunk`](https://github.com/haxybaxy/rex-worktrunk) | Project and Git worktree pickers driven by [worktrunk](https://github.com/max-sixty/worktrunk): pick a repo, pick a worktree, one Rex session per worktree, remove one safely |
| [`rex-sessionizer`](https://github.com/haxybaxy/rex-sessionizer) | One key, a fuzzy list of your project directories, a session for whichever you pick — the `tmux-sessionizer` loop |
| [`awesome-rex`](https://github.com/haxybaxy/awesome-rex) | A curated list of tools, plugins and integrations for Rex — the place to look before writing one of these yourself |

The rule of thumb: a self-contained program wrapped for Rex (worktrunk, atuin,
`fzf`) earns its own repo; a few hundred lines that register actions, pickers and
panes belongs in the collection.

## Install

```sh
git clone https://github.com/huaxel/rex-extensions ~/projects/rex-extensions
cd ~/projects/rex-extensions && ./install.sh
```

`./install.sh` with no arguments installs every extension: it symlinks each extension
where Rex looks for modules, links the helpers into `~/.local/bin`, and adds one line to
`~/.config/rex/init.lua`:

```lua
require("rex-extensions").setup{}
```

That line loads whatever is linked, so installing another extension later does not touch
the file again. Before keeping it the installer runs `rex config check`; if Rex rejects
the result, the file is restored byte for byte. A config that no longer loads costs you
every key you had, which is worse than not being installed.

Name extensions to install only those, and use the same variables as before for a
different prefix or another account's config:

```sh
./install.sh appearance rex-ladybird
PREFIX=/usr/local ./install.sh
REX_CONFIG=/path/to/init.lua ./install.sh
```

Bindings are yours to choose, in the same `init.lua` — every action also appears in Rex's
command palette, grouped by category. This is the set the extensions were built with:

```lua
require("rex-extensions").setup{}
rex.bind("ctrl+b>a", "tui_launcher")
rex.bind("ctrl+b>y", "terminal_theme")
rex.bind("ctrl+b>w", "ladybird_open")
rex.bind("ctrl+b>l", "ladybird_new")
rex.bind("ctrl+b>u", "ladybird_url")
rex.bind("ctrl+b>k", "ladybird_links")
rex.bind("ctrl+b>c", "ladybird_click")
rex.bind("ctrl+b>n", "ladybird_tab_new")
rex.bind("ctrl+b>b", "ladybird_tabs")
rex.bind("ctrl+b>x", "ladybird_tab_close")
```

Then `rex config reload`, and `rex keymap` to check they were picked up.

Removing one is the same command in reverse. It unlinks only what the installer could
have made — a directory, or a symlink into somewhere else, is somebody's work and is
refused — and it leaves the load line alone, because that line loads whatever is
linked:

```sh
./install.sh --remove tui-launcher
```

## How Rex finds these

Rex resolves `require("name")` off `package.path`, with `~/.config/rex` on it, so the
directory name under `~/.config/rex` *is* the module name. The installer therefore makes
one symlink per extension (`~/.config/rex/rex-ladybird` → `extensions/rex-ladybird`), and
each extension also works on its own:

```lua
require("rex-ladybird").setup{}
```

`init.lua` at the root is the collection's own module. It puts
`extensions/?.lua` on `package.path` (so a bare checkout works with nothing installed),
loads the extensions in its `local MODULES` list, and passes per-extension options
through:

```lua
require("rex-extensions").setup{
  extensions = { "appearance", "rex-ladybird" },
  options = { ["rex-ladybird"] = { hide_status_line = false } },
}
```

A name or option that does not exist is refused where it is written, rather than failing
later inside an extension.

## Adding an extension here

An extension is a directory with an `init.lua`; the rest is convention, and the suite
checks it.

```
extensions/<name>/
├── init.lua       the module: options, setup(), actions, and what is checkable
├── README.md      what it is for, what it needs, its keys
├── bin/           optional helpers, linked onto PATH by the installer
└── test/run.sh    optional; the repository runner calls it if it exists
```

- **Add the name to `local MODULES` in the root `init.lua`.** Nothing else loads it, and
  `test/manifest_check.py` fails when the list and the directories disagree.
- **`setup(opts)` validates and registers, and returns the module.** An unknown option is
  an error naming the option, not a silent no-op. Keep defaults in `M.options` so the
  error can be precise.
- **Name actions `snake_case`, give them a `title`, a `description`, a `category` for the
  palette, `keywords` for search, and an `args` schema** (`{ url = "string?" }`) when
  they can be driven from the command line: `rex do ladybird_open url=https://example.com`.
- **Errors say what to do.** `no Ladybird pane to drive; open one with ctrl+b l` beats
  `attempt to index a nil value`, especially from a picker that cannot show a stack trace.
- **State goes in its own directory** under `${XDG_STATE_HOME:-~/.local/state}/<name>`,
  so two extensions never share a file.
- **Do not type into a terminal when the program has a channel.** `rex-ladybird` writes
  APC commands into the pty; `tui-launcher` types only because a shell has no channel.
- **Test against the fake.** `test/fake_rex.lua` is an in-memory Rex that records every
  call, and `test/helper.lua` gives a test `section`, `check`, `error_of` and a fresh copy
  of the module. Neither needs a server, a browser or a terminal. See
  `extensions/appearance/test/theme_test.lua` for the smallest example.
- **Say what you cannot check.** The launcher's suite needs a running Rex and skips
  loudly when there is none; CI has no Rex, so that skip is the honest state.

## Tests

```sh
bash test/run.sh
```

The runner checks the scope trap (`test/scope_check.py` rejects a name read above the
`local` that declares it), the module list (`test/manifest_check.py`), the collection
module itself, then each extension's `test/run.sh`, shellcheck, the Python helpers, and
the installer against a temporary account. `LUA_BIN` points it at a Lua 5.1 interpreter
if `luajit`, `lua5.1` or `lua` is not on your `PATH`; it also looks in the nix store,
because a skipped suite that reads as green is worse than a slow lookup. CI runs the
same script on Linux and macOS.

## Platform

macOS is where these were built and measured. Linux is expected to work and has been run
in CI, not by hand: the modules read XDG directories and find `wl-copy`, `xclip` or
`xsel`. `bin/ladybird-import-chrome-cookies` decrypts with the macOS Keychain, so cookie
importing is macOS-only. Windows is untested.

## License

MIT, see [`LICENSE`](LICENSE). `extensions/rex-ladybird/patch/ladybird-status-line.patch`
is a diff against [Ladybird](https://github.com/LadybirdBrowser/ladybird), which is
BSD-2-Clause: the patched files stay Ladybird's, and the patch is offered under their
terms.
