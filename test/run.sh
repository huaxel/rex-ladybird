#!/usr/bin/env bash
# Runs the Lua tests against a fake Rex, the CLI tests against a fake DevTools
# server, then shellcheck on the helpers in bin/.
# Exits non-zero if any of them fails.
#
#   bash test/run.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

failed=0

step() {
    local name=$1
    shift
    echo "== $name"
    "$@" || { echo "!! $name failed"; failed=1; }
    echo
}

step "scope check" python3 test/scope_check.py init.lua

# Rex runs Lua 5.1, so prefer an interpreter that speaks it.
lua=$(command -v luajit || command -v lua5.1 || command -v lua || true)
if [[ -z $lua ]]; then
    echo "!! no Lua interpreter found (luajit, lua5.1 or lua)"
    failed=1
else
    for test in test/*_test.lua; do
        step "$test" "$lua" "$test"
    done
fi

if command -v shellcheck >/dev/null 2>&1; then
    step shellcheck shellcheck test/*.sh
else
    echo "skip: shellcheck is not installed"
fi

# The helpers are Python; check that they compile and that the CLI still answers.
step "compile bin/" python3 -m py_compile bin/ladyctl bin/ladybird-import-chrome-cookies
step "ladyctl --help" python3 bin/ladyctl --help
# The CLI's exit codes are the interface a script or an agent reads, so they are
# pinned against a fake DevTools server rather than left to a live browser.
step "ladyctl contract" python3 test/ladyctl_test.py

exit $failed
