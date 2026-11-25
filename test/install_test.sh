#!/usr/bin/env bash
# Installs into a temporary account, against a `rex` that only answers, and
# checks what the installer leaves behind:
#
#   * the module is a symlink, ladyctl is on PATH, and the load line went in once;
#   * a config Rex rejects is left exactly as it was;
#   * a directory where the module symlink belongs is not touched.
#
#   bash test/install_test.sh

set -uo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failed=0
pass() { echo "  ok   $1"; }
fail() {
    echo "  FAIL $1"
    [ -n "${2:-}" ] && echo "       $2"
    failed=1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rex-ladybird-install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

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
        PATH="$tmp/path:$PATH" "$@" "$root/install.sh"
}

echo "== install into an empty account"
mkdir -p "$tmp/config/rex" "$tmp/home"
: >"$tmp/config/rex/init.lua"
out=$(install_into 2>&1) || fail "the installer succeeded" "$out"
[ -L "$tmp/config/rex/rex-ladybird" ] && [ "$(readlink "$tmp/config/rex/rex-ladybird")" = "$root" ] &&
    pass "the module is a symlink to the checkout" || fail "the module is a symlink to the checkout"
[ -x "$tmp/prefix/bin/ladyctl" ] && pass "ladyctl is linked" || fail "ladyctl is linked"
[ "$(grep -cF 'require("rex-ladybird").setup{}' "$tmp/config/rex/init.lua")" = 1 ] &&
    pass "the load line went in once" || fail "the load line went in once" "$(cat "$tmp/config/rex/init.lua")"
grep -q "config check" "$tmp/rex.log" && pass "the result was checked" || fail "the result was checked"

echo
echo "== running it again changes nothing"
before=$(cat "$tmp/config/rex/init.lua")
install_into >/dev/null 2>&1 || fail "the second run succeeded"
[ "$(cat "$tmp/config/rex/init.lua")" = "$before" ] && pass "the config is unchanged" || fail "the config is unchanged"
[ "$(grep -cF 'require("rex-ladybird").setup{}' "$tmp/config/rex/init.lua")" = 1 ] &&
    pass "still one load line" || fail "still one load line"

echo
echo "== a config Rex rejects is left as it was"
rm -rf "$tmp/config" "$tmp/prefix"
mkdir -p "$tmp/config/rex"
printf 'rex.bind("ctrl+b>z", "nothing")\n' >"$tmp/config/rex/init.lua"
before=$(cat "$tmp/config/rex/init.lua")
if REX_CHECK=fail install_into >"$tmp/rejected.log" 2>&1; then
    fail "the installer refuses a config Rex rejects"
else
    pass "the installer refuses a config Rex rejects"
fi
[ "$(cat "$tmp/config/rex/init.lua")" = "$before" ] && pass "the config is byte for byte what it was" ||
    fail "the config is byte for byte what it was" "$(cat "$tmp/config/rex/init.lua")"
grep -q "is unchanged" "$tmp/rejected.log" && pass "and says so, with the way to check it" ||
    fail "and says so, with the way to check it" "$(cat "$tmp/rejected.log")"

echo
echo "== a config file that did not exist is not left behind"
rm -rf "$tmp/config" "$tmp/prefix"
if REX_CHECK=fail install_into >/dev/null 2>&1; then
    fail "the installer refuses to create a config Rex rejects"
else
    pass "the installer refuses to create a config Rex rejects"
fi
[ -e "$tmp/config/rex/init.lua" ] && fail "no half-written init.lua is left" || pass "no half-written init.lua is left"

echo
echo "== a directory where the symlink belongs is not deleted"
rm -rf "$tmp/config" "$tmp/prefix"
mkdir -p "$tmp/config/rex/rex-ladybird"
printf 'mine\n' >"$tmp/config/rex/rex-ladybird/init.lua"
if install_into >/dev/null 2>&1; then
    fail "the installer refuses to replace a directory"
else
    pass "the installer refuses to replace a directory"
fi
[ "$(cat "$tmp/config/rex/rex-ladybird/init.lua" 2>/dev/null)" = "mine" ] &&
    pass "and the directory's contents are untouched" || fail "and the directory's contents are untouched"

echo
if [ "$failed" -ne 0 ]; then
    echo "some checks failed"
    exit 1
fi
echo "all checks passed"
