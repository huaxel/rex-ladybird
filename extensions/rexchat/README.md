# rexchat

A read-only, chat-shaped view of Rex sessions in a browser. Sessions on the left,
one block's output on the right, and the list ordered by which session is waiting
on you rather than by name.

```sh
./install.sh rexchat      # from the repository root
rexchat --port 8787       # prints the URL it bound; open that
```

`--port 0` picks a free port, `--tail N` sets how many characters of scrollback
to show. It listens on `127.0.0.1` only.

| Route | What it answers |
|---|---|
| `/` | the page: sessions on the left, one block's output on the right |
| `/api/sessions` | every session, its terminals, and each program's claim about what it is doing |
| `/api/transcript?block=ID` | one block's terminal output as plain text |
| `/api/stream` | server-sent session and program-status change notifications |

The list is sorted by the Program Status Protocol rather than by name: a session
with a block waiting on you (`blocked`, from OSC 7501, per `rex block call
program_status`) comes first, then sessions with a failure, then everything else.
That ordering is the point — with forty sessions running, "which one wants me" is
the only question worth a home screen.

There is no endpoint that writes to a terminal, so the view cannot type into
someone's work, and it exposes terminal output only to a local browser. Do not
publish or forward the port.

On narrow screens the page opens on the session list. Select a terminal to see its
output, then use **← Sessions** to return. Wide screens keep both panes visible.

The sidebar refreshes on `rex events --json --all`, with polling if the stream
disconnects. **Follow** periodically re-captures the selected terminal; this is not
output streaming. If the scrollback exceeds one reply, the view labels the available
text as the oldest output rather than presenting it as the current tail.

It drives the `rex` on `PATH` (`REX_BIN` overrides it) rather than speaking the
server's socket protocol, so it needs no plugin and no Rex version beyond the CLI.

## Why it is here

It is the smallest version of the thing Rex has no view for: sessions as a list of
conversations rather than a tiled screen. `docs/rex-chat-wrapper.md` reads Ben
Tossell's `rex-chat` screenshots against the Rex CLI and server API, saying which
primitives make that cheap and which parts are the wrapper's own invention — useful
background if you are considering the same view.

## Tests

```sh
bash extensions/rexchat/test/run.sh
```

`test/rexchat_test.py` points `REX_BIN` at a script that answers the read-only calls
the view makes, to pin the properties an edit would quietly break: which state reaches
the "needs you" list, that the transcript shows the newest output, and that no route
reaches a block method that types into a terminal.
