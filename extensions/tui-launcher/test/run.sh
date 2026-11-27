#!/usr/bin/env bash
# The launcher builds its index from shell history, the live server's sessions
# and the client's own actions, so this suite needs a running Rex. Without one
# it says so and passes: a skipped check that reads as green is worse than a
# loud skip, and CI has no Rex at all.
#
#   bash extensions/tui-launcher/test/run.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

if ! command -v rex >/dev/null 2>&1; then
    echo "skip: the launcher reads a live server, and rex is not on PATH"
    exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1 && [ ! -x /usr/bin/sqlite3 ]; then
    echo "skip: the fixture history needs sqlite3"
    exit 0
fi
if ! rex whoami >/dev/null 2>&1; then
    echo "skip: no Rex server answered (start one, then run this again)"
    exit 0
fi

db=$(mktemp "${TMPDIR:-/tmp}/atuin-fixture.XXXXXX") || exit 1
# shellcheck disable=SC1010  # "do" here is rex's subcommand, not a keyword
TUI_LAUNCHER_DB="$db" rex do "$here/launcher_test.lua"
status=$?
rm -f -- "$db"
exit $status
