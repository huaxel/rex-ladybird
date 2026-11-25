# rex-ladybird

Rex integration for Ladybird's terminal mode (`--headless=terminal`). Rex owns the
pickers and the layout; Ladybird owns the page.

`ctrl+b w` picks an address from your browser history and loads it in the pane. From
there it is an ordinary browser: click links, `alt+←` to go back, scroll with the
wheel. Scripts and agents get the same browser from the command line, without Rex.

## What you need

- **Rex**, the terminal multiplexer (0.1.0-preview or newer). This is a Rex module: it
  uses `rex.ui.pick`, `rex.session.new_split` and the action registry, so without Rex it
  does nothing. Rex is in preview and is not installable from this repository — if you
  do not already run it, read this as a worked example rather than a drop-in. The two
  browser surfaces it drives (the APC command channel and the DevTools subset) are
  documented below and are useful on their own, with any terminal client.
- **A Ladybird build with terminal mode** (`--headless=terminal`). A source build — the
  release app does not have it. Looked for in `~/projects/ladybird`, `~/ladybird`,
  `~/src/ladybird` and `/Applications/Ladybird.app`, then `ladybird` on `PATH`;
  `LADYBIRD_BINARY` overrides all of it.
- **A terminal that draws graphics** with the Kitty graphics protocol — kitty, ghostty,
  wezterm. Terminal mode sends the page as images; elsewhere there is nothing to see.
- **python3** for `bin/ladyctl` and the optional cookie importer.

## Install

```sh
git clone https://github.com/huaxel/rex-ladybird ~/projects/rex-ladybird
cd ~/projects/rex-ladybird && ./install.sh
```

That links the checkout where Rex looks for a module, links `ladyctl` into
`~/.local/bin`, and adds the load line to `~/.config/rex/init.lua`. It asks nothing and
is safe to run again after a `git pull`. Before it keeps that line it runs
`rex config check`, and if Rex rejects the result the file is restored: a config that
no longer loads costs you every key you had. `PREFIX` moves the symlinks somewhere else
on `PATH`, `REX_CONFIG` installs into another account's config file.

Then the keys, in the same `~/.config/rex/init.lua`:

```lua
rex.bind("ctrl+b>w", "ladybird_open")
rex.bind("ctrl+b>l", "ladybird_new")
rex.bind("ctrl+b>u", "ladybird_url")
rex.bind("ctrl+b>k", "ladybird_links")
rex.bind("ctrl+b>c", "ladybird_click")
rex.bind("ctrl+b>n", "ladybird_tab_new")
rex.bind("ctrl+b>b", "ladybird_tabs")
rex.bind("ctrl+b>x", "ladybird_tab_close")
```

Then `rex config reload`. `rex keymap` should list the eight bindings; if they are
missing, the module was not found on Rex's `package.path` — the symlink above is what
puts it there.

The module locates `bin/ladyctl` beside itself, so a checkout works without the second
symlink; it falls back to `~/.local/bin/ladyctl` for a config-directory install.

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
| `ctrl+b>c` | `ladybird_click` | Pick any control the page offers — a button, a field, a menu item — and click it |
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

## Options

| option | default | meaning |
| --- | --- | --- |
| `binary` | `LADYBIRD_BINARY`, then the build paths above | the terminal-mode executable |
| `profile` | `${XDG_DATA_HOME:-~/.local/share}/ladybird-terminal-profile` | `--profile-path`, a persistent profile |
| `device_pixel_ratio` | `2` | passed through to the renderer |
| `label` | `"Ladybird"` | the pane label used for detection |
| `chrome_history` | the first Chrome-family `History` that exists | picker source; a missing file is an empty history |
| `history_items` | `400` | how many visits the picker offers |
| `devtools_port` | `9317` | first port of the range panes allocate from |
| `ladyctl` | `bin/ladyctl` beside the module | the CLI |
| `hide_status_line` | `true` | needs the patch below; harmless otherwise |

State lives in `${XDG_STATE_HOME:-~/.local/state}/rex-ladybird`. Passing
`--temporary-profile` is deliberately not an option: it throws cookies away on exit.

Launching a pane uses `--profile-path`, never `--profile NAME` — named profiles are
not created in headless mode (it makes an empty directory and no database).

## Platform

