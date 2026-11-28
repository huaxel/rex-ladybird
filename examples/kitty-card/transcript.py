#!/usr/bin/env python3
"""A scrollable transcript of a Rex pane, drawn with the Kitty graphics protocol.

    TARGET=block:<id> python3 examples/kitty-card/transcript.py [--scale 0.5]

Scroll with the wheel, j/k, PageUp/PageDown. Every repaint is logged to
$KITTY_TRANSCRIPT_LOG as CSV: millis,bytes,scale,rows so the cost can be measured
rather than guessed.
"""
import base64, json, os, select, subprocess, sys, termios, time, tty

BLOCK = os.environ["REX_BLOCK"]
TARGET = os.environ.get("TARGET", BLOCK)
SCALE = float(os.environ.get("SCALE", "0.5"))
LOG = os.environ.get("KITTY_TRANSCRIPT_LOG", "/tmp/kitty-transcript.csv")
IMAGE_ID = 7312


def rex(*args):
    return subprocess.run(["rex", "--autostart=false", *args], capture_output=True, text=True, timeout=10)


def geometry():
    size = json.loads(rex("block", "call", "-b", BLOCK, "size").stdout)
    return size["columns"], size["rows"], size["cell_width_px"], size["cell_height_px"]


def transcript():
    out = rex("capture", "-b", TARGET, "--trim").stdout
    return [line.rstrip() for line in out.splitlines()]


def esc(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def svg(lines, first, rows, width, height, cell_h, cols):
    body = []
    for index in range(rows):
        line = lines[first + index] if first + index < len(lines) else ""
        body.append(f'<text x="8" y="{int((index + 0.78) * cell_h * SCALE)}" '
                    f'font-family="Menlo" font-size="{int(cell_h * SCALE * 0.62)}" fill="#d7dae0">{esc(line[:cols])}</text>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            f'<rect width="{width}" height="{height}" fill="#16181d"/>' + "".join(body) + "</svg>")


def rasterise(lines, first, rows, width, height, cell_h, cols):
    started = time.time()
    drawing = subprocess.run(["magick", "-background", "none", "svg:-", "-depth", "8", "-alpha", "off", "rgb:-"],
                             input=svg(lines, first, rows, width, height, cell_h, cols).encode(),
                             capture_output=True, timeout=60)
    if len(drawing.stdout) != width * height * 3:
        raise RuntimeError(f"rasteriser returned {len(drawing.stdout)} bytes, wanted {width * height * 3}")
    return drawing.stdout, int((time.time() - started) * 1000)


def write(text):
    sys.stdout.write(text)
    sys.stdout.flush()


def draw(lines, first, cols, rows, cell_w, cell_h):
    width, height = int(cols * cell_w * SCALE), int(rows * cell_h * SCALE)
    pixels, raster_ms = rasterise(lines, first, rows, width, height, cell_h, cols)
    data = base64.b64encode(pixels).decode()
    started = time.time()
    write(f"\x1b_Ga=d,d=i,i={IMAGE_ID},q=2\x1b\\")
    write("\x1b[1;1H")
    for start in range(0, len(data), 4096):
        chunk = data[start:start + 4096]
        more = 1 if start + 4096 < len(data) else 0
        head = (f"a=T,f=24,s={width},v={height},c={cols},r={rows},i={IMAGE_ID},q=2,m={more}"
                if start == 0 else f"m={more}")
        write(f"\x1b_G{head};{chunk}\x1b\\")
    with open(LOG, "a") as f:
        f.write(f"{raster_ms + int((time.time() - started) * 1000)},{len(data)},{SCALE},{rows}\n")


def main():
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    cols, rows, cell_w, cell_h = geometry()
    lines = transcript()
    first = max(0, len(lines) - rows)
    write("\x1b[?1003h\x1b[?1006h\x1b[?25l")
    try:
        draw(lines, first, cols, rows, cell_w, cell_h)
        while True:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if not ready:
                continue
            data = os.read(fd, 4096).decode("utf-8", "replace")
            moved = 0
            for event in data.split("\x1b[<")[1:]:
                fields = event.rstrip("Mm").split(";")
                if len(fields) < 3:
                    continue
                button = int(fields[0].split(";")[0])
                if button == 64:
                    moved -= 3
                elif button == 65:
                    moved += 3
            if "j" in data or "\x1b[B" in data:
                moved += 1
            if "k" in data or "\x1b[A" in data:
                moved -= 1
            if "\x1b[6~" in data:
                moved += rows - 2
            if "\x1b[5~" in data:
                moved -= rows - 2
            if not moved:
                continue
            new_first = max(0, min(len(lines) - rows, first + moved))
            if new_first != first:
                first = new_first
                draw(lines, first, cols, rows, cell_w, cell_h)
            changed = geometry()[:2]
            if changed != (cols, rows):
                cols, rows, cell_w, cell_h = geometry()
                draw(lines, first, cols, rows, cell_w, cell_h)
    finally:
        write(f"\x1b_Ga=d,d=i,i={IMAGE_ID},q=2\x1b\\")
        write("\x1b[?1003l\x1b[?1006l\x1b[?25h")
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
