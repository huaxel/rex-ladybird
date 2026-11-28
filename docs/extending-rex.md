# Extending Rex

Everything in this repository is made of the surfaces below, and every surface is
reachable from a single Lua file. This is the guide to those surfaces: what each one
gives you, what it costs, and which extension here demonstrates it.

Nothing here is a plugin API. Rex has no extension registry, no manifest and no
installer; it has a config file, `require`, and a server whose methods you can call.
Understanding that is most of understanding how to extend it.

## Three shapes, and which one you want

| shape | what it is | example |
| --- | --- | --- |
| **config only** | `rex.bind` and `rex.action` written straight into `~/.config/rex/init.lua`. No files, no module, nothing to install. | a palette action, a key that splits a pane |
| **a module** | a directory on `package.path` whose `init.lua` registers actions in `setup(opts)` | [`appearance`](../extensions/appearance/init.lua) (smallest), [`rex-ladybird`](../extensions/rex-ladybird/init.lua) (largest) |
| **a client** | a program outside Rex that reads and drives it: the CLI, the API, or terminal output | [`ladyctl`](../extensions/rex-ladybird/bin/ladyctl), [`rexchat`](../extensions/rexchat/bin/rexchat) |

Start with config only. Move to a module when the file has a helper, an option, or a
test in it, and to a client when Rex should not have to be running.

## How Rex finds a module

Rex runs Lua 5.1 and resolves `require("name")` off the ordinary `package.path`, with
`~/.config/rex` on it. So:

- the **directory name is the module name**: `~/.config/rex/appearance/init.lua` is
  `require("appearance")`;
- a symlink into a checkout works, and `git pull` is the update;
- `rex config reload` re-reads the config, and `rex config check` loads it and reports
  what it found **without** touching the running server. Use `check` as a gate before
  `reload`: a config that fails to load costs you every key you had.

The collection's [`init.lua`](../init.lua) is itself a module: it adds
`extensions/?.lua` to `package.path`, so a bare checkout works with nothing installed,
then loads the extensions listed in its `local MODULES`.

```lua
require("rex-extensions").setup{
  extensions = { "appearance", "rex-ladybird" },        -- nil loads them all
  options = { ["rex-ladybird"] = { hide_status_line = false } },
}
```

## Actions

An action is where an extension becomes visible: it gets a row in the command palette,
it can be bound to a key, and it can be run by name from a shell.

```lua
rex.action{
  name = "ladybird_open",                      -- snake_case, stable: keys and scripts name it
  title = "Ladybird: open address…",           -- the palette row
  description = "Pick from history or type an address, and load it in the pane.",
  category = "Browser",                        -- groups the palette
  keywords = "ladybird browser web page url",  -- what a search should match
  args = { url = "string?" },                  -- optional arguments, for scripts
  run = function(ctx, args) return M.open(ctx, args and args.url) end,
}
```

- **`ctx`** is where the action was invoked from: `ctx.block_id` for the focused block
  and `ctx.session_id` for its session. Treat both as hints — the block may be gone by
  the time you use it.
- **`args`** is the schema applied: `"string?"`, `"boolean?"` and their non-optional
  forms. That is what makes `rex do ladybird_open url=https://example.com` work, and it
  is why an action with no schema cannot be driven from a shell.
- **Return a table** to make `rex do` print it; `--json` prints it as JSON. The
  launcher returns `{ action = "worktree", index_ms = 12 }` from a dispatch, which is
  what makes it scriptable.
- **Raise on failure.** `error("no Ladybird pane to drive; open one with ctrl+b l", 0)`
  reaches the person in the palette and the shell in `rex do` — the `0` keeps Lua's file
  and line prefix out of it.

`rex.bind("ctrl+b>w", "ladybird_open")` attaches a key; `rex.unbind` takes it away. A
binding may pass arguments: `rex.bind("ctrl+b>ctrl+b", "pane.send_key", { key = "ctrl+b" })`.
`rex keymap` shows the merged result — the config's bindings and each client's — with the
line each one came from, which is the fastest way to find out why a key is not yours.

## Pickers

`rex.ui.pick` is the reason to build Rex extensions rather than typing into a shell:
a fuzzy list over your own data, drawn by the app, not by your program.

```lua
local choice, why, detail = rex.ui.pick{
  title = "Ladybird: open address",
  placeholder = "Filter history, or type an address or search",
  allow_other = true,                          -- typed text comes back as a choice
  items = { { id = "https://example.com/", title = "Example Domain",
              subtitle = "example.com", icon = "globe", detail = "3× today" } },
}
```

