#!/usr/bin/env python3
"""Contract tests for bin/ladyctl against a fake DevTools server.

The CLI is what an agent or a script drives, so its exit codes are the
interface: a click that matched nothing, a script that threw, and a dead port
must not look like success. A real browser cannot be started in CI, so a
length-prefixed JSON server stands in for it and answers the four packets the
client actually sends.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

LADYCTL = Path(__file__).resolve().parent.parent / "bin" / "ladyctl"
TAB_ACTOR = "server0-tab1"
WATCHER_ACTOR = "server0-watcher1"
FRAME_ACTOR = "server0-frame1"
CONSOLE_ACTOR = "server0-console1"


class FakeDevTools:
    """A DevTools server that answers listTabs, getWatcher, watchTargets and evaluateJSAsync.

    `answers` decides what a script evaluates to. `with_result=False` reproduces
    Ladybird's behaviour for a throwing script: the console acknowledges the
    script and then never sends an evaluationResult.
    """

    def __init__(self, answers="clicked", with_result=True, hang_up=False):
        self.answers = answers
        self.with_result = with_result
        # hang_up models a server that accepts and then says nothing useful, the
        # way a browser still starting up does.
        self.hang_up = hang_up
        self.scripts: list[str] = []
        self.server = socket.socket()
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.port = self.server.getsockname()[1]
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.server.close()

    @staticmethod
    def read_packet(connection: socket.socket) -> dict | None:
        buffer = b""
        while b":" not in buffer:
            chunk = connection.recv(65536)
            if not chunk:
                return None
            buffer += chunk
        length, _, rest = buffer.partition(b":")
        size = int(length)
        while len(rest) < size:
            chunk = connection.recv(65536)
            if not chunk:
                return None
            rest += chunk
        return json.loads(rest[:size])

    @staticmethod
    def send(connection: socket.socket, body: dict) -> None:
        payload = json.dumps(body).encode()
        connection.sendall(b"%d:" % len(payload) + payload)

    def serve(self) -> None:
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                self.send(connection, {"from": "root", "applicationType": "browser", "traits": {}})
                if self.hang_up:
                    continue
                while True:
                    try:
                        packet = self.read_packet(connection)
                    except OSError:
                        # A client that hangs up mid-packet is normal: a liveness
                        # probe connects and closes without saying anything.
                        break
                    if packet is None:
                        break
                    self.answer(connection, packet)

    def answer(self, connection: socket.socket, packet: dict) -> None:
        kind = packet.get("type")
        sender = packet.get("from") or "root"
        if kind == "listTabs":
            self.send(connection, {
                "from": "root",
                "tabs": [{"actor": TAB_ACTOR, "title": "Example", "url": "https://example.com/"}],
            })
        elif kind == "getWatcher":
            self.send(connection, {"from": TAB_ACTOR, "actor": WATCHER_ACTOR})
        elif kind == "watchTargets":
            self.send(connection, {
                "from": WATCHER_ACTOR,
                "type": "target-available-form",
                "target": {"actor": FRAME_ACTOR, "consoleActor": CONSOLE_ACTOR},
            })
        elif kind == "evaluateJSAsync":
            self.scripts.append(packet.get("text", ""))
            self.send(connection, {"from": CONSOLE_ACTOR, "resultID": "result-1"})
            if self.with_result:
                self.send(connection, {
                    "from": CONSOLE_ACTOR,
                    "type": "evaluationResult",
                    "resultID": "result-1",
                    "result": self.answers,
                    "hasException": False,
                })
        else:
            self.send(connection, {"from": sender, "error": f"unknown packet {kind}"})


class LadyctlTests(unittest.TestCase):
    def run_cli(self, *arguments: str, port: int | None = None, environment: dict | None = None) -> subprocess.CompletedProcess:
        environment = dict(os.environ if environment is None else environment)
        environment.pop("LADYCTL_PORT", None)
        return subprocess.run(
            [sys.executable, str(LADYCTL)]
            + ([] if port is None else ["--port", str(port)])
            + list(arguments),
            capture_output=True, text=True, timeout=60, env=environment,
        )

    def test_click_reports_the_click(self) -> None:
        fake = FakeDevTools(answers="clicked")
        try:
            result = self.run_cli("click", "a[href]", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "clicked")
        self.assertIn("document.querySelector", fake.scripts[0])

    def test_click_without_a_match_fails(self) -> None:
        fake = FakeDevTools(answers="missing")
        try:
            result = self.run_cli("click", "#nope", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no element matches #nope", result.stderr)
        self.assertNotIn("clicked", result.stdout)

    def test_a_script_that_produces_no_result_fails(self) -> None:
        fake = FakeDevTools(with_result=False)
        try:
            result = self.run_cli("eval", "throw new Error('boom')", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no evaluation result", result.stderr)

    def test_eval_prints_the_value(self) -> None:
        fake = FakeDevTools(answers="Example Domain")
        try:
            result = self.run_cli("eval", "document.title", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Example Domain")

    def test_json_output_is_machine_readable(self) -> None:
        fake = FakeDevTools(answers="Example Domain")
        try:
            result = self.run_cli("--json", "eval", "document.title", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "Example Domain")

    def test_the_state_directory_follows_xdg(self) -> None:
        # The module honours XDG_STATE_HOME, so the CLI has to read the port from
        # the same place or the two halves of the setup stop finding each other.
        fake = FakeDevTools(answers="Example Domain")
        try:
            with tempfile.TemporaryDirectory() as home:
                state = Path(home, "xdg", "rex-ladybird")
                state.mkdir(parents=True)
                (state / "port").write_text(f"{fake.port}\n")
                environment = dict(os.environ, HOME=home, XDG_STATE_HOME=str(state.parent))
                result = self.run_cli("url", port=None, environment=environment)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "https://example.com/")

    def pane_environment(self, directory: Path) -> tuple[dict, Path, Path]:
        """An environment where the CLI finds a pane, and a `rex` that only records.

        Returns the environment, the log the fake `rex` writes, and its directory.
        """
        state = Path(directory, "state", "rex-ladybird")
        state.mkdir(parents=True)
        (state / "current").write_text("block:1\n")
        binaries = Path(directory, "bin")
        binaries.mkdir()
        rex = binaries / "rex"
        rex.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$REX_LOG"\n')
        rex.chmod(0o755)
        log = Path(directory, "rex.log")
        environment = dict(
            os.environ,
            HOME=str(directory),
            XDG_STATE_HOME=str(Path(directory, "state")),
            PATH=str(binaries) + os.pathsep + os.environ.get("PATH", ""),
            REX_LOG=str(log),
        )
        return environment, log, binaries

    @staticmethod
    def page(*elements: dict, text: str = "Hello") -> str:
        return json.dumps({"title": "Example", "url": "https://example.com/", "elements": list(elements), "text": text})

    def test_snapshot_numbers_the_controls(self) -> None:
        answer = self.page(
            {"ref": "e1", "kind": "text", "label": "Search", "value": "ladybird", "flags": []},
            {"ref": "e2", "kind": "button", "label": "Go", "value": None, "flags": ["disabled"]},
        )
        fake = FakeDevTools(answers=answer)
        try:
            result = self.run_cli("snapshot", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[e1] text "Search" = "ladybird"', result.stdout)
        self.assertIn('[e2] button "Go" [disabled]', result.stdout)
        self.assertIn("Hello", result.stdout)
        # The refs have to come from somewhere the next command can find them.
        self.assertIn("data-lb-ref", fake.scripts[0])

    def test_snapshot_list_is_one_control_per_line(self) -> None:
        # The Rex picker reads this without a JSON parser, so the shape is pinned:
        # ref, kind, label, then the flags when there are any.
        answer = self.page(
            {"ref": "e1", "kind": "link", "label": "Docs", "value": None, "flags": []},
            {"ref": "e2", "kind": "checkbox", "label": "Remember me", "value": None, "flags": ["checked"]},
        )
        fake = FakeDevTools(answers=answer)
        try:
            result = self.run_cli("snapshot", "--list", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["e1\tlink\tDocs", "e2\tcheckbox\tRemember me\tchecked"])

    def test_click_follows_a_snapshot_ref(self) -> None:
        fake = FakeDevTools(answers="clicked")
        try:
            result = self.run_cli("click", "e2", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("data-lb-ref", fake.scripts[0])
        self.assertIn("pointerdown", fake.scripts[0])
        self.assertIn("scrollIntoView", fake.scripts[0])

    def test_a_ref_the_page_no_longer_has_fails_by_name(self) -> None:
        fake = FakeDevTools(answers="missing")
        try:
            result = self.run_cli("click", "e9", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no element e9", result.stderr)

    def test_type_sends_real_keystrokes(self) -> None:
        fake = FakeDevTools(answers="focused")
        with tempfile.TemporaryDirectory() as home:
            environment, log, _ = self.pane_environment(Path(home))
            try:
                result = self.run_cli("type", "e1", "hello", "--submit", port=fake.port, environment=environment)
            finally:
                fake.close()
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text().splitlines()
        # The text and the Enter are keystrokes in the pane, not synthetic events.
        self.assertIn("send -b block:1 -- hello", calls)
        self.assertIn("send-key -b block:1 enter", calls)

    def test_type_does_not_type_when_the_field_does_not_focus(self) -> None:
        fake = FakeDevTools(answers="missing")
        with tempfile.TemporaryDirectory() as home:
            environment, log, _ = self.pane_environment(Path(home))
            try:
                result = self.run_cli("type", "e1", "hello", port=fake.port, environment=environment)
            finally:
                fake.close()
            self.assertEqual(result.returncode, 1)
            self.assertIn("no element e1", result.stderr)
            # Typing into whatever has focus would be worse than failing.
            self.assertFalse(log.exists(), "the CLI sent keystrokes to whatever had focus")

    def test_press_sends_the_keys_to_the_pane(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            environment, log, _ = self.pane_environment(Path(home))
            result = self.run_cli("press", "tab", "enter", port=None, environment=environment)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("send-key -b block:1 tab enter", log.read_text().splitlines())

    def test_wait_returns_when_the_condition_holds(self) -> None:
        fake = FakeDevTools(answers=True)
        try:
            result = self.run_cli("wait", "--selector", "#done", "--timeout", "5", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#done", fake.scripts[0])

    def test_wait_says_what_it_waited_for(self) -> None:
        fake = FakeDevTools(answers=False)
        try:
            result = self.run_cli("wait", "--selector", "#spinner", "--timeout", "0.4", port=fake.port)
        finally:
            fake.close()
        self.assertEqual(result.returncode, 1)
        self.assertIn("waited 0.4s for the page to show #spinner", result.stderr)

    def test_ls_shows_the_recorded_panes(self) -> None:
        fake = FakeDevTools(answers="Example Domain")
        with tempfile.TemporaryDirectory() as home:
            environment, _, _ = self.pane_environment(Path(home))
            # One pane answers, one has quit: the listing says which is which
            # instead of pretending both are usable.
            (Path(home, "state", "rex-ladybird", "tabs")).write_text(
                f"block:1\t{fake.port}\thttps://example.com/\nblock:2\t9\thttps://gone.example/\n"
            )
            try:
                result = self.run_cli("--json", "ls", environment=environment)
            finally:
                fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)
        self.assertEqual([row["block"] for row in rows], ["block:1", "block:2"])
        self.assertEqual([row["live"] for row in rows], [True, False])
        self.assertEqual(rows[0]["title"], "Example")

    def test_a_pane_that_listens_but_does_not_answer_is_still_listed(self) -> None:
        fake = FakeDevTools(hang_up=True)
        with tempfile.TemporaryDirectory() as home:
            environment, _, _ = self.pane_environment(Path(home))
            (Path(home, "state", "rex-ladybird", "tabs")).write_text(f"block:1\t{fake.port}\thttps://example.com/\n")
            try:
                result = self.run_cli("--json", "ls", environment=environment)
            finally:
                fake.close()
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(result.stdout)[0]
        self.assertTrue(row["live"], "the port answers, so the pane is live")
        self.assertIsNone(row["title"], "a title that was not read is not invented")
        self.assertEqual(row["url"], "https://example.com/", "the recorded address stands in")

    def test_a_block_target_picks_the_pane_to_drive(self) -> None:
        fake = FakeDevTools(answers="Example Domain")
        with tempfile.TemporaryDirectory() as home:
            environment, _, _ = self.pane_environment(Path(home))
            (Path(home, "state", "rex-ladybird", "tabs")).write_text(
                f"block:1\t9\thttps://elsewhere.example/\nblock:2\t{fake.port}\thttps://example.com/\n"
            )
            try:
                # The state file points at block:1; -b has to win over it.
                result = self.run_cli("url", "-b", "block:2", environment=environment)
                by_suffix = self.run_cli("url", "-b", "2", environment=environment)
                by_url = self.run_cli("url", "-b", "example.com", environment=environment)
            finally:
                fake.close()
        for result in (result, by_suffix, by_url):
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "https://example.com/")

    def test_an_ambiguous_target_asks_for_the_full_id(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            environment, _, _ = self.pane_environment(Path(home))
            (Path(home, "state", "rex-ladybird", "tabs")).write_text(
                "block:2\t9\thttps://a.example/\nblock:12\t10\thttps://b.example/\n"
            )
            result = self.run_cli("url", "-b", "2", environment=environment)
        self.assertEqual(result.returncode, 1)
        self.assertIn("matches 2 panes", result.stderr)

    def test_an_unknown_target_names_the_command_that_lists_panes(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            environment, _, _ = self.pane_environment(Path(home))
            (Path(home, "state", "rex-ladybird", "tabs")).write_text("block:1\t9\thttps://a.example/\n")
            result = self.run_cli("url", "-b", "nothing", environment=environment)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no recorded pane matches nothing", result.stderr)
        self.assertIn("ladyctl ls", result.stderr)

    def test_focus_and_close_take_a_target_to_rex(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            environment, log, _ = self.pane_environment(Path(home))
            focused = self.run_cli("focus", "-b", "block:1", environment=environment)
            closed = self.run_cli("close", "-b", "block:1", environment=environment)
            calls = log.read_text().splitlines()
        self.assertEqual(focused.returncode, 0, focused.stderr)
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertEqual(calls, ["focus block:1", "block close block:1"])

    def test_a_dead_port_is_not_success(self) -> None:
        # Bind and release, so the port is very likely to be closed.
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        result = self.run_cli("url", port=port)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot reach the devtools server", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
