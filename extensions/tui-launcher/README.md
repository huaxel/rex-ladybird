# tui-launcher

One key, a list of the tools you actually run, launched in the focused pane's
folder. The index comes from shell history (atuin), so it is made of the programs
you run, not of a list someone maintains.

```lua
require("rex-extensions").setup{}          -- or require("tui-launcher")
rex.bind("ctrl+b>a", "tui_launcher")
```

Needs `atuin` (for its `history.db`) and `sqlite3`. The action is also in the
command palette under "Launch", and it can be driven without a picker:

```sh
rex do tui_launcher pick=btop          # run a tool by name
rex do tui_launcher command=lazygit    # run any line
rex do tui_launcher dry=true --json    # print the index instead of asking
```

## What it offers

- **Tools you use**, one row each, with run count and age.
- **A row per target** for tools whose argument names one: `ssh alpha` and
  `ssh beta` are different things.
- **The focused pane's folder**, read from the terminal's `process` and `pwd`
  methods, so the tool opens where you were working. A shell tab is opened and the
  command typed at its prompt, so quitting the tool leaves a shell there.
- **Sessions, applications and Rex actions** in the same list, so it doubles as a
  launcher for everything else. Typed text is routed by shape: a URL goes to
  `ladybird_open` when that action exists, a folder opens a tab there, anything
  else is run as a command.

What counts as a TUI is in the file: at least `MIN_RUNS` runs, used within
`MAX_AGE_DAYS`, and mostly staying longer than `LONG_RUN_SECONDS`, which is what
separates `btop` from `ls`. A blocklist keeps the long runners that are still not
tools to launch out of the list.

| variable | meaning |
| --- | --- |
| `TUI_LAUNCHER_DB` | the atuin history database to read (default: the XDG one) |
| `TUI_LAUNCHER_DRY` | print the index instead of opening the picker |

## Tests

```sh
bash extensions/tui-launcher/test/run.sh
```

The suite builds a fixture history shaped like real use — a TUI that sits for
minutes, a one-shot that returns at once, a build that is long but never a tool — and
checks what the picker would show. It needs a running Rex (the index includes the
live server's sessions and the client's own actions), so it skips loudly when there
is none; CI has none.