- `choice` is the `id` of the picked row, or — with `allow_other` — a table with the
  typed `text`.
- `why` says why there is no choice: `"cancelled"` (a person said no), `"unsupported"`
  or `"no_client"` (no app can draw a prompt, usually an app older than the server).
  Handle the second pair loudly: it is a broken installation, not a decision.
- It blocks. `rex do` waits for an answer; a command palette row waits for one too.
- `rex.ui.input{ title=…, placeholder=…, value=…, confirm=… }` is the one-line form, for
  a rename or a URL. `rex-worktrunk`'s session rename is the worked example.

## Panes, windows and layers

A **window** is a tab. A **block** is a pane. A **layer** is a floating block in front of
a window.

```lua
local pane, err = rex.session.new_split{
  anchor_id = ctx.block_id,          -- beside this block
  direction = "horizontal", side = "after", ratio = 0.5, focus = true,
  layout = rex.layout.block{
    flavor = "com.superlogical.terminal.shell",   -- the block type to create
    label = "Ladybird",
    options = { cwd = cwd, command = { argv0, arg1 } },
  },
}
```

- `new_window` opens a tab, `new_block` creates one with no place in a layout yet,
  `new_layer` floats one. `session.move_block` puts a detached block somewhere.
- The **`layout.block` options belong to the creator**, so they are worth
  discovering: `rex api call block_creator.list` prints each flavor's schema. For a
  shell that is `cwd`, `command`, `args`, `theme`, `initial_input`, `login` and a few
  more. `initial_input` types something at the prompt for you, which is usually better
  than writing to the pty once the block exists.
- **Full-window views**: `session.zoom_block` makes a block fill its window while the
  others keep running behind it; leave `zoom` out to toggle. Rex-ladybird's
  tabs are blocks plus zoom, and the code comments record why layers were tried first
  and abandoned: they detached from every window.
- Everything returns `(result, err)` and returns `nil, err` rather than raising, so a
  pane that could not be created is a message you write, not a traceback in the palette.

## Blocks are typed, and the types are not yours

A block is not a rectangle of terminal — it is an instance of a **flavor** provided
by a **creator**, and the flavor decides what the block is and what it can do. On
this machine there are three creators and four flavors:

```text
com.superlogical.terminal   shell    shell, command, args, login, interactive, cwd,
                                     path_prepend, size, theme, initial_input, exit
com.superlogical.tunnel     dial     host, port, client_address
                            listen   address, port, client_target
com.superlogical.onboarding onboarding step
```

`rex api call block_creator.list` prints that with each option's schema, and
`session.describe_block` prints one block's methods, events and actions. The
options *are* the interface: `initial_input` types something at a shell's prompt,
`command` runs a program there, `exit` decides what happens when it ends.

**A Lua extension cannot add a creator or a flavor, and no API pretends otherwise:**
the script global has `session`, `block`, `layout`, `action`, `ui`, `exec` and the
rest, but nothing that registers a block type, and the server exposes
`block_creator.list` alone. A new flavor is a change to the server *and* to every
client that must draw it — which is why the interesting extensions here are built
out of what already exists:

- a **program in a shell block** is a new pane type without a new flavor
  (`rex-ladybird` runs a browser, `tui-launcher` runs whatever you picked);
- a **client** is a whole app against the same API (`ladyctl`, `rexchat`);
- an **action** is a new verb over blocks that already exist.

So when an idea needs a picker that stays on screen until answered, a native
question widget, or a form, it is a Rex feature proposal rather than an extension:
two implementations, a contract for stale answers, and a rule that an older client
must not answer on the user's behalf. [`native-choice-block.md`](native-choice-block.md)
is that kind of proposal.

## The server API, and block methods

Two calls cover most of it:

```lua
local sessions = rex.call("session.list")                    -- { sessions = { ... } }
local view = rex.call("session.view", { session_id = id })    -- windows, layouts, blocks
rex.call("session.zoom_block", { session_id = id, block_id = block_id, zoom = true })
```

`rex api list` prints every method the server has, and `rex api describe METHOD` prints
its schema, examples and validation rules. The ones an extension reaches for:
`session.list`, `session.view`, `session.focus_block`, `session.zoom_block`,
`session.set_label`, `session.set_block_label`, `block.close`, `client.keymap`,
`client.queue`, `block_creator.list`, `target.complete`.

