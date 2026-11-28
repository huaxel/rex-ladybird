"""Deterministic checks for the hybrid card's hit-testing, which a mouse cannot repeat."""
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("hybrid", __file__.replace("test_hybrid.py", "hybrid.py"))
hybrid = importlib.util.module_from_spec(spec)
sys.modules["hybrid"] = hybrid
spec.loader.exec_module(hybrid)

COLS, CARD_COL = 151, 118


def parse(payload):
    """The program's own parser, so the test cannot drift from it."""
    return hybrid.clicked(payload, CARD_COL)


# A narrower pane moves the card, and clicking a stale coordinate must do nothing.
narrow = hybrid.card_column(80)
narrow_click = narrow + int(16 / (408 / 34)) + 15

checks = [
    ("card column in a 151-cell pane", hybrid.card_column(151), 118),
    ("card column in an 80-cell pane", narrow, 47),
    ("a click at the 151-cell coordinate misses in a narrow pane",
     hybrid.clicked(f"\x1b[<0;134;6M", narrow), None),
    ("a click at the 80-cell coordinate hits", hybrid.clicked(f"\x1b[<0;{narrow_click};6M", narrow), "Mac + iOS together"),
    ("first row of the card", parse("\x1b[<0;134;6M"), "Mac + iOS together"),
    ("second row of the card", parse("\x1b[<0;134;9M"), "Mac only first"),
    ("a release is not a click", parse("\x1b[<0;134;6m"), None),
    ("text outside the card", parse("\x1b[<0;40;6M"), None),
    ("scrolling past the card", parse("\x1b[<64;134;6M"), None),
]
failed = 0
for name, got, want in checks:
    ok = got == want
    print(("  ok   " if ok else "  FAIL ") + name + "" if ok else f"  FAIL {name}: got {got!r}, wanted {want!r}")
    failed += 0 if ok else 1
sys.exit(1 if failed else 0)
