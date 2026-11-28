#!/usr/bin/env python3
"""The documented click path, checked end to end in a real pane.

The hit-test suite checks the geometry against recorded terminal input. This checks
the other half: that a click in the pane writes the answer file and relabels the
pane, which is what the README and the guide promise an agent can wait on.

It opens the card through `ask.lua`, asks card.py itself where its first choice is
(so the geometry cannot drift from the program that draws it), writes the SGR
sequence a mouse would send into the pane, and requires:

  * the answer file appears, holding {"id", "title", "block_id"};
  * the pane's label becomes "chose: <title>";
  * the tab it opened is closed again, whether the check passed or failed.

It needs a running Rex, ImageMagick, and nothing else. It opens and closes a tab,
so it is not part of test/run.sh; CI has no Rex to open one in.

    python3 examples/kitty-card/test_click_live.py
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
        return True
    print(f"  FAIL {name}" + (f"\n       {detail}" if detail else ""))
    return False


def rex(*args, expect=True):
    out = subprocess.run(["rex", *args], capture_output=True, text=True, timeout=30)
    if expect and out.returncode != 0:
        raise SystemExit(f"rex {' '.join(args)} failed: {out.stderr.strip()[:400]}")
    return out


def main():
    if not os.environ.get("REX_BLOCK"):
        print("skip: this check opens a card in a Rex pane, and REX_BLOCK is unset")
        return 0
    if rex("whoami", expect=False).returncode != 0:
        print("skip: no Rex server answered (start one, then run this again)")
        return 0

    answer = Path(tempfile.mkdtemp()) / "answer.json"
    created = json.loads(
        rex(
            "do",
            str(HERE / "ask.lua"),
            "--action",
            "ask",
            "question=Does a click answer the card?",
            "choices=yes=Ship it|no=Wait",
            f"answer={answer}",
            "--json",
        ).stdout
    )
    block = created["block_id"]
    failed = 0
    try:
        # The card has to switch the pty to raw mode and draw before it reads a
        # click; there is no event to wait for, so give it a fixed head start.
        time.sleep(3)

        size = json.loads(rex("block", "call", "-b", block, "size").stdout)
        cell_w, cell_h = size["cell_width_px"], size["cell_height_px"]
        width = size["columns"] * cell_w

        # card.py's own boxes, imported with the environment it would have in a pane.
        os.environ["REX_BLOCK"] = block
        os.environ["CARD_QUESTION"] = "Does a click answer the card?"
        os.environ["CARD_CHOICES"] = "yes=Ship it|no=Wait"
        os.environ["CARD_ANSWER"] = str(answer)
        spec = importlib.util.spec_from_file_location("kitty_card", HERE / "card.py")
        card = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(card)

        left, top, box_w, box_h, ident = card.buttons(width, size["rows"] * cell_h)[0]
        x, y = left + box_w // 2, top + box_h // 2
        col, row = x // cell_w + 1, y // cell_h + 1
        print(f"  pane {size['columns']}x{size['rows']} cells, clicking {ident} at ({col},{row})")
        rex("block", "call", "-b", block, "write",
            json.dumps({"data": f"\x1b[<0;{col};{row}M"}))

        for _ in range(16):
            if answer.exists():
                break
            time.sleep(0.5)

        if not check("the click wrote the answer file", answer.exists(), str(answer)):
            failed += 1
        else:
            written = json.loads(answer.read_text())
            if not check(
                "it holds the choice, its title and the block",
                written.get("id") == ident and written.get("title") == "Ship it"
                and written.get("block_id") == block,
                json.dumps(written),
            ):
                failed += 1
        label = json.loads(rex("block", "inspect", block, "--json").stdout)["block"].get("label")
        if not check("the pane's label shows the answer", label == "chose: Ship it", str(label)):
            failed += 1
    finally:
        rex("block", "close", block, expect=False)
        print("  closed the tab the check opened")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