Blocks have methods too, called by creator name:

```lua
rex.block.call("com.superlogical.terminal", "write",
  { block_id = id, data = "\27_ladybird;open;https://example.com\27\\" })
rex.block.call("com.superlogical.terminal", "set_theme", { block_id = id, background = "#1a1b26" })
```

For a terminal the useful ones are `write` (type text, as if a person typed it),
`format` (the screen and scrollback as text or HTML), `process` (what is running, and
where), `pwd`, `program_status` (the OSC 7501 protocol behind "needs you"), `ports`,
`set_theme`, `resize`. Each returns `(result, err)`.

**Two rules worth knowing.** Some methods (`set_theme`, `resize`) apply at once only if
the caller owns the block or no client does; otherwise they wait for ownership, and an
extension should say so rather than pretend. And `set_theme` is partly appending: empty
color fields fall back to the built-in colors, but palette slots are deltas that stay
until the block is closed, so "apply a theme" has no matching "unapply". And reading a terminal's screen is a
snapshot, not a stream — `data.connect` is the streaming door, and it is a different
kind of program (a client, not a module).

## Running programs

```lua
local result = rex.exec({ "/usr/bin/sqlite3", "-separator", "\t", database, query },
                        { timeout = 5000 })
-- result.ok, result.stdout, result.stderr, result.code
```

`rex.exec` takes an **argv table** — no shell, no quoting bugs, and no `os.execute`:
Rex's sandbox refuses it with a message that says to use `rex.exec`. Run `{"sh", "-c", …}`
when you need shell syntax, and treat `nil` (could not run) differently from `ok == false`
(ran and failed). A timeout is worth setting for anything that talks to a database or a
network.

## Events, scripts and clients

- **Scripts**: `rex do path/to/script.lua` runs a file with the same `rex` API, and
  `rex.args` holds the `key=value` arguments. `rex.after(seconds, fn)` and
  `rex.every(seconds, fn)` schedule work — but **not during `rex.sleep`**: a script
  that slept to let a timer fire measured zero callbacks, because a pause is not
  the script running. Wait on an event with `rex.wait` instead of sleeping on a
  timer. A script that registers `rex.on`
  handlers keeps running and receives events (`--all` for every session), pausing with
  `rex.sleep(seconds)` and `rex.wait(event, filter, timeout)` until `rex.stop(code)`.
  This is how you watch Rex rather than react to a key. See `rex do --help`.
- **`rex.invoke(name, args)`** runs another action from inside yours — how the launcher
  dispatches to `ladybird_open` or to a `rex-worktrunk` action without knowing it exists.
  Look for the action first (`rex.call("client.keymap")` lists them) and treat a missing
  one as a normal absence, not an error.
- **`rex.client.queue("session.select", {...})`** asks the app to show something. Do not
  move someone's view by calling the server method: the queue makes it a client action,
  so it happens in the app the person is looking at.

## Patterns that keep an extension honest

These are decisions this repository made the hard way, and they are cheap to copy.

1. **Validate options at `setup`, name the option in the error.** `unknown appearance
   option: background`, not a missing inkwell three keystrokes later. Keep defaults in
   `M.options` so the error can say what *is* allowed.
2. **Detect by what a block runs, not by its label.** Labels are user-editable and
   truncated in the status line; `process` says `Ladybird` or `/bin/zsh`. Rex-ladybird
   builds its whole targeting story on that.
3. **Prefer the program's own channel to typing.** Writing an APC command into the pty
   is exact and survives a slow terminal; typing is a guess about focus, timing and
   prompt state. Type only when there is no channel (a shell has none).
4. **Keep state in `${XDG_STATE_HOME:-~/.local/state}/<name>`**, one directory per
   extension, and drop entries whose blocks no longer exist when you read it.
5. **Errors are the interface.** A picker cannot show a stack trace, and `rex do` exits
   non-zero: `no element e3`, `waited 10s for the page to mention "Saved"`,
   `no such rex extension: …` are all worth more than `attempt to index a nil value`.
6. **Never edit a config without a way back.** The installer writes one line, runs
   `rex config check`, and restores the file byte for byte if Rex rejects it.
7. **Do not register an action twice.** Two `setup` calls for the same extension mean
   two palette rows and a key binding that resolves to one of them; the installer
   replaces the old single-extension load line instead of adding to it.

## Testing without Rex

