#!/usr/bin/env python3
"""A card drawn in a Rex pane with the Kitty graphics protocol.

Run inside a pane:  python3 examples/kitty-card/card.py
Click a choice: the card redraws as answered and the answer goes back through the
Rex API (the pane's own label), so nothing is read from or typed into the terminal.
"""
import base64
import json
import os
import select
import subprocess
import sys
import termios
import time
import tty

def find_magick():
    """ImageMagick is not on every PATH a Rex pane starts with, so look for it."""
    import shutil
    found = shutil.which("magick")
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/magick", "/usr/local/bin/magick",
                      os.path.expanduser("~/.nix-profile/bin/magick")):
        if os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("kitty-card needs ImageMagick's `magick`; install it or put it on PATH")


MAGICK = find_magick()
BLOCK = os.environ["REX_BLOCK"]
IMAGE_ID = 7311
LOG = os.environ.get("KITTY_CARD_LOG", "/tmp/kitty-card.log")
QUESTION = os.environ.get("CARD_QUESTION", "Which platforms should we build for?")
CHOICES = [tuple(part.split("=", 1)) if "=" in part else (part, part)
           for part in os.environ.get("CARD_CHOICES", "mac_ios=Mac + iOS together|mac=Mac only first").split("|")]
ANSWER_FILE = os.environ.get("CARD_ANSWER", f"/tmp/rex-card-{BLOCK.split(':')[-1]}.json")


def note(message):
    with open(LOG, "a") as f:
        f.write(message + "\n")


def rex(*args):
    return subprocess.run(["rex", "--autostart=false", *args], capture_output=True, text=True, timeout=5)


def pane_geometry():
    out = rex("block", "call", "-b", BLOCK, "size")
    size = json.loads(out.stdout)
    return (size["columns"] * size["cell_width_px"], size["rows"] * size["cell_height_px"],
            size["cell_width_px"], size["cell_height_px"])


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def svg(width, height, answered):
    card_w, card_h = min(720, width - 80), 120 + 72 * len(CHOICES)
    x, y = 40, 40
    rows = []
    for index, (_, title) in enumerate(CHOICES):
        top = y + 96 + index * 72
        fill = "#e8f0ff" if answered and answered == CHOICES[index][1] else "#f2f2f4"
        rows.append(f'<rect x="{x + 24}" y="{top}" width="{card_w - 48}" height="56" rx="10" fill="{fill}"/>')
        label = title + ("  ✓" if answered == title else "")
        rows.append(f'<text x="{x + 44}" y="{top + 36}" font-family="Helvetica" font-size="22" fill="#16181d">{label}</text>')
    status = f'Answered: {answered}' if answered else "Click a choice."
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">
<rect width="{width}" height="{height}" fill="#1b1d21"/>
<rect x="{x}" y="{y}" width="{card_w}" height="{card_h}" rx="16" fill="#ffffff"/>
<text x="{x + 24}" y="{y + 46}" font-family="Helvetica" font-size="24" font-weight="bold" fill="#16181d">{esc(QUESTION)}</text>
<text x="{x + 24}" y="{y + 72}" font-family="Helvetica" font-size="16" fill="#6b7280">{status}</text>
{"".join(rows)}
</svg>'''


def render(width, height, answered):
    drawing = subprocess.run(
        [MAGICK, "-background", "none", "svg:-", "-depth", "8", "-alpha", "off", "rgb:-"],
        input=svg(width, height, answered).encode(), capture_output=True, timeout=30)
    pixels = drawing.stdout
    if len(pixels) != width * height * 3:
        raise RuntimeError(f"magick returned {len(pixels)} bytes, wanted {width * height * 3}")
    return base64.b64encode(pixels).decode()


def write(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def draw(width, height, answered):
    data = render(width, height, answered)
    # Delete the previous image first, then place this one at the top-left cell.
    write(f"\x1b_Ga=d,d=i,i={IMAGE_ID},q=2\x1b\\")
    write("\x1b[1;1H")
    for start in range(0, len(data), 4096):
        chunk = data[start:start + 4096]
        more = 1 if start + 4096 < len(data) else 0
        first = start == 0
        control = f"a=T,f=24,s={width},v={height},i={IMAGE_ID},q=2,m={more}" if first else f"m={more}"
        write(f"\x1b_G{control};{chunk}\x1b\\")


def answer(ident, title):
    note("clicked " + ident)
    result = rex("api", "call", "-s", BLOCK, "session.set_block_label",
                 json.dumps({"block_id": BLOCK, "label": "chose: " + title}))
    note(f"api {result.returncode} {result.stdout.strip()} {result.stderr.strip()}")
    with open(ANSWER_FILE, "w") as f:
        json.dump({"id": ident, "title": title, "block_id": BLOCK}, f)
    note("wrote " + ANSWER_FILE)


def buttons(width, height):
    card_w = min(720, width - 80)
    box = []
    for index, (ident, title) in enumerate(CHOICES):
        top = 40 + 96 + index * 72
        box.append((40 + 24, top, card_w - 48, 56, ident))
    return box


def main():
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    answered = None
    write("\x1b[?1003h\x1b[?1006h\x1b[?25l")   # every-motion mouse, SGR encoding, hide cursor
    try:
        width, height, cell_w, cell_h = pane_geometry()
        draw(width, height, answered)
        while True:
            ready, _, _ = select.select([fd], [], [], 0.4)
            if ready:
                data = os.read(fd, 4096).decode("utf-8", "replace")
                for event in data.split("\x1b[<")[1:]:
                    button, col, row = event.split(";")[0], int(event.split(";")[1]), int(event.split(";")[2].rstrip("Mm"))
                    if event.endswith("m") or button not in ("0", "1"):
                        continue
                    x, y = (col - 1) * cell_w, (row - 1) * cell_h
                    for left, top, w, h, ident in buttons(width, height):
                        if left <= x <= left + w and top <= y <= top + h:
                            answered = dict(CHOICES)[ident]
                            answer(ident, answered)
                            draw(width, height, answered)
                            break
            geometry = pane_geometry()
            if geometry[:2] != (width, height):
                width, height, cell_w, cell_h = geometry
                draw(width, height, answered)
    finally:
        write(f"\x1b_Ga=d,d=i,i={IMAGE_ID},q=2\x1b\\")
        write("\x1b[?1003l\x1b[?1006l\x1b[?25h")
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
