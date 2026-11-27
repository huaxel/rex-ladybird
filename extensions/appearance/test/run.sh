#!/usr/bin/env bash
# The palette extension against the shared fake Rex: the exact set_theme call,
# and the refusals. No terminal is involved.
#
#   bash extensions/appearance/test/run.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$here/../../.." && pwd -P)
# shellcheck source=/dev/null
. "$root/test/lib.sh"

if lua=$(find_lua); then
    "$lua" "$here/theme_test.lua"
    exit $?
fi
echo "!! no Lua interpreter found (luajit, lua5.1 or lua; set LUA_BIN)"
exit 1
