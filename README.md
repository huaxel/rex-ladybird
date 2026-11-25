# rex-ladybird

Rex integration for Ladybird's terminal mode (`--headless=terminal`). Rex owns the
pickers and the layout; Ladybird owns the page.

## Why

Ladybird's terminal mode already renders a real page in a Rex pane and exposes a
command channel on its own stdin:

```
ESC _ ladybird;open;<url> ESC \
```

That is the whole interface this module needs. Navigation is written into the
pane's pty, so the address bar can be a native Rex picker instead of the
in-terminal prompt, and no keystrokes are faked.

## Actions

| Binding | Action | What it does |
|---|---|---|
| `ctrl+b>w` | `ladybird_open` | Pick from Chrome + Ladybird history, or type an address/search, and load it |
| `ctrl+b>l` | `ladybird_new` | Open a Ladybird pane beside the focused one at the picked address |
| `ctrl+b>k` | `ladybird_links` | Pick a link from the page's current DOM and load it |
| `ctrl+b>n` | `ladybird_tab_new` | Open a new tab (block) beside the active one at the picked address |
| `ctrl+b>b` | `ladybird_tabs` | Pick an open tab and bring it to the front |
| `ctrl+b>x` | `ladybird_tab_close` | Close the picked tab |
| `ctrl+b>u` | `ladybird_url` | Read the address (DevTools when available, status line otherwise) and copy it |

Every action is also in Rex's command palette under "Browser", and the ones that open
something take `url=` so they can be driven from scripts:

```sh
rex do ladybird_open url=https://example.com
rex do ladybird_url --json
```

## How it finds the right pane

1. the focused block, when it is running Ladybird;
2. the block an earlier action drove (`~/.local/state/rex-ladybird/current`);
3. a pane with the exact configured label, then any pane whose label starts with it.

Detection asks the terminal what the block is running
(`com.superlogical.terminal.process`, matching `Ladybird`/`Ladybird.app`) rather
than scraping the status line, which is truncated to the pane width.

## Install

```sh
git clone <this repo> ~/projects/rex-ladybird
ln -sfn ~/projects/rex-ladybird ~/.config/rex/rex-ladybird
ln -sfn ~/projects/rex-ladybird/bin/ladyctl ~/.local/bin/ladyctl
```

The module finds `bin/ladyctl` beside itself, so a checkout works without the second
symlink; it falls back to `~/.local/bin/ladyctl` for a config-directory install.

## Setup

```lua
-- ~/.config/rex/init.lua
require("rex-ladybird").setup{}
rex.bind("ctrl+b>w", "ladybird_open")
rex.bind("ctrl+b>l", "ladybird_new")
rex.bind("ctrl+b>u", "ladybird_url")
```

Options: `binary`, `profile` (the `--profile-path` directory), `device_pixel_ratio`,
`label`, `chrome_history`, `history_items`, `devtools_port`, `ladyctl`,
`hide_status_line`. The profile must be the persistent one;
`--temporary-profile` throws cookies away on exit. State lives in
`${XDG_STATE_HOME:-~/.local/state}/rex-ladybird`.

Launching a pane uses `--profile-path`, never `--profile NAME` — named profiles are
not created in headless mode (it makes an empty directory and no database).

## Known limits

- Chrome's History file is read with `?immutable=1` because Chrome holds a lock on it;
  a very recent visit may be missing from a picker until Chrome flushes.
- Ladybird writes `History.db` lazily, so until it exists the picker is Chrome-only.
- The status line cuts a long URL at the pane width; with the patch applied the address
  should be read from DevTools (`ladyctl`), which is what this module does first.
- Picker answers come from `rex.ui.pick`; `rex do ladybird_open` will wait for one.

## `ladyctl` — the CLI half

`bin/ladyctl` reaches the same browser without Rex's help, so scripts,
agents and other tools use the same two surfaces:

```sh
ladyctl tabs            # every tab, with its real title and URL
ladyctl url | title     # current page
ladyctl links --limit 50
ladyctl eval 'document.querySelectorAll("a").length'
ladyctl click 'a[href="/pulls"]'
ladyctl open https://example.com     # via DevTools, or the APC channel as a fallback
ladyctl back | forward | reload | quit
```

It reads the port and the pane from the same state directory as this module.

Exit status is meant for scripts: an unreachable DevTools server exits 1 with
`cannot reach the devtools server on PORT`, `click` exits 1 with
`no element matches SELECTOR` instead of reporting a silent no-op, and `eval`
exits 1 with `no evaluation result` when the script throws — Ladybird sends no
`evaluationResult` in that case, so an exception and a dead console look alike
from the client.

## The two surfaces, and what each is good for

