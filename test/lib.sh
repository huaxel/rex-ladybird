# shellcheck shell=bash
# Shared by the test entry points. Sourced, not run.
#
#   . "$repo/test/lib.sh"
#   lua=$(find_lua) || ...
#
# Rex runs Lua 5.1, so the tests prefer an interpreter that speaks it. A nix
# install often leaves luajit in the store without putting it on PATH, which is
# why the last resort looks there: a skipped suite that looks green is worse
# than a slow lookup.

find_lua() {
    for candidate in "${LUA_BIN:-}" luajit lua5.1 lua5.4 lua; do
        [ -n "$candidate" ] || continue
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    for candidate in /nix/store/*-luajit-*/bin/luajit; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
