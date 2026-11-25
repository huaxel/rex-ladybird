#!/bin/sh
# Installs rex-ladybird: the module where Rex looks for it, ladyctl where a
# shell finds it, and the line that loads the module into init.lua.
#
# Asks nothing, and safe to run again after a `git pull`. Every change it makes
# to init.lua is undone if `rex config check` rejects the result.
#
#   ./install.sh                              # ~/.local/bin and the XDG config dir
#   PREFIX=/usr/local ./install.sh            # somewhere else on PATH
#   REX_CONFIG=/path/to/init.lua ./install.sh # another account's config file
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd -P)
config_file="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
config_dir=$(dirname -- "$config_file")
module="$config_dir/rex-ladybird"
bindir="${PREFIX:-$HOME/.local}/bin"
line='require("rex-ladybird").setup{}'

fail() {
    echo "rex-ladybird: $*" >&2
    exit 1
}

# 1. What has to be there already. Rex is not optional: without it this is a
#    module nothing loads. Ladybird is only a warning, because a pane opened
#    before the build exists says so itself.
command -v rex >/dev/null 2>&1 ||
    fail "the rex command is not on PATH. See https://www.superlogical.com/rex/docs/installation"
[ -f "$here/init.lua" ] || fail "$here does not look like a rex-ladybird checkout"
command -v python3 >/dev/null 2>&1 || fail "ladyctl needs python3"
if [ -z "${LADYBIRD_BINARY:-}" ] && ! command -v ladybird >/dev/null 2>&1; then
    echo "rex-ladybird: no ladybird on PATH and LADYBIRD_BINARY is unset. A pane needs a" >&2
    echo "              source build with terminal mode; set LADYBIRD_BINARY to its path." >&2
fi

# 2. The module. It is a symlink so that `git pull` is the update, and it is
#    never forced over a directory: that one may be somebody's work.
if [ -L "$module" ]; then
    rm -- "$module"
elif [ -e "$module" ]; then
    fail "$module exists and is not a symlink. Move it aside, then run this again"
fi
mkdir -p -- "$config_dir"
ln -s -- "$here" "$module"
echo "linked $module -> $here"

# 3. The CLI. The module finds bin/ladyctl beside itself, so this link is only
#    for typing `ladyctl` by hand.
mkdir -p -- "$bindir"
ln -sf -- "$here/bin/ladyctl" "$bindir/ladyctl"
echo "linked $bindir/ladyctl"

# 4. Loading it. The line goes in once, and the file only keeps it if Rex can
#    still read the result: a config that no longer loads costs the user their
#    keys, which is worse than not being installed.
if grep -qF -- "$line" "$config_file" 2>/dev/null; then
    echo "$config_file already loads the module"
else
    backup="$config_file.before-rex-ladybird"
    if [ -f "$config_file" ]; then
        cp -- "$config_file" "$backup"
    fi
    printf '\n%s\n' "$line" >>"$config_file"
    if rex config check "$config_file" >/dev/null 2>&1; then
        echo "added $line to $config_file"
    else
        if [ -f "$backup" ]; then
            cp -- "$backup" "$config_file"
        else
            rm -f -- "$config_file"
        fi
        fail "$config_file is unchanged: rex config check rejected it with the module loaded. Run: rex config check"
    fi
fi

# 5. Tell the running server, if there is one. Not an error when there is not:
#    the next start reads the file anyway.
rex config reload >/dev/null 2>&1 || echo "warning: rex config reload failed; run it by hand once Rex is running" >&2

case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "Add $bindir to your PATH, for example: echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "done. ctrl+b w in Rex opens an address; ladyctl drives the pane from a shell."