**APC command channel** — `ESC _ ladybird;<command>;<argument> ESC \` written into the
pane's pty. Terminal mode implements exactly `open`, `back`, `forward`, `reload`,
`quit`, `frames`. No port, no extra process, works over ssh; write-only.

**Firefox Remote Debugging Protocol** — `--devtools=PORT` (also accepted in headless
mode). Length-prefixed JSON over TCP, and the parts worth knowing:

```text
root     listTabs                          -> tabs[].{actor,title,url,browserId}
tab      getWatcher                        -> watcher actor
tab      navigateTo {url} | goBack | goForward
tab      reloadDescriptor {bypassCache?}   | getFavicon
watcher  watchTargets {targetType:"frame"} -> target-available-form
target   {actor, consoleActor, inspectorActor, threadActor, styleSheetsActor}
frame    reload | goBack | goForward | listFrames | listWorkers | detach
console  evaluateJSAsync {text}            -> resultID, then evaluationResult
```

There is no `attach` on the tab or frame actor — the child actors arrive in the
`target-available-form` payload, and `evaluateJSRequest` does not exist; the console
accepts `evaluateJSAsync` only.

**Files** — `data/Ladybird.db` (cookies, storage), `History.db`, `Sessions.db` for
anything that is not live.

## Where a new surface would go

If a query is not covered, the cheapest addition is another command in terminal
mode's `handle_command` (one `if` in `LibWebView/TerminalWebView.cpp`) which replies
over the same APC channel: `ladybird;url` → `ESC _ ladybird;state;<url>;<title> ESC \`.
That is upstreamable and small, whereas scraping the status line is bounded by pane
width and the DevTools server requires a port and a second connection.

## Tabs

A tab is a Ladybird block: `ladybird_tab_new` splits beside the active tab, gives the
new block its own DevTools port, and records `block_id<TAB>port<TAB>url` in
`${XDG_STATE_HOME:-~/.local/state}/rex-ladybird/tabs`. A pane opened with
`ladybird_new` is the same thing without the zoom, so both appear in the picker and
neither reuses a port. Entries whose block has left its window are dropped when the
registry is read, so closing a pane by hand needs no cleanup. Every tab is its own process but they all share
one `--profile-path`, and therefore one cookie jar: headless instances skip the
profile coordination the GUI does, so nothing refuses the second one. Measured on
this machine: three tabs, three processes, one profile, all live at once.

Showing a tab is `session.zoom_block`, so the active page fills the window while the
other tabs stay laid out behind it with their programs still running. Switching is
therefore free (no reload) and does not touch the pty.

**Layers do not work for this.** `session.new_layer` does create a full-window
floating layer, and `set_layer_state` does minimize and raise it, but the layers did
not survive: the blocks ended up detached from every window (still running, no longer
reachable through `session.view`), which is why tabs are blocks plus zoom instead.

Each tab is a full browser, so memory scales with tab count (the UI process plus its
WebContent children). Closing tabs matters more here than in a normal browser.

## Hiding terminal mode's own status line

The bottom row is drawn by Ladybird and cannot be disabled from outside: it is
positional (`CUP` to the last row), so giving the pty a fake extra row does not help —
the terminal clamps the cursor and the line still lands on the last visible row
(verified against Rex/Ghostty). `patch/ladybird-status-line.patch` adds the small change
that makes it optional:

- `ESC _ ladybird;chrome;off ESC \` (and `on`) toggles it at runtime;
- with it off the page fills the whole pane, and `ctrl-l` is swallowed instead of
  opening a prompt that would be typed blind.

The change is committed on a branch in `~/projects/ladybird` as
`LibWebView: Allow terminal mode to hide its status line`
(`terminal-status-line-toggle`), and `docs/PR-status-line.md` holds the description to
open it upstream. Apply it to any checkout with `git apply` and rebuild:

```sh
cd ~/projects/ladybird && git apply ~/projects/rex-ladybird/patch/ladybird-status-line.patch
./Meta/ladybird.py build
```

Built and measured here: the page area grows by exactly one text row
(`window.innerHeight` 184 → 192 CSS px in a 48-row pane), the line stops being drawn,
and `ctrl-l` is swallowed while hidden. `ladyctl chrome off` sends the command, and an
unpatched browser answers with an `unknown command: chrome` notice.

This module uses `~/projects/ladybird/Build/release/bin/Ladybird.app` when it exists and
falls back to `/Applications/Ladybird.app`, with `hide_status_line = true` sending
`chrome off` to each new pane. Set either option to change that.

Build prerequisites that were missing on this machine (macOS, arm64): the autotools
vcpkg wants for `gperf`/`skia` (`brew install autoconf autoconf-archive automake
libtool make`), a `libtoolize` shim so Apple's `libtool` stays first on `PATH` (skia
links with `libtool -static`), and the pinned Rust toolchain from `rust-toolchain.toml`
(1.98.0 plus `rust-src`) wired in with `-DRUST_CARGO=` / `-DRUST_RUSTC=` — a newer
toolchain fails the build because `Atomic::fetch_update` is deprecated under `-Dwarnings`.

## Tests

```sh
bash test/run.sh
```

The Lua tests run `init.lua` against `test/fake_rex.lua`, an in-memory Rex that records
every call, so the command channel, the tab registry, port allocation, the pickers and
the fallback from DevTools to the status line are checked without a browser. `HOME` and
`XDG_STATE_HOME` point into a temporary directory, so the registry files are real files
the tests read back. `run.sh` also runs `test/scope_check.py`, which rejects a name read above the `local`
that declares it (the trap that makes a helper look nil at run time), and checks that
the Python helpers compile.

Not covered: the patch itself (needs a compiled browser — see the build recipe above),
and anything that requires Rex to actually lay out panes.
