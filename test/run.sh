#!/usr/bin/env bash
# Runs everything this repository can check without a browser: the collection
# module and every extension's own suite, the installer against a temporary
# account, the scope and manifest checks, and shellcheck.
#
# Exits non-zero if any of them fails. An extension's suite may report a skip
# instead (the launcher needs a running Rex); that is not a failure.
#
#   bash test/run.sh
#   LUA_BIN=/path/to/luajit bash test/run.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1
# shellcheck source=/dev/null
. "$root/test/lib.sh"

failed=0

step() {
    local name=$1
    shift
    echo "== $name"
    "$@" || { echo "!! $name failed"; failed=1; }
    echo
}

# The scope check is the trap that makes a helper look nil at run time: a name
# read above the `local` that declares it. It is cheap, so it runs on every
# Lua file in the collection.
step "scope check" python3 test/scope_check.py init.lua extensions/*/init.lua
# A new extension is a directory and a line in init.lua; this is the only place
# that notices when only one of the two happened.
step "manifest check" python3 test/manifest_check.py
# The READMEs point into each other by relative path, and a collection moves files.
step "link check" python3 test/links_check.py

if lua=$(find_lua); then
    step "collection contract" "$lua" test/collection_test.lua
    echo "using Lua: $lua"
    echo
else
    echo "!! no Lua interpreter found (luajit, lua5.1 or lua; set LUA_BIN)"
    failed=1
fi

for path in extensions/*/; do
    name=$(basename -- "$path")
    [ -f "$path/test/run.sh" ] || continue
    step "$name" bash "$path/test/run.sh"
done

if command -v shellcheck >/dev/null 2>&1; then
    step shellcheck shellcheck test/*.sh install.sh extensions/*/test/run.sh
else
    echo "skip: shellcheck is not installed"
fi

# The python helpers are compiled before they are run, so a syntax error in one
# is reported as that file rather than as a confusing failure in a test.
echo "== compile the python helpers"
python_helpers=0
for helper in extensions/*/bin/*; do
    [ -f "$helper" ] || continue
    head -n 1 "$helper" | grep -q python || continue
    python_helpers=$((python_helpers + 1))
    python3 -m py_compile "$helper" || { echo "!! $helper does not compile"; failed=1; }
done
[ "$python_helpers" -gt 0 ] || { echo "!! no python helpers found"; failed=1; }
echo

# --help is the cheapest proof that a helper still starts under this python.
step "ladyctl --help" python3 extensions/rex-ladybird/bin/ladyctl --help
step "rexchat --help" python3 extensions/rexchat/bin/rexchat --help
# The installer edits a file the user cannot lose, so its rollback is pinned.
step "install.sh contract" bash test/install_test.sh

exit $failed
