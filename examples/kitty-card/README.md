# A card drawn in a pane, no native window

`card.py` draws a two-button card inside an ordinary Rex pane and takes clicks on it.
Nothing here is macOS-specific: it uses only what a Rex client must already speak.

Run it in a pane:

```sh
python3 examples/kitty-card/card.py
```

Click a choice. The card redraws as answered and writes the answer through the Rex
API (`session.set_block_label`), so the result is visible in the tab and can be read
back with `rex block ls`.

## Asking an agent's question

`ask.lua` turns the card into a question an agent can wait on:

```sh
rex do examples/kitty-card/ask.lua --action ask \
  question='Ship the split view?' choices='yes=Ship it|no=Wait' \
  answer=/tmp/demo/answer.json --json
```

It opens the card in its own tab and returns `answer_file`, `block_id` and `window_id`
immediately; the agent polls the file instead of blocking. Clicking writes
`{"id": "yes", "title": "Ship it", "block_id": "..."}` and sets the pane's label to
`chose: Ship it`. Verified end to end: the action opened the pane, an injected click at
the button's cells produced that file and label.

Two things this cost, worth knowing:

- **`shell = "none"` silently ignored `command`** when creating a window through
  `rex.session.new_window`, starting a login shell instead. Without `shell`, the command
  runs through the user's shell, which also finds their `PATH`.
- ImageMagick may not be on a pane's `PATH`, so the card resolves `magick` itself.

## Where this is still a prototype

`ask.lua` is a script you run by path, not an installed action, and the card has no
cancel button: an unanswered question simply leaves the pane there and the file
missing. Nothing here is Rex drawing the controls — that is still the roadmap item, and
`../../docs/native-choice-block.md` is the proposal for it. The pane is
also per-tab state: if the pane is closed before an answer, the agent waits forever, so
give the poll a deadline.

## What Rex answered when asked directly

Sent from inside a pane, on Rex 0.1.0-preview.23 (macOS client 0.1.0-snapshot.2182):

| Query | Reply | Meaning |
| --- | --- | --- |
| `CSI ? 1003 h` + `CSI ? 1006 h`, then a click | `\x1b[<0;57;20M` … `m` | SGR mouse press/release with cell coordinates |
| `CSI 14 t` | `\x1b[4;384;640t` | pixel geometry reported |
| kitty graphics query `\x1b_Gi=31…a=q` | `\x1b_Gi=31;OK` | the graphics protocol is implemented |
| kitty keyboard (`CSI > 1 u`) | `\x1b[97;1:3u` | keys arrive in kitty keyboard encoding |

`1002h` (button-event tracking) produced nothing; `1003h` (all-motion) works.

## What this proves, and what it does not

Drawing and hit-testing work with no accessibility permission, no overlay window, no
WebKit, and no Mac-only API. The same program should work in any Rex client that
implements those protocols, including on a phone.

It is a card, not a chat client. A real one still has to own: a text field (cursor,
selection, IME for non-Latin input), scrolling, accessibility for screen readers,
redraw after scroll or reattach, and the bandwidth cost of sending frames over a
remote host. Text entry is the hard part; bubbles and buttons are not.

## What a full-pane repaint costs

`transcript.py` renders a scrolling view of a real pane and logs every frame
(`/tmp/kitty-transcript.csv`). Scrolling is driven with `rex send -b BLOCK k`, which
is more reliable than synthetic key events: OS-level keycodes are layout-dependent
(`40` types `e` here) and the wheel never reached the program.

Measured on this machine, Rex 0.1.0-preview.23, a 50-row pane, one frame including
rasterising:

| render scale | per frame | rate | data per frame |
| --- | --- | --- | --- |
| 0.25 | 0.38 s | 2.7 fps | 0.54 MB |
| 0.5 | 0.43 s | 2.3 fps | 2.18 MB |
| 1.0 | 0.93 s (max 1.57 s) | 1.1 fps | 8.71 MB |

`hybrid.py` is the split that measurement argues for, and it is cheaper by orders of
magnitude: the transcript is printed as text (a scroll repaint is **0 ms for 1,239
bytes**), and only the decision card is an image (111–404 ms, 359 KB, drawn when it
changes rather than when the transcript moves). Its button hit-testing is pinned by
`test_hybrid.py` — which caught two real bugs: a wheel event over the card was being
treated as a click (SGR encodes the wheel as button 64 in the same shape), and the card's
column was only right for the pane width it was first tried in.

The click path was verified end to end by writing the exact bytes a mouse produces
(`\x1b[<0;63;6M`) with `rex block call -b BLOCK write`: the run logged `0,0,api`,
redrew the card (189 ms, 359 KB), and the pane's label became
`chose: Mac + iOS together`. Set `HYBRID_DEBUG=1` to log every raw input chunk to
`$HYBRID_LOG.raw`, which is how the escape sequences were confirmed to arrive intact.

Every pixel scroll redraws the whole pane, because Kitty has no "shift the image up one
line". So a static card is comfortable and a **smooth scroll is not**: even a quarter
resolution tops out near 3 fps, which matches the community reports of Kitty graphics
lag in Rex. Scroll repaint is exercised — a frame is drawn only when the offset
changes — but the visual proof is the card above; another agent on this machine kept
switching the visible session while I tried to screenshot the scrolled state.
