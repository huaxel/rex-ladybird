#!/usr/bin/env python3
"""Contract tests for bin/rexchat against a fake `rex`.

The view is read-only by construction, so the properties worth pinning are the
ones a later edit would quietly break: which state reaches the "needs you" list,
that the transcript shows the newest output rather than the oldest, that a reply
too large for one call says so instead of lying, and that no path reaches a
block method that types into a terminal. A live Rex cannot run in CI, so
REX_BIN points at a script that answers the five calls the view makes and
records every one of them.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REXCHAT = Path(__file__).resolve().parent.parent / "bin" / "rexchat"

# Records each call and answers from one JSON file, so a test says what Rex
# would have said without building a server.
FAKE_REX = '''#!/usr/bin/env python3
import json, os, sys, time

args = sys.argv[1:]
assert args.pop(0) == "--autostart=false"
with open(os.environ["FAKE_REX_LOG"], "a") as log:
    log.write(" ".join(args) + "\\n")

with open(os.environ["FAKE_REX_DATA"]) as handle:
    data = json.load(handle)

def answer(value):
    print(json.dumps(value))
    raise SystemExit(0)

def refuse(message):
    sys.stderr.write(message + "\\n")
    raise SystemExit(1)

if "FAIL" in data.get("mode", ""):
    refuse(data["mode"])
if args[:1] == ["events"]:
    # A stream: echo what the test appends to FAKE_REX_EVENTS, then keep the
    # connection open the way `rex events` does. FAKE_REX_EVENTS_EXIT models a
    # stream that ends at once, which is what a server restart looks like.
    if os.environ.get("FAKE_REX_EVENTS_EXIT"):
        raise SystemExit(0)
    path = os.environ.get("FAKE_REX_EVENTS", "")
    printed = 0
    while True:
        try:
            with open(path) as handle:
                lines = handle.read().splitlines()
        except OSError:
            lines = []
        while printed < len(lines):
            print(lines[printed], flush=True)
            printed += 1
        time.sleep(0.05)

if args[:1] == ["ls"]:
    answer({"sessions": data["sessions"]})

if args[:2] == ["block", "ls"]:
    session = args[args.index("-s") + 1] if "-s" in args else ""
    answer({"blocks": data.get("blocks", {}).get(session, [])})

if args[:2] == ["block", "call"]:
    block = args[args.index("-b") + 1]
    method = args[args.index("-b") + 2]
    methods = data.get("methods", {}).get(block, {})
    if method not in methods:
        refuse(f"block {block} has no method {method!r}")
    answer(methods[method])
    raise SystemExit(0)

refuse("unknown command: " + " ".join(args))
'''

TERMINAL = "com.superlogical.terminal"


def block_id(name: str) -> str:
    return f"block:aaaa{name}"


def terminal(name: str) -> dict:
    return {
        "block_id": block_id(name),
        "label": "shell",
        "creator_name": TERMINAL,
        "flavor": "com.superlogical.terminal.shell",
    }


def status(state: str, **rest: object) -> dict:
    return {"records": [{"state": state, "app": "claude-code", "effective_app": "claude-code", **rest}]}


class RexChatTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.log = self.root / "calls.log"
        self.data = self.root / "data.json"
        self.events = self.root / "events.jsonl"
        self.events.touch()
        self.fake = self.root / "rex"
        self.fake.write_text(FAKE_REX)
        self.fake.chmod(0o755)
        self.server: subprocess.Popen | None = None
        self.streams: list = []

    def tearDown(self) -> None:
        for stream in self.streams:
            stream.close()
        if self.server is not None:
            self.server.terminate()
            try:
                self.server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.server.kill()
            for stream in (self.server.stdout, self.server.stderr):
                if stream is not None:
                    stream.close()
        self.directory.cleanup()

    # ---------------------------------------------------------------- helpers

    def serve(self, data: dict, events_exit: bool = False) -> str:
        self.data.write_text(json.dumps(data))
        environment = dict(
            os.environ,
            REX_BIN=str(self.fake),
            FAKE_REX_LOG=str(self.log),
            FAKE_REX_DATA=str(self.data),
            FAKE_REX_EVENTS=str(self.events),
        )
        if events_exit:
            environment["FAKE_REX_EVENTS_EXIT"] = "1"
        else:
            environment.pop("FAKE_REX_EVENTS_EXIT", None)
        self.server = subprocess.Popen(
            [sys.executable, str(REXCHAT), "--port", "0"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert self.server.stdout is not None
        url = self.server.stdout.readline().strip()
        self.assertTrue(url.startswith("http://"), f"no URL from the server: {url!r}")
        return url

    def get(self, url: str, path: str) -> tuple[int, dict]:
        try:
            with urllib.request.urlopen(url + path, timeout=30) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def calls(self) -> list[str]:
        # A request the view rejects before it reaches Rex leaves no log at all.
        if not self.log.exists():
            return []
        return self.log.read_text().splitlines()

    def emit(self, block: str, kind: str = "program_status_changed") -> None:
        """Append one event, the way `rex events` would deliver it."""
        event = {
            "type": "session_event",
            "payload": {
                "session_id": "session:idle",
                "event": {
                    "type": "block_event",
                    "payload": {"block_id": block, "creator_name": TERMINAL, "name": kind, "payload": {}},
                },
            },
        }
        with self.events.open("a") as handle:
            handle.write(json.dumps(event) + "\n")

    def open_stream(self, url: str):
        stream = urllib.request.urlopen(url + "/api/stream", timeout=20)
        self.streams.append(stream)
        return stream

    def frame(self, stream) -> dict:
        """The next `data:` frame, ignoring heartbeats."""
        while True:
            line = stream.readline()
            if not line:
                self.fail("the event stream closed")
            text = line.decode().strip()
            if text.startswith("data: "):
                return json.loads(text[len("data: ") :])

    def frame_with(self, stream, predicate, what: str) -> dict:
        while True:
            frame = self.frame(stream)
            if predicate(frame):
                return frame

    def two_sessions(self) -> dict:
        return {
            "sessions": [
                {"session_id": "session:idle", "label": "idle-one"},
                {"session_id": "session:busy", "label": "build"},
            ],
            "blocks": {
                "session:idle": [terminal("idle")],
                "session:busy": [terminal("busy"), terminal("other")],
            },
            "methods": {
                block_id("idle"): {"program_status": status("done")},
                block_id("busy"): {
                    "program_status": status("blocked", kind="question", msg="QXBwcm92ZSAzIGFwcGxpZXM/"),
                },
                block_id("other"): {"program_status": status("working")},
            },
        }

    # ------------------------------------------------------------------ tests

    def test_blocked_sessions_are_the_ones_that_need_you(self) -> None:
        url = self.serve(self.two_sessions())
        _, body = self.get(url, "/api/sessions")
        sessions = {session["label"]: session for session in body["sessions"]}
        self.assertEqual(sessions["build"]["state"], "blocked")
        self.assertTrue(sessions["build"]["needs_you"])
        self.assertFalse(sessions["idle-one"]["needs_you"])
        self.assertEqual(sessions["idle-one"]["state"], "done")
        # Whoever is waiting on a person comes first, whatever order Rex listed.
        self.assertEqual(body["sessions"][0]["label"], "build")
        busy = sessions["build"]["blocks"]
        self.assertEqual([block["state"] for block in busy], ["blocked", "working"])
        # The protocol base64s free text; the view hands it back readable.
        self.assertEqual(busy[0]["message"], "Approve 3 applies?")
        self.assertEqual(busy[0]["kind"], "question")

    def test_a_session_with_no_terminal_is_listed_not_dropped(self) -> None:
        data = {
            "sessions": [{"session_id": "session:empty", "label": "nothing-here"}],
            "blocks": {"session:empty": [{"block_id": block_id("x"), "label": "Chart", "creator_name": "com.example.chart"}]},
            "methods": {},
        }
        url = self.serve(data)
        status_code, body = self.get(url, "/api/sessions")
        self.assertEqual(status_code, 200)
        self.assertEqual(body["sessions"][0]["blocks"], [])
        self.assertEqual(body["sessions"][0]["state"], "idle")

    def test_the_transcript_is_the_newest_output(self) -> None:
        lines = "".join(f"line {number}\n" for number in range(400))
        data = self.two_sessions()
        data["methods"][block_id("idle")]["format"] = {"content": lines}
        data["methods"][block_id("idle")]["title"] = {"title": "parcel-dashboard"}
        url = self.serve(data)
        _, body = self.get(url, f"/api/transcript?block={block_id('idle')}&tail=1000")
        self.assertTrue(body["trimmed"])
        self.assertFalse(body["truncated"])
        self.assertTrue(body["content"].endswith("line 399\n"), body["content"][-40:])
        self.assertEqual(body["title"], "parcel-dashboard")
        # The tail is taken here, not by asking Rex for a smaller reply, because
        # format answers from the oldest line.
        asked = [call for call in self.calls() if " format " in f" {call} "]
        self.assertEqual(len(asked), 1)
        self.assertNotIn("tail", asked[0])

    def test_an_oversized_reply_says_it_starts_at_the_oldest_line(self) -> None:
        data = self.two_sessions()
        data["methods"][block_id("idle")]["format"] = {"content": "head only", "id": 7, "total": 900_000}
        url = self.serve(data)
        _, body = self.get(url, f"/api/transcript?block={block_id('idle')}&tail=10")
        self.assertTrue(body["truncated"])
        self.assertFalse(body["trimmed"])
        self.assertEqual(body["content"], "head only")

    def test_a_bad_block_id_never_reaches_rex(self) -> None:
        url = self.serve(self.two_sessions())
        status_code, body = self.get(url, "/api/transcript?block=--help")
        self.assertEqual(status_code, 400)
        self.assertIn("block must be a Rex block ID", body["error"])
        self.assertEqual([call for call in self.calls() if "--help" in call], [])

    def test_nothing_can_type_into_a_terminal(self) -> None:
        url = self.serve(self.two_sessions())
        self.get(url, "/api/sessions")
        self.get(url, f"/api/transcript?block={block_id('idle')}")
        request = urllib.request.Request(url + f"/api/transcript?block={block_id('idle')}", method="POST")
        try:
            urllib.request.urlopen(request, timeout=30)
            self.fail("a POST was accepted")
        except urllib.error.HTTPError as error:
            self.assertEqual(error.code, 405)
            self.assertIn("only reads", json.load(error)["error"])
        forbidden = [call for call in self.calls() if " write" in f" {call}" or " send" in f" {call}"]
        self.assertEqual(forbidden, [])

    def test_rex_failing_is_reported_not_hidden(self) -> None:
        data = self.two_sessions()
        data["mode"] = "FAIL: rex is not running"
        url = self.serve(data)
        status_code, body = self.get(url, "/api/sessions")
        self.assertEqual(status_code, 502)
        self.assertIn("rex is not running", body["error"])

    def test_the_page_says_it_is_read_only(self) -> None:
        url = self.serve(self.two_sessions())
        with urllib.request.urlopen(url + "/", timeout=30) as response:
            page = response.read().decode()
        self.assertIn("Read-only", page)
        self.assertNotIn("terminal.write", page)

    def test_rejects_non_loopback_host(self) -> None:
        url = self.serve(self.two_sessions())
        request = urllib.request.Request(url + "api/sessions", headers={"Host": "example.test"})
        with self.assertRaises(urllib.error.HTTPError) as result:
            urllib.request.urlopen(request, timeout=5)
        with result.exception as error:
            self.assertEqual(error.code, 403)

    def test_session_creation_reaches_an_open_stream(self) -> None:
        url = self.serve(self.two_sessions())
        stream = self.open_stream(url)
        self.frame_with(stream, lambda frame: frame["state"] == "live", "a live frame")
        with self.events.open("a") as handle:
            handle.write('{"type":"session_created","payload":{"session":{"session_id":"session:new"}}}\n')
        self.frame_with(stream, lambda frame: frame["sessions"], "a list frame")

    def test_a_status_change_invalidates_the_cached_list(self) -> None:
        url = self.serve(self.two_sessions())
        _, before = self.get(url, "/api/sessions")
        self.assertEqual({session["label"] for session in before["sessions"] if session["needs_you"]}, {"build"})
        # The next read is inside the one-second cache; only the event can make
        # the view notice that the other session now wants a person.
        data = self.two_sessions()
        data["methods"][block_id("idle")]["program_status"] = status("blocked", kind="permission")
        self.data.write_text(json.dumps(data))
        stream = self.open_stream(url)
        self.frame_with(stream, lambda frame: frame["state"] == "live", "a live frame")
        self.emit(block_id("idle"))
        self.frame_with(stream, lambda frame: frame["sessions"], "a list frame")
        _, after = self.get(url, "/api/sessions")
        waiting = {session["label"] for session in after["sessions"] if session["needs_you"]}
        self.assertEqual(waiting, {"build", "idle-one"})

    def test_a_stream_that_ends_is_reported_not_hidden(self) -> None:
        url = self.serve(self.two_sessions(), events_exit=True)
        stream = self.open_stream(url)
        frame = self.frame_with(stream, lambda frame: frame["state"] == "down", "a down frame")
        self.assertIn("reconnecting", frame["error"])

    def test_help_explains_what_it_reads(self) -> None:
        result = subprocess.run([sys.executable, str(REXCHAT), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("only reads", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
