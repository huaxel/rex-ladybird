#!/usr/bin/env python3
"""Check that the collection's module list matches the directories on disk.

`init.lua` names the extensions it loads in a Lua table, because reading a
directory at config load time would mean spawning a shell. A new extension is
therefore two edits, and forgetting one is silent: the extension exists, has
tests, and never loads. This compares the list with extensions/*/init.lua both
ways.

    python3 test/manifest_check.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULES = re.compile(r"^local MODULES = \{(.*)\}\s*$", re.M)


def listed():
    text = (ROOT / "init.lua").read_text(encoding="utf-8")
    match = MODULES.search(text)
    if not match:
        raise SystemExit("init.lua: no `local MODULES = { ... }` line to read")
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def on_disk():
    return {
        path.parent.name
        for path in (ROOT / "extensions").glob("*/init.lua")
        if path.parent.is_dir()
    }


def main():
    declared, found = listed(), on_disk()
    problems = []
    for name in sorted(declared - found):
        problems.append(f"init.lua lists {name!r}, but extensions/{name}/init.lua does not exist")
    for name in sorted(found - declared):
        problems.append(f"extensions/{name}/init.lua exists, but init.lua does not list {name!r}")
    for problem in problems:
        print(problem)
    if problems:
        print("\nkeep `local MODULES` in init.lua and extensions/*/init.lua in step")
        return 1
    print(f"the collection lists all {len(declared)} extensions: {', '.join(sorted(declared))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
