#!/usr/bin/env bash
# Installs into a temporary account, against a `rex` that only answers, and
# checks what the installer leaves behind:
#
#   * the collection and every extension are symlinks, the helpers are on PATH,
#     and the load line went in once;
#   * installing one extension links only that one, under the same line;
#   * a single-extension line written by the old installer is replaced, not
#     left to register the same actions twice;
#   * a config Rex rejects is left exactly as it was;
#   * a directory where a symlink belongs is not touched.
#
#   bash test/install_test.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
failed=0
pass() { echo "  ok   $1"; }
fail() {
    echo "  FAIL $1"
    [ -n "${2:-}" ] && echo "       $2"
    failed=1
    return 0
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-extensions-install.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# A `rex` that records what it was asked and can reject the config, so the
# rollback is exercised without a Rex server.
mkdir -p "$tmp/path"
cat >"$tmp/path/rex" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >>"$REX_LOG"
case "$1 $2" in
    "config check") [ "${REX_CHECK:-ok}" = ok ] ;;
    "config reload") exit 0 ;;
    *) exit 0 ;;
esac
FAKE
chmod +x "$tmp/path/rex"

install_into() {
    env HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" PREFIX="$tmp/prefix" \
        REX_CONFIG="$tmp/config/rex/init.lua" REX_LOG="$tmp/rex.log" \
        PATH="$tmp/path:$PATH" "$root/install.sh" "$@"
}

fresh_account() {
    rm -rf -- "${tmp:?}/config" "${tmp:?}/prefix" "${tmp:?}/home"
    mkdir -p -- "$tmp/config/rex" "$tmp/home"
    : >"$tmp/config/rex/init.lua"
}

linked_to() {
    [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

expect_link() {
    if linked_to "$1" "$2"; then
        pass "$3"
    else
        fail "$3" "$(readlink "$1" 2>/dev/null || echo "no such link")"
    fi
}

expect_executable() {
    if [ -x "$1" ]; then pass "$2"; else fail "$2" "$1 is not executable"; fi
}

expect_absent() {
    if [ -e "$1" ]; then fail "$2" "$1 exists"; else pass "$2"; fi
}

expect_line_count() {
    local count
    count=$(grep -cF -- "$2" "$1" 2>/dev/null)
    if [ "$count" = "$3" ]; then pass "$4"; else fail "$4" "found $count in $(cat "$1")"; fi
}

line='require("rex-extensions").setup{}'

echo "== install every extension into an empty account"
fresh_account
out=$(install_into 2>&1) || fail "the installer succeeded" "$out"
expect_link "$tmp/config/rex/rex-extensions" "$root" "the collection is linked"
expect_link "$tmp/config/rex/rex-ladybird" "$root/extensions/rex-ladybird" "rex-ladybird is linked"
expect_link "$tmp/config/rex/appearance" "$root/extensions/appearance" "appearance is linked"
expect_link "$tmp/config/rex/tui-launcher" "$root/extensions/tui-launcher" "tui-launcher is linked"
expect_absent "$tmp/config/rex/rexchat" "an extension without init.lua is not linked as a module"
expect_executable "$tmp/prefix/bin/ladyctl" "ladyctl is linked"
expect_executable "$tmp/prefix/bin/rexchat" "rexchat is linked"
expect_executable "$tmp/prefix/bin/ladybird-import-chrome-cookies" "the cookie importer is linked"
expect_line_count "$tmp/config/rex/init.lua" "$line" 1 "the load line went in once"
if grep -q "config check" "$tmp/rex.log"; then pass "the result was checked"; else fail "the result was checked"; fi

echo
echo "== running it again changes nothing"
before=$(cat "$tmp/config/rex/init.lua")
install_into >/dev/null 2>&1 || fail "the second run succeeded"
if [ "$(cat "$tmp/config/rex/init.lua")" = "$before" ]; then pass "the config is unchanged"; else fail "the config is unchanged"; fi
expect_line_count "$tmp/config/rex/init.lua" "$line" 1 "still one load line"

echo
echo "== installing one extension links only that one"
fresh_account
install_into appearance >/dev/null 2>&1 || fail "the installer succeeded"
expect_link "$tmp/config/rex/appearance" "$root/extensions/appearance" "appearance is linked"
expect_absent "$tmp/config/rex/rex-ladybird" "rex-ladybird is left out"
expect_absent "$tmp/prefix/bin/ladyctl" "its helpers are left out"
expect_line_count "$tmp/config/rex/init.lua" "$line" 1 "the same line loads it"

echo
echo "== an extension that does not exist is named"
if out=$(install_into nosuch 2>&1); then
    fail "the installer refuses an unknown name"
else
    pass "the installer refuses an unknown name"
fi
case "$out" in
    *"no extension called 'nosuch'"*) pass "and says so" ;;
    *) fail "and says so" "$out" ;;
esac