macOS is where this was built and measured. Linux should work and has not been run:
the module reads XDG directories, finds `wl-copy`, `xclip` or `xsel` for the clipboard,
and looks for Chrome, Chromium, Brave and Edge histories under `~/.config`.
`bin/ladybird-import-chrome-cookies` decrypts with the macOS Keychain, so importing
cookies is macOS-only. Windows is untested.

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
ladyctl ls              # the panes this module launched: block, port, address, title
ladyctl tabs            # the tabs inside one pane, with their real titles and URLs
ladyctl url | title     # current page
ladyctl links --limit 50
ladyctl snapshot        # number the controls (e1, e2, …) and read the page text
ladyctl eval 'document.querySelectorAll("a").length'
ladyctl click e2        # a ref from the last snapshot, or any CSS selector
ladyctl type e1 'ladybird browser' --clear --submit
ladyctl press tab enter
echo 'document.title' | ladyctl eval -
ladyctl wait --text Saved --timeout 10
ladyctl open https://example.com     # via DevTools, or the APC channel as a fallback
ladyctl back | forward | reload | quit
ladyctl focus | close   # hand a pane the keyboard, or close it
```

It reads the port and the pane from the same state directory as this module.

**Several panes are open?** `-b` picks which one, by block id, id suffix, or part
of the address it was opened at, and every command takes it:

```sh
ladyctl ls                             # block:7  9317  https://example.com/  Example Domain
ladyctl -b block:7 url                 # the full id
ladyctl url -b 7                       # the suffix
ladyctl snapshot -b example.com        # part of the address
```

Without `-b` a command drives the pane the module last opened, exactly as before.
A target that names two panes is refused rather than guessed, and `ls` marks the
panes whose port no longer answers (`live` in `--json`) instead of hiding them.

`snapshot` is what makes the page drivable rather than readable: it marks every
control it lists with `data-lb-ref`, so `click e3` is that control even after the
page has moved around, and it fails by name when the page no longer has it. The
text is capped at 20000 characters (`--max 0` for all of it), `--json` returns
the whole page as one object, and `--list` prints one control per line —
`ref<TAB>kind<TAB>label[<TAB>flags]` — for the Rex picker behind `ctrl+b>c`.

`type` writes real keystrokes into the pane with `rex send`, after focusing the
field through the page, so autocomplete, validation and framework models see the
same events a person's typing produces.

Exit status is meant for scripts: an unreachable DevTools server exits 1 with
`cannot reach the devtools server on PORT`, `click` exits 1 with
`no element matches SELECTOR` instead of reporting a silent no-op, `click e3`
exits 1 with `no element e3` when the snapshot is older than the page, and `eval`
exits 1 with `no evaluation result` when the script throws — Ladybird sends no
`evaluationResult` in that case, so an exception and a dead console look alike
from the client. `type` refuses to type when the field did not take focus rather
than sending the text to whatever has it, and `wait` names what it waited for and
how long: `waited 10s for the page to mention "Saved"`.

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

Ladybird does not accept pull requests from non-maintainers
([`CONTRIBUTING.md`](https://github.com/LadybirdBrowser/ladybird/blob/master/CONTRIBUTING.md)),
so this stays a local patch: `docs/PR-status-line.md` is the proposal, and a branch with
the same commit sits in [the fork](https://github.com/huaxel/ladybird/tree/terminal-status-line-toggle)
as a reference. Apply it to a checkout and rebuild:

```sh
cd path/to/ladybird
git apply path/to/rex-ladybird/patch/ladybird-status-line.patch
./Meta/ladybird.py build
```

Built and measured here: the page area grows by exactly one text row
(`window.innerHeight` 184 → 192 CSS px in a 48-row pane), the line stops being drawn,
and `ctrl-l` is swallowed while hidden. `ladyctl chrome off` sends the command, and an
unpatched browser answers with an `unknown command: chrome` notice.

The module sends `chrome off` to each new pane while `hide_status_line` is true, so an
unpatched browser loses nothing but five seconds of notice.

Build prerequisites that were missing on the machine this was developed on (macOS,
arm64): the autotools
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

## Contributing

`bash test/run.sh` runs everything the repository can check without a browser: the Lua
suite against a fake Rex, the CLI against a fake DevTools server, a scope check and
shellcheck. CI runs the same script on Linux and macOS. Bug reports are most useful when
they say which of the two surfaces failed — `ladyctl url` answering while the pane shows
nothing is a different problem from neither answering.

## License

MIT, see `LICENSE`. `patch/ladybird-status-line.patch` is a diff against
[Ladybird](https://github.com/LadybirdBrowser/ladybird), which is BSD-2-Clause: the
patched files stay Ladybird's, and the patch is offered under their terms.
