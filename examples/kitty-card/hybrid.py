#!/usr/bin/env python3
"""Cells for the transcript, pixels for the card: the split the measurements argue for.

    TARGET=block:<id> python3 examples/kitty-card/hybrid.py

The transcript is printed as ordinary terminal text, so it scrolls, selects and copies
the way text should. The decision card is a small image placed in cells the text never
touches. Both paths log their cost to $HYBRID_LOG (ms,bytes,kind).
"""
import base64, json, os, select, subprocess, sys, termios, time, tty

BLOCK = os.environ["REX_BLOCK"]
TARGET = os.environ.get("TARGET", BLOCK)
LOG = os.environ.get("HYBRID_LOG", "/tmp/hybrid.csv")
IMAGE_ID = 7313
CHOICES = [("mac_ios", "Mac + iOS together"), ("mac", "Mac only first")]
CARD_CELLS = (34, 11)          # card occupies this many cells, top right
CARD_PX = (408, 220)           # rendered at 12 px per cell wide, 20 high


def rex(*args):
    return subprocess.run(["rex", "--autostart=false", *args], capture_output=True, text=True, timeout=10)


def geometry():
    size = json.loads(rex("block", "call", "-b", BLOCK, "size").stdout)
    return size["columns"], size["rows"], size["cell_width_px"], size["cell_height_px"]


def transcript():
    return [l.rstrip() for l in rex("capture", "-b", TARGET, "--trim").stdout.splitlines()]


def out(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def log(kind, started, nbytes):
    with open(LOG, "a") as f:
        f.write(f"{int((time.time() - started) * 1000)},{nbytes},{kind}\n")


def esc(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def card_svg(width, height, answered):
    rows = []
    for index, (_, title) in enumerate(CHOICES):
        top = 84 + index * 58
        chosen = answered == title
        rows.append(f'<rect x="16" y="{top}" width="{width - 32}" height="46" rx="8" fill="{"#dbe9ff" if chosen else "#f1f2f4"}"/>')
        rows.append(f'<text x="30" y="{top + 30}" font-family="Helvetica" font-size="19" fill="#15171c">{esc(title)}{"  ✓" if chosen else ""}</text>')
    status = f"Answered: {esc(answered)}" if answered else "Click a choice"
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            f'<rect width="{width}" height="{height}" fill="#ffffff"/>'
            f'<text x="16" y="34" font-family="Helvetica" font-size="18" font-weight="bold" fill="#15171c">Which platforms?</text>'
            f'<text x="16" y="60" font-family="Helvetica" font-size="13" fill="#6b7280">{status}</text>'
            + "".join(rows) + "</svg>")


def draw_card(answered, card_col, rows_):
    width, height = CARD_PX
    started = time.time()
    drawing = subprocess.run(["magick", "-background", "none", "svg:-", "-depth", "8", "-alpha", "off", "rgb:-"],
                             input=card_svg(width, height, answered).encode(), capture_output=True, timeout=30)
    if len(drawing.stdout) != width * height * 3:
        raise RuntimeError("rasteriser failed")
    data = base64.b64encode(drawing.stdout).decode()
    out(f"\x1b[1;{card_col}H")
    for start in range(0, len(data), 4096):
        chunk = data[start:start + 4096]
        more = 1 if start + 4096 < len(data) else 0
        head = (f"a=T,f=24,s={width},v={height},c={CARD_CELLS[0]},r={CARD_CELLS[1]},i={IMAGE_ID},q=2,m={more}"
                if start == 0 else f"m={more}")
        out(f"\x1b_G{head};{chunk}\x1b\\")
    log("card", started, len(data))


def draw_text(lines, first, rows, text_cols, status):
    started = time.time()
    body = [f"\x1b[{row + 1};1H{lines[first + row][:text_cols]:<{text_cols}}" for row in range(rows)]
    body.append(f"\x1b[{rows};1H{status[:text_cols]:<{text_cols}}")
    payload = "".join(body)
    out(payload)
    log("text", started, len(payload))


def card_column(cols):
    """First cell column of the card in a pane this wide."""
    return cols - min(CARD_CELLS[0], cols // 2) + 1


def buttons(card_col):
    """Cell rectangles for the two choices, inside the card."""
    # The image is scaled into CARD_CELLS, so one cell covers this many rendered pixels.
    per_cell_x = CARD_PX[0] / CARD_CELLS[0]
    per_cell_y = CARD_PX[1] / CARD_CELLS[1]
    boxes = []
    for index, (_, title) in enumerate(CHOICES):
        top_px = 84 + index * 58
        left = card_col + int(16 / per_cell_x)
        width = int((CARD_PX[0] - 32) / per_cell_x)
        boxes.append((left, 1 + int(top_px / per_cell_y), width, max(1, int(46 / per_cell_y)), title))
    return boxes


def clicked(payload, card_col):
    """The choice a chunk of terminal input asks for, or None."""
    for event in payload.split("\x1b[<")[1:]:
        fields = event.rstrip("Mm").split(";")
        if len(fields) < 3 or event.endswith("m"):
            continue
        # Only the left and middle buttons are clicks: the wheel sets bit 64 and a drag
        # sets bit 32, and both would otherwise answer a card they scrolled past.
        if fields[0] not in ("0", "1"):
            continue
        col, row = int(fields[1]), int(fields[2].rstrip("Mm"))
        for left, top, width, height, title in buttons(card_col):
            if left <= col < left + width and top <= row < top + height:
                return title
    return None


def main():
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    out("\x1b[?1003h\x1b[?1006h\x1b[?25l\x1b[2J")
    answered = None
    try:
        cols, rows, cell_w, cell_h = geometry()
        card_col = card_column(cols)
        text_cols = card_col - 2
        lines, first = transcript(), 0
        draw_text(lines, first, rows - 1, text_cols, "j/k scroll  r reload  q quit")
        draw_card(answered, card_col, rows)
        while True:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if not ready:
                continue
            data = os.read(fd, 4096).decode("utf-8", "replace")
            if os.environ.get("HYBRID_DEBUG"):
                with open(LOG + ".raw", "a") as f:
                    f.write(repr(data) + "\n")
            if data.strip() == "q":
                break
            if data.strip() == "r":
                lines = transcript()
                first = max(0, len(lines) - (rows - 1))
                draw_text(lines, first, rows - 1, text_cols, "j/k scroll  r reload  q quit")
                draw_card(answered, card_col, rows)
                continue
            moved = (-1 if "k" in data else 0) + (1 if "j" in data else 0) + (rows - 2 if "\x1b[6~" in data else 0) - (rows - 2 if "\x1b[5~" in data else 0)
            if moved:
                new_first = max(0, min(max(0, len(lines) - (rows - 1)), first + moved))
                if new_first != first:
                    first = new_first
                    draw_text(lines, first, rows - 1, text_cols, "")
                continue
            answer = clicked(data, card_col)
            if answer:
                answered = answer
                result = rex("api", "call", "-s", BLOCK, "session.set_block_label",
                             json.dumps({"block_id": BLOCK, "label": "chose: " + answer}))
                with open(LOG, "a") as f:
                    f.write(f"{result.returncode},0,api\n")
                draw_card(answered, card_col, rows)
                draw_text(lines, first, rows - 1, text_cols, "answer sent through the Rex API")
    finally:
        out(f"\x1b_Ga=d,d=i,i={IMAGE_ID},q=2\x1b\\")
        out("\x1b[?1003l\x1b[?1006l\x1b[?25h\r\n")
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
