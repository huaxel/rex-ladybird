# Proposal: a choice that stays in a Rex pane

**Not a shipped API.** Today `rex.ui.pick` asks a question in the command palette. This proposal puts one question in a normal split, so the user can leave it unanswered, work elsewhere, and come back. It does not propose a chat client, a browser, a terminal graphics protocol, or a general widget toolkit.

## What was actually tried (2026-11-27, Rex 0.1.0-preview.23 server, macOS app 0.1.0-snapshot.2182)

| Attempt | Result |
| --- | --- |
| `rex.ui.pick` from a script run with `rex do ./x.lua --action …` | Returned `unsupported`. The action loads and registers; no picker appeared. |
| `session.new_split` with the built-in onboarding flavor, on a throwaway server | Created the block. Built-in client-drawn blocks work. |
| The same call with a made-up third-party flavor | `404 block flavor not found`. A plugin cannot simply name a new graphical flavor. |
| `rex server run --block-dir DIR` with an executable | Rex launched it, then dropped it with `connection info closed before reporting connection info: EOF`. Discovery works; the handshake is undocumented here. |
| A native window tracked over a full-tab Rex pane (SwiftUI, no WebKit) | Worked on Mac: the card drew over its tab, a press returned `{"selected":"mac"}` to the pane's stdout, and the window hid when the tab lost focus. |
| A real mouse click on a card button, then on its text field and Return | Both recorded (`{"selected":"mac"}`, `{"typed":"phone"}`) and **Rex stayed the frontmost app**. Getting there needed a nonactivating `NSPanel`; with `becomesKeyOnlyIfNeeded = true` the first keystroke leaked into the terminal underneath. |
| The same card in a 60/40 split, with focus moved to the other pane | The card landed exactly on its own terminal (482×858 at the right pane's origin, matching Rex's own accessibility frame) and kept accepting clicks while the neighbour held focus. |
| A click with no typing, comparing the pane before and after | One line changed: `{"selected":"mac"}`. No stray keystrokes reached the terminal, and after the answer the card gave the keyboard back, so later typing went to the pane. |

So the Mac route demonstrates the *interaction*, and the server route demonstrates that a block can hold state, but nothing yet shows the stock app drawing third-party controls. That gap is what the proposal below is about.

## What the user sees

An agent opens a split titled **Build target** next to its terminal. The pane asks “Which platforms should we build for?” and offers **Mac + iOS**, **Mac only**, and a text field for another answer. The user can switch tabs without answering. After submission the pane shows the accepted answer instead of disappearing. Closing an unanswered pane abandons the question; it never chooses the default.

The prototype in `examples/native-choice/` approximates this on macOS, using a tracked nonactivating `NSPanel` positioned from Rex's own accessibility frames, so it follows splits and the sidebar instead of guessing at chrome. It does not run on iOS, and it is not drawn by Rex: it is a window over one.

## What Rex would need to implement

- **Server:** one built-in block flavor accepting a title, ordered choices with stable IDs, and `allow_other`. Opening the block returns immediately; the caller need not keep a Lua action suspended. Keep one question per block for its lifetime.
- **Client:** one renderer for that flavor. Use platform controls for choosing, typing, submitting, and displaying the accepted answer. Plugins supply data, not Swift code or pixels. An older client with no renderer must not submit on the user's behalf.
- **Contract:** `state` returns the question and either `pending` or the accepted answer. `answer` accepts exactly one choice ID or typed text. Reject unknown IDs and reject text unless enabled. Atomically accept the first valid answer; a retry or competing device gets the already accepted state, never a second decision. Emit a change event after acceptance. On attach or reconnect, read `state` rather than depending on a missed event.
- **Agent integration:** pass the structured result to the agent that created the question. An answer is data, not keystrokes to whichever pane now has focus. If the agent has no structured reply interface, leave delivery out of the prototype.

## Acceptance test on stock clients once implemented

1. Create the question from a script. The Mac app shows native controls in a split; no palette opens and no web server or terminal renderer starts.
2. Switch tabs and return. The question is still pending. Disconnect and reattach: the same block and choices remain.
3. With Mac and phone showing the question, submit different choices nearly simultaneously. Both clients must converge on the same single answer. Reconnect one client after the event to check the snapshot path.
4. Repeat with a typed answer, an invalid option ID, and a pane closed without an answer. None should type into the terminal or run a command.

**Why this is a plausible Rex change:** the existing onboarding block already separates server-held state from client-drawn UI, and the [Custom UI API](https://www.superlogical.com/rex/docs/customize/custom-ui) already gives choices stable IDs and defines typed answers. Neither is evidence that today's third-party plugins can draw an arbitrary native view. Passing this test would demonstrate a persistent decision card, not yet an inline chat transcript or composer.
