# LibWebView: Let terminal mode give up its status line

This is a proposal, not a pull request. Ladybird's `CONTRIBUTING.md` is explicit that the
project "do[es] not accept pull requests from non-maintainers and do[es] not allow code
change proposals through any other route", so nothing was sent upstream. The branch lives
in the fork at `huaxel/ladybird` (`terminal-status-line-toggle`, rebased on current
`master`) as a reference implementation; the discussion belongs on the project's Discord,
where their contribution guide points design discussion.

## Why

Terminal mode reserves the bottom row for its own status line: the page title and URL,
the `ctrl-l` prompt, the shortcut hints, and notices. That is the right default for
`Ladybird --headless=terminal` run on its own.

It is the wrong thing when the terminal already has chrome of its own. A multiplexer
(tmux, zellij), an editor pane, or a terminal front end that owns its tab bar and address
bar wants the page to fill the pane; a second, unthemed address bar underneath it is dead
space that cannot be themed, sized, or dismissed.

Today there is no way to ask for that. The line is drawn to an absolute position (`CUP`
to the last row), so arranging for it to fall outside the pane does not help either: the
terminal clamps the cursor and the line lands on the last visible row anyway.

## What

A new command on the channel terminal mode already reads for navigation:

    ESC _ ladybird;chrome;off ESC \      # page fills the pane, no status line
    ESC _ ladybird;chrome;on  ESC \      # back to the default

With the status line off:

- `page_pixel_size()` keeps the last row, so the page is one row taller and the
  compositor viewport follows;
- the shortcut hints, the loading dot, the URL prompt and notices are not drawn, and the
  row they used to hold is cleared once;
- `ctrl-l` is swallowed instead of opening the prompt, because the prompt would be typed
  blind. The client that hides the line owns that key.

Existing behaviour is unchanged: the line is shown unless a client turns it off, and the
command reports `status line on`/`off` as a notice when it is visible.

## Notes for review

- `PaneGeometry::page_pixel_size` gains a `reserve_status_line` parameter rather than
  growing a second geometry type; the two call sites (`apply_pane_geometry`,
  `transmit_frame`) pass the current state.
- The command is a runtime toggle, not a flag, because the client knows when it wants the
  row back — a split ratio change, a floating layer, a full-screen toggle — and terminal
  mode already takes commands this way (`frames damage`).
- `chrome off` on a build without this change is answered with the existing
  `unknown command: chrome` notice, so a client can probe for support.

Commit: `LibWebView: Allow terminal mode to hide its status line`, kept in
`patch/ladybird-status-line.patch` and rebased onto upstream `master`.

## Checks

Built `Meta/ladybird.py build` (Release) on macOS 27.2 arm64 from `eae01b006b` and ran
`Ladybird --headless=terminal --device-pixel-ratio=2` in a terminal pane:

- The page area grows by exactly one text row: `window.innerHeight` 184 → 192 CSS px
  in a 48-row pane, and the status line stops being drawn (`ctrl-l url` gone from the
  screen).
- With the line hidden, `ctrl-l` is swallowed: sending it and then typing leaves no
  prompt behind and the page keeps its address.
- `chrome on` restores the line and the prompt.
- The `chrome` command is answered with the usual `unknown command: chrome` notice on a
  build without the change, so a client can probe for support.
