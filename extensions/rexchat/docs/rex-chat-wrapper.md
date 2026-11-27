# A chat UI over Rex: what the screenshots are actually using

Notes on Ben Tossell's `rex-chat` (X, 26 Nov 2026): a chat interface, on iOS and Mac, wrapped
around Rex sessions. He reports building it "in like 2 prompts" and that the functionality is
good "because it's just rex under the makeup". These notes read the two screenshots against the
Rex CLI and server API to say which primitives make that cheap, which parts are the wrapper's
own invention, and what a phone still cannot get from a terminal.

Not a proposal for this repository. Nothing here needs Ladybird; it is background for how Rex is
being used as a substrate.

## What the screens show

Left image: two chat panes side by side, a session sidebar, per-session state badges. Right
image: a Rex session where the agent runs `xcodebuild -version` and proposes two
architectures, then asks the person to choose platform via a card of buttons.

| What you see | Where it comes from |
| --- | --- |
| Session list grouped by project (`rex-chat`, `bites`, `posts`), `Archived 24` | `session.list`, `.label`; grouping/archiving is the wrapper's own bookkeeping |
| `Needs you` inbox at the top | Program Status Protocol `state=blocked` on the session's blocks — `com.superlogical.terminal.program_status`, event `terminal.program_status_changed` |
| Green `Done` in the pane header | The same protocol's `finished` state (`failed` for failures) |
| Animated glyph on some rows vs an `R` badge | `working`, and the block's program identity |
| Indented `Test child thread 1..3` under a parent | Sessions carry no parent. Either the wrapper's grouping or agent subagent naming rendered as an outline |
| Header `Opus 5.5 · Medium` picker | The wrapper's own model/effort selector, passed to the agent it launches |
| Divider `claude-opus-5-5 · thinking medium` | The agent's own output, parsed. Not a Rex primitive |
| Chat transcript, markdown, monospace paths | `com.superlogical.terminal.format` with `format=html`, or a live `data.connect` stream; markdown rendering is the wrapper's |
| Bubbles, composer, tabs, close button | Pure wrapper. `terminal.write` sends the text the person types |
| `droid is asking` card with buttons, `or type your answer below`, `Show terminal` | Implementation unverified. Rex offers a similar flow for `rex.ui.pick` / `rex.ui.input`; that does not establish how Droid prompts reach this UI. |

Two of those rows are the whole product: the status inbox and the prompt card. Everything else,
Rex already has a view for, and the wrapper is re-drawing it for a thumb.

## The two things a terminal on a phone cannot do

**Blocked-state triage.** `terminal.program_status_changed` gives a program's own claim about
what it is doing — `idle`, `working`, `blocked` (with `kind`, e.g. `permission`), `finished`,
`failed` — with a message. A terminal can only paint that on a tab header. A chat app can sort
forty sessions into "needs you" and "done", and notify on the transition, which is the thing
Rex's own docs say they intend to add (push to mobile, a priority inbox).

**Answering a question with a control, not keystrokes.** `client_prompt_requested` asks a
connected app to put a question to the person; the answer comes back through `client.reply` as
`{"text": …}`, `{"ids": […]}` or `{"cancelled": true}`. The server sends it to every app that can
show it, the first answer ends it everywhere, and the rest get `client_prompt_ended`. That is a possible route for prompts from Rex Lua actions, not evidence that the screenshot uses it.

## What a minimal wrapper needs

Reading only, enough for the left screenshot:

```sh
rex ls --json                                  # sessions, labels, state
rex session inspect SESSION --json             # windows, blocks, focus
rex api call -s "$REX_BLOCK" session.view '{}' # one snapshot of the layout
rex block call -b BLOCK program_status
rex block call -b BLOCK format '{"format":"html"}'
```

Live rather than polling:

```sh
rex api call -s "$REX_BLOCK" session.attach_all '{}'   # events for the server, plus sessions
rex events --json                                     # the same stream, from the CLI
```

`session.attach_all` / `session.bootstrap` give a new connection the event stream and the session
list in one call; `data.connect` yields a ticket for streaming a block's content as it changes,
which is how you keep a transcript live without re-capturing the screen. Writing goes through
`com.superlogical.terminal.write`, the same path as `rex send`.

Two viable backends, and the choice is mostly about latency: shelling out to the `rex` CLI is a
dozen lines and fine for an on-demand refresh, while a wrapper that shows a spinner while an agent
works wants the event stream. The CLI remains the safety net — `rex capture --trim` is what you
fall back to for anything the API does not model yet.

## What got built from these notes

`bin/rexchat` is a read-only session viewer. It uses `rex events --json --all` to refresh the
sidebar when Rex reports a session or status change. The selected terminal is still plain-text
snapshots, not structured chat messages or a data stream. See the README for the routes and how
to run it locally. Prompt replies and push notifications are out of scope.

## Notes

- **Nothing in the wrapper is a Rex plugin.** Ben's point about "bb + t3 come with their own
  bloat" is structural: a chat client is a Rex *client*, in Rex's own sense (`rex client ls`,
  `client.perform`, `client.reply`), not a second multiplexer with its own state. Session restore
  lives on the server, so reconnecting the app costs nothing.
- **The `WKWebView` shortcut buys the wrong thing here.** Image two settles on a Swift webview
  around the existing web app. It gets Mac + iOS in an afternoon, but the two features that make
  a phone client worth having — notification on `blocked`, and surviving backgrounding — are the
  two a webview does not give you. That is the argument for the wrapper eventually being native
  even though the UI is trivial.
- **`Show terminal` is the honest escape hatch.** A chat view of a terminal is a lossy view:
  alternate-screen programs, control sequences, and anything the agent printed that the parser
  did not recognise. Keeping the pane one tap away, and not pretending the transcript is the
  terminal, is what makes the loss acceptable.
- **Model and effort are not Rex's.** The badges are the wrapper's, and the transcript divider is
  the agent's own text. Anyone building this should keep that split, or the client starts to
  guess at state it does not own.
