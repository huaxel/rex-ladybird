#!/usr/bin/env bash
# rexchat reads a running Rex; CI has none, so a fake rex pins what it asks for
# and, as importantly, the block methods it never calls.
#
#   bash extensions/rexchat/test/run.sh

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

echo "== rexchat contract"
exec python3 "$here/rexchat_test.py"