echo
echo "== a single-extension load line is replaced, not left beside it"
fresh_account
printf 'rex.bind("ctrl+b>z", "ladybird_open")\nrequire("rex-ladybird").setup{}\n' >"$tmp/config/rex/init.lua"
install_into >/dev/null 2>&1 || fail "the installer succeeded"
expect_line_count "$tmp/config/rex/init.lua" 'require("rex-ladybird")' 0 "the old line is gone"
expect_line_count "$tmp/config/rex/init.lua" "$line" 1 "the collection line is there once"
if grep -qF 'rex.bind("ctrl+b>z", "ladybird_open")' "$tmp/config/rex/init.lua"; then
    pass "the rest of the file is untouched"
else
    fail "the rest of the file is untouched" "$(cat "$tmp/config/rex/init.lua")"
fi

echo
echo "== a config Rex rejects is left as it was"
fresh_account
printf 'rex.bind("ctrl+b>z", "nothing")\n' >"$tmp/config/rex/init.lua"
before=$(cat "$tmp/config/rex/init.lua")
if REX_CHECK=fail install_into >"$tmp/rejected.log" 2>&1; then
    fail "the installer refuses a config Rex rejects"
else
    pass "the installer refuses a config Rex rejects"
fi
if [ "$(cat "$tmp/config/rex/init.lua")" = "$before" ]; then
    pass "the config is byte for byte what it was"
else
    fail "the config is byte for byte what it was" "$(cat "$tmp/config/rex/init.lua")"
fi
if grep -q "is unchanged" "$tmp/rejected.log"; then
    pass "and says so, with the way to check it"
else
    fail "and says so, with the way to check it" "$(cat "$tmp/rejected.log")"
fi

echo
echo "== a config file that did not exist is not left behind"
fresh_account
rm -f -- "$tmp/config/rex/init.lua"
if REX_CHECK=fail install_into >/dev/null 2>&1; then
    fail "the installer refuses to create a config Rex rejects"
else
    pass "the installer refuses to create a config Rex rejects"
fi
expect_absent "$tmp/config/rex/init.lua" "no half-written init.lua is left"

echo
echo "== a directory where a symlink belongs is not deleted"
fresh_account
mkdir -p -- "$tmp/config/rex/rex-ladybird"
printf 'mine\n' >"$tmp/config/rex/rex-ladybird/init.lua"
if install_into >/dev/null 2>&1; then
    fail "the installer refuses to replace a directory"
else
    pass "the installer refuses to replace a directory"
fi
if [ "$(cat "$tmp/config/rex/rex-ladybird/init.lua" 2>/dev/null)" = "mine" ]; then
    pass "and the directory's contents are untouched"
else
    fail "and the directory's contents are untouched"
fi

echo
echo "== removing an extension unlinks it and its helpers, and nothing else"
fresh_account
install_into >/dev/null 2>&1 || fail "the install succeeded"
before=$(cat "$tmp/config/rex/init.lua")
install_into --remove rex-ladybird >/dev/null 2>&1 || fail "the remove succeeded"
expect_absent "$tmp/config/rex/rex-ladybird" "its own link is gone"
expect_absent "$tmp/prefix/bin/ladyctl" "its helper is gone"
expect_absent "$tmp/prefix/bin/ladybird-import-chrome-cookies" "its second helper is gone"
expect_executable "$tmp/prefix/bin/rexchat" "another extension's helper stays"
expect_link "$tmp/config/rex/appearance" "$root/extensions/appearance" "another extension's link stays"
if [ "$(cat "$tmp/config/rex/init.lua")" = "$before" ]; then
    pass "the load line is untouched"
else
    fail "the load line is untouched" "$(cat "$tmp/config/rex/init.lua")"
fi

echo
echo "== removal refuses a directory it did not create"
fresh_account
mkdir -p -- "$tmp/config/rex/appearance"
printf 'mine\n' >"$tmp/config/rex/appearance/init.lua"
if install_into --remove appearance >"$tmp/removal.log" 2>&1; then
    fail "the installer refuses to remove a directory"
else
    pass "the installer refuses to remove a directory"
fi
if [ "$(cat "$tmp/config/rex/appearance/init.lua" 2>/dev/null)" = "mine" ]; then
    pass "and its contents are untouched"
else
    fail "and its contents are untouched"
fi

echo
echo "== removing something that was never linked says so and succeeds"
fresh_account
if install_into --remove appearance >"$tmp/unlinked.log" 2>&1; then
    pass "it succeeds"
else
    fail "it succeeds" "$(cat "$tmp/unlinked.log")"
fi
if grep -q "is not linked" "$tmp/unlinked.log"; then
    pass "and says it was not linked"
else
    fail "and says it was not linked" "$(cat "$tmp/unlinked.log")"
fi

echo
if [ "$failed" -ne 0 ]; then
    echo "some checks failed"
    exit 1
fi
echo "all checks passed"
