# appearance

Terminal palettes, applied through the terminal's own `set_theme` block method.
Nothing is written to a config file and nothing restarts: the colors change in the
panes you already have.

```lua
require("rex-extensions").setup{}          -- or require("appearance").setup{}
rex.bind("ctrl+b>y", "terminal_theme")
```

Then `rex do terminal_theme` applies Tokyo Night to the block you are in, or pick
"Appearance: apply a terminal theme…" from the command palette.

| option | default | meaning |
| --- | --- | --- |
| `theme` | `"tokyo-night"` | the palette `terminal_theme` applies when it is not given one |

`rex do terminal_theme theme=tokyo-night` names a theme explicitly. A theme's palette
entries are `index=#RRGGBB` for the terminal's own slots: Tokyo Night sets 0–21 (0–7
normal, 8–15 bright, 16–21 beyond those), and any slot a theme leaves out keeps its
built-in color. The terminal's palette runs to 255.

## Add a palette

```lua
local appearance = require("appearance")
appearance.register{
  name = "paper",
  foreground = "#111111",
  background = "#ffffff",
  cursor = "#111111",
  scheme = "light",
  palette = { "0=#000000", "1=#990000" },   -- as many slots as you want to set
}
```

`register` is also the extension to copy: it is the smallest module in the
collection, one action over one block method, with a test that never touches a
terminal (`test/theme_test.lua`).

## Tests

```sh
bash extensions/appearance/test/run.sh
```
