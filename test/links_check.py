#!/usr/bin/env python3
"""Check that every relative link in the docs points at something.

A collection moves files: this one moved every file it had, and the READMEs point
into each other by relative path. A link that no longer resolves is invisible until
someone follows it, so it is checked here instead.

    python3 test/links_check.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\]\(([^)\s]+)\)")
SKIP = ("http://", "https://", "mailto:", "#")


def documents():
    yield from ROOT.glob("*.md")
    yield from ROOT.glob("docs/*.md")
    yield from ROOT.glob("extensions/*/README.md")
    yield from ROOT.glob("extensions/*/docs/*.md")


def main():
    problems = []
    checked = 0
    for document in sorted(documents()):
        for target in LINK.findall(document.read_text(encoding="utf-8")):
            if target.startswith(SKIP):
                continue
            path = target.split("#", 1)[0]
            if not path:
                continue
            checked += 1
            if not (document.parent / path).resolve().exists():
                problems.append(f"{document.relative_to(ROOT)}: {target}")
    for problem in problems:
        print(problem)
    if problems:
        print("\nfix these paths, or the file they name is gone")
        return 1
    print(f"all {checked} relative links resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
