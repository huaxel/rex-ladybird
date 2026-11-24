#!/usr/bin/env python3
"""Report names that are read before the `local` that declares them.

A `local function foo()` declares `foo` from that line on. A reference above it
is a lookup of the *global* `foo`, which is nil at run time and only shows up
when that path is exercised. The failure looks like "attempt to call a nil value"
from a helper that clearly exists, which is easy to misread as a typo.

    python3 test/scope_check.py init.lua
"""

import re
import sys

# Only file-level declarations matter: a name inside a function body is visible
# there alone, so it cannot be the "declared later" name another function reads.
DECL = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_]\w*)")
# `function name()` at the left margin assigns a global unless `local name` came first.
GLOBAL_FUNC = re.compile(r"^function\s+([A-Za-z_]\w*)\s*\(")


def strip(line):
    """Drop comments and string literals, so their words do not count."""
    line = re.sub(r"--.*$", "", line)
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    line = re.sub(r"'(?:\\.|[^'\\])*'", "''", line)
    return line


def check(path):
    with open(path, encoding="utf-8") as handle:
        raw = handle.read().split("\n")
    lines = [strip(line) for line in raw]

    declared = {}
    for number, line in enumerate(lines, 1):
        match = DECL.match(line)
        if match:
            declared.setdefault(match.group(1), number)

    problems = []
    for number, line in enumerate(lines, 1):
        match = GLOBAL_FUNC.match(line)
        if match and match.group(1) not in declared:
            problems.append((match.group(1), number, 0, raw[number - 1].strip()))
    for name, at in declared.items():
        pattern = re.compile(r"(?<![\w.:])" + re.escape(name) + r"\b(?!\s*=(?!=))")
        for number in range(1, at):
            if pattern.search(lines[number - 1]):
                problems.append((name, number, at, raw[number - 1].strip()))
                break
    return problems


def main(paths):
    failed = False
    for path in paths:
        for name, line, at, text in check(path):
            if at == 0:
                print(f"{path}:{line}: {name} is assigned as a global")
            else:
                print(f"{path}:{line}: {name} is read before its local declaration on line {at}")
            print(f"    {text}")
            failed = True
    if failed:
        print("\ndeclare these names first: `local name` above their first use")
        return 1
    print("no name is read before its declaration")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["init.lua"]))