A module can be checked without a server, a browser or a terminal. `test/fake_rex.lua`
puts an in-memory `rex` in place of the real one — sessions, blocks, status lines,
pickers, and every `exec` handler — and records each call in order:

```lua
local Fake = require("fake_rex")
local t = require("helper")
t.extension_dir = here .. "/.."
local fake = Fake.install()
local M = t.load_module{ binary = "/tmp/Ladybird", ladyctl = "/tmp/ladyctl" }

fake:set_status("block:1", "● Example — https://example.com/")
M.open({ block_id = "block:1" }, "https://example.org/")
t.check("open is one APC command", fake:last_call("block").params.data == "…")
```

`HOME` and `XDG_STATE_HOME` point into a temporary directory, so the files an extension
writes are real files a test reads back.

It cannot cover: how Rex lays out panes, whether a picker renders, or whether a program
in a pane responds. Those are what a live check is for — and when one is impossible, say
so in the extension's `test/run.sh` and skip loudly rather than quietly.

## Recipes

| you want | surface | look at |
| --- | --- | --- |
| a key that runs something in the focused folder | `process`/`pwd` + `new_window` + `write` | [`tui-launcher`](../extensions/tui-launcher/init.lua) |
| a picker over your own data | `rex.ui.pick` with `items` | [`tui-launcher`](../extensions/tui-launcher/init.lua), [`rex-ladybird`](../extensions/rex-ladybird/init.lua) |
| a palette-only action with no key | `rex.action` alone | [`appearance`](../extensions/appearance/init.lua) |
| restyle something | a block method (`set_theme`) | [`appearance`](../extensions/appearance/init.lua) |
| open a full-window view | `new_split` + `zoom_block` | `M.tab_new` in [`rex-ladybird`](../extensions/rex-ladybird/init.lua) |
| a question that outlives a tab switch | a card pane + an answer file | [`ask.lua`](../examples/kitty-card/ask.lua) |
| a program outside Rex that drives it | CLI + API | [`ladyctl`](../extensions/rex-ladybird/bin/ladyctl), [`rexchat`](../extensions/rexchat/bin/rexchat) |

To ask a question in the app and return the answer to a shell script, use `rex do`
with a picker directly. This prints the selected ID as JSON without typing into a pane:

```sh
rex do -e 'local id, why = rex.ui.pick{title="Build target", items={{id="mac", title="Mac"}, {id="ios", title="iOS"}}}; return {choice=id, reason=why}' --json
```

A connected Rex app must answer the prompt. On cancellation, check `reason` rather
than treating the missing choice as a default.

That prompt is modal: it pauses the action and closes on the first answer. When the
question should stay visible while you keep working — or be answered on another device
later — open a card pane instead and let the answer arrive as a file:

```sh
rex do examples/kitty-card/ask.lua --action ask \
  question='Ship the split view?' choices='yes=Ship it|no=Wait' answer=/tmp/answer.json --json
```

The action returns at once with `answer_file`; the click writes
`{"id", "title", "block_id"}` there and sets the pane's label.

## Finding out what your Rex can do

The API is discoverable from the installed version, which is the only documentation
that cannot drift:

```sh
rex do --help                  # the Lua API, scripts, rex.on, rex.args
rex actions --json             # every action, with its arguments
rex api list                   # every server method, grouped, block methods included
rex api describe session.new_split
rex api call block_creator.list # the block flavors this server can make, and their options
rex keymap                     # what each key does, and which line bound it
rex config check               # does the config load, and what did it define
```

## Pixels or cells

A pane is a terminal, and Rex answers the protocol questions a graphics program asks:
`\x1b_Gi=31…a=q` comes back `OK`, so the Kitty graphics protocol is available from any
pane. That makes an in-pane app with real buttons possible without a native window, an
overlay, or an accessibility permission — `examples/kitty-card/card.py` is one, and it
writes its answer back through `session.set_block_label`.

The cost decides when to use it. Measured here on Rex 0.1.0-preview.23:

| what is redrawn | per frame |
| --- | --- |
| the same pane as text cells (80×24) | 1,971 bytes, under a millisecond |
| the same pane as pixels, quarter scale | 0.54 MB, 0.38 s |
| the same pane as pixels, full scale | 8.71 MB, 0.93 s |

Kitty has no "shift the image up one line", so every scroll is a full repaint. Pixels
suit what changes rarely — a card, a decision, an image, a status strip — and cells suit
anything that scrolls, gets selected, copied, or read by a screen reader. A chat view
wants cells for the transcript and pixels only for the chrome.
