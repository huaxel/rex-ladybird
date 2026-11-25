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

    def __init__(self, answers="clicked", with_result=True):
        self.answers = answers
        self.with_result = with_result
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
                while True:
                    packet = self.read_packet(connection)
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
    def run_cli(self, *arguments: str, port: int) -> subprocess.CompletedProcess:
        environment = dict(os.environ)
        environment.pop("LADYCTL_PORT", None)
        return subprocess.run(
            [sys.executable, str(LADYCTL), "--port", str(port), *arguments],
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
