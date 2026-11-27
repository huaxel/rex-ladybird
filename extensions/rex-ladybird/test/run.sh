#!/usr/bin/env bash
# The Ladybird extension's own checks: the module against a fake Rex, then the
# CLI against a fake DevTools server. Neither needs a browser.
#
#   bash extensions/rex-ladybird/test/run.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$here/../../.." && pwd -P)
# shellcheck source=/dev/null
. "$root/test/lib.sh"

failed=0

if lua=$(find_lua); then
    echo "== module contract ($lua)"
    "$lua" "$here/module_test.lua" || failed=1
else
    echo "!! no Lua interpreter found (luajit, lua5.1 or lua; set LUA_BIN)"
    failed=1
fi

echo "== ladyctl contract"
python3 "$here/ladyctl_test.py" || failed=1

exit $failed
