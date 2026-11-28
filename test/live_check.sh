#!/usr/bin/env bash
# Loads the collection in the real Rex, not in the fake.
#
# The fake Rex is the broad check: fast, portable, and it records every call. It
# is also not Rex, and it has no sandbox -- it happily ran the `os.execute` that
# a real server refuses the first time this collection was loaded. This check
# exists for exactly that class of failure.
#
# It needs a server, so it skips loudly when there is none, the way the
# launcher's suite does. Nothing here changes the running configuration:
# `config check` loads a file and reports what it found, and the script runs the
# collection in `rex do`, where the actions it registers are the script's own.
#
#   bash test/live_check.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failed=0

if ! command -v rex >/dev/null 2>&1; then
    echo "skip: rex is not on PATH, so there is no server to load the collection"
    exit 0
fi
if ! rex whoami >/dev/null 2>&1; then
    echo "skip: no Rex server answered (start one, then run this again)"
    exit 0
fi

echo "== the collection loads under the server's Lua"
# dofile, not require: this checkout is often loaded by path before it is
# installed, and the returned list is what shows whether every extension made it.
# shellcheck disable=SC1010  # "do" here is rex's subcommand, not a shell keyword
if ! loaded=$(REX_EXT_ROOT="$root" rex do -e '
local collection = dofile(os.getenv("REX_EXT_ROOT") .. "/init.lua")
local result = collection.setup{}
return { loaded = result.loaded, skipped = result.skipped }
' --json 2>&1); then
    echo "$loaded"
    echo "!! the collection did not load"
    exit 1
fi
printf '%s' "$loaded" | python3 -c '
import json, sys
result = json.load(sys.stdin)
names = result.get("loaded") or []
skipped = result.get("skipped") or []
problems = []
if not names:
    problems.append("no extension loaded")
if "rex-ladybird" not in names:
    problems.append("rex-ladybird did not load")
for name in skipped:
    problems.append("skipped " + name)
if problems:
    print("  FAIL " + "; ".join(problems))
    sys.exit(1)
print("  ok   every extension loaded: " + ", ".join(names))
' || failed=1

echo
echo "== a config file that loads it is accepted"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-live-check.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/init.lua" <<CONFIG
local collection = dofile("$root/init.lua")
collection.setup{}
rex.bind("ctrl+b>y", "terminal_theme")
CONFIG
if ! out=$(rex config check "$tmp/init.lua" 2>&1); then
    echo "$out"
    echo "!! rex config check rejected the collection"
    exit 1
fi
actions=$(printf '%s\n' "$out" | sed -n 's/^actions: //p')
bindings=$(printf '%s\n' "$out" | sed -n 's/^bindings: //p')
if [ "${actions:-0}" -ge 10 ] 2>/dev/null; then
    echo "  ok   it registered its actions ($actions)"
else
    echo "  FAIL it registered its actions (${actions:-none})"; echo "$out"; failed=1
fi
if [ "${bindings:-0}" -ge 1 ] 2>/dev/null; then
    echo "  ok   it took the binding written beside it ($bindings)"
else
    echo "  FAIL it took the binding written beside it (${bindings:-none})"; echo "$out"; failed=1
fi

exit $failed
